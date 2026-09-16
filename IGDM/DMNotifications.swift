import Foundation
import BackgroundTasks
import UserNotifications
import WebKit
import os

/// Checks the DM inbox while the app is in the background (whenever iOS grants a "Background App Refresh"
/// slot) and posts a local notification for every conversation with a new unread message from someone else.
///
/// iOS decides when these checks run: usually every 15 to 60 minutes while the phone is in normal use,
/// less often overnight or when the app is rarely opened, and never if the app was force-quit.
final class DMNotifier {
    static let shared = DMNotifier()
    static let taskIdentifier = AppInfo.bundleID + ".refresh"
    static let userAgentKey = "webUserAgent"

    private let log = Logger(subsystem: AppInfo.bundleID, category: "notifications")
    private let notifiedKey = "notifiedThreadTimestamps"   // thread id -> timestamp of the last message notified
    private let lastCheckKey = "lastCheckSummary"
    private var running = false
    private var lastForegroundSync = Date.distantPast

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private init() {}

    // MARK: - Background task

    /// Must be called before the app finishes launching.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let self, let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.scheduleNextCheck()
            let work = Task { await self.checkForNewMessages(reason: "background refresh") }
            refresh.expirationHandler = { work.cancel() }
            Task { refresh.setTaskCompleted(success: await work.value) }
        }
    }

    /// Asks iOS for the next background slot. Submitting again replaces the previous request.
    func scheduleNextCheck() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = nil   // no minimum wait: iOS already spaces these checks out on its own
        do {
            try BGTaskScheduler.shared.submit(request)
            note("Background check scheduled")
        } catch {
            note("Background check not scheduled: \(error.localizedDescription)")
        }
    }

    // MARK: - Permission and badge

    func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                self?.note("Notification permission \(granted ? "granted" : "denied")")
            }
        }
    }

    func clearBadge() {
        let center = UNUserNotificationCenter.current()
        center.setBadgeCount(0)
        center.removeAllDeliveredNotifications()
    }

    /// Posts one test notification, so permission and delivery can be confirmed by eye.
    func postTestNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = "IG DM"
            content.body = "Notifications are working."
            content.sound = .default
            let inThreeSeconds = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
            center.add(UNNotificationRequest(identifier: "test", content: content, trigger: inThreeSeconds))
        }
    }

    // MARK: - Foreground

    /// Called when the app comes to the front and right after login. Fetches the inbox (at most once a
    /// minute) and records everything currently unread as seen, because the user is looking at the inbox.
    /// The next background check then only notifies about messages that arrive after this moment.
    func foregroundSync() {
        guard Date().timeIntervalSince(lastForegroundSync) > 60 else { return }
        lastForegroundSync = Date()
        Task { await checkForNewMessages(reason: "foreground", postNotifications: false) }
    }

    // MARK: - The check

    /// Fetches the inbox with the web view's own cookies and notifies about new unread messages.
    /// Returns false when Instagram could not be reached or answered something unexpected.
    @discardableResult
    func checkForNewMessages(reason: String, postNotifications: Bool = true) async -> Bool {
        guard !running else { return true }
        running = true
        defer { running = false }
        note("CHECK started (\(reason))")

        let center = UNUserNotificationCenter.current()
        let permission = await center.notificationSettings().authorizationStatus
        note("Notification permission: \(Self.describe(permission))")

        let cookies = await Self.instagramCookies()
        guard let session = cookies.first(where: { $0.name == "sessionid" }), !session.value.isEmpty else {
            return finish("skipped: not logged in", success: true)
        }
        let userAgent = UserDefaults.standard.string(forKey: Self.userAgentKey) ?? InboxAPI.fallbackUserAgent
        let csrfToken = cookies.first(where: { $0.name == "csrftoken" })?.value ?? ""
        let request = InboxAPI.request(cookies: cookies, csrfToken: csrfToken, userAgent: userAgent)

        let data: Data
        do {
            let (body, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return finish("failed: no HTTP response", success: false) }
            if http.statusCode == 401 || http.statusCode == 403 || InboxAPI.isLoginRequired(body) {
                if postNotifications { await notifyLoginRequired() }
                return finish("failed: Instagram wants a new login (HTTP \(http.statusCode))", success: false)
            }
            guard http.statusCode == 200 else {
                return finish("failed: Instagram answered HTTP \(http.statusCode)", success: false)
            }
            data = body
        } catch {
            return finish("failed: \(error.localizedDescription)", success: false)
        }

        guard let snapshot = InboxAPI.parse(data) else {
            return finish("failed: unexpected answer: \(InboxAPI.describeUnexpected(data))", success: false)
        }

        var notified = (UserDefaults.standard.dictionary(forKey: notifiedKey) as? [String: Double]) ?? [:]
        let fresh = InboxAPI.newMessages(in: snapshot, alreadyNotified: notified)

        for thread in fresh {
            if postNotifications {
                let content = UNMutableNotificationContent()
                content.title = thread.title
                content.body = thread.preview
                content.sound = .default
                content.threadIdentifier = thread.id
                content.userInfo = ["thread_id": thread.id]
                let identifier = "\(thread.id)-\(Int(thread.lastMessageTimestamp))"
                try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            }
            notified[thread.id] = thread.lastMessageTimestamp
        }
        // Keep the bookkeeping small: forget conversations that are no longer among the newest.
        notified = notified.filter { entry in snapshot.threads.contains { $0.id == entry.key } }
        UserDefaults.standard.set(notified, forKey: notifiedKey)
        if postNotifications {
            try? await center.setBadgeCount(snapshot.unseenCount)
        }
        let verb = postNotifications ? "notified" : "marked as seen"
        return finish("ok: \(snapshot.threads.count) threads, \(snapshot.unseenCount) unseen, \(fresh.count) \(verb)", success: true)
    }

    private func notifyLoginRequired() async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "IG DM"
        content.body = "Instagram signed you out. Open the app to log in again."
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "login-required", content: content, trigger: nil))
        try? await center.setBadgeCount(0)
    }

    private func finish(_ summary: String, success: Bool) -> Bool {
        note("CHECK \(summary)")
        UserDefaults.standard.set("\(Date()) \(summary)", forKey: lastCheckKey)
        return success
    }

    /// Writes to the system log, and in Debug builds also to the console so `devicectl --console` shows it.
    private func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
        #if DEBUG
        print("[IGDM] \(message)")
        #endif
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not asked yet"
        case .denied: return "denied"
        case .authorized: return "allowed"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func instagramCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                    continuation.resume(returning: cookies.filter { $0.domain.hasSuffix("instagram.com") })
                }
            }
        }
    }
}

/// Receives notification taps and hands the conversation to the web view.
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    @Published var pendingThreadID: String?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let threadID = response.notification.request.content.userInfo["thread_id"] as? String
        DispatchQueue.main.async { self.pendingThreadID = threadID }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The app is open, so the inbox already shows new messages; only the test notification is shown.
        completionHandler(notification.request.identifier == "test" ? [.banner, .sound] : [])
    }
}
