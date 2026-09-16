import Foundation
import BackgroundTasks
import UserNotifications
import WebKit
import os

/// Checks every account's DM inbox while the app is in the background (whenever iOS grants a
/// "Background App Refresh" slot) and posts a local notification for every conversation with a new
/// unread message from someone else.
///
/// iOS decides when these checks run: usually every 15 to 60 minutes while the phone is in normal use,
/// less often overnight or when the app is rarely opened, and never if the app was force-quit.
final class DMNotifier {
    static let shared = DMNotifier()
    static let taskIdentifier = AppInfo.bundleID + ".refresh"
    static let userAgentKey = "webUserAgent"

    private let log = Logger(subsystem: AppInfo.bundleID, category: "notifications")
    private let lastCheckKey = "lastCheckSummary"
    private var runningAll = false
    private var inProgress: Set<UUID> = []
    private var lastForegroundSync: [UUID: Date] = [:]

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
            let work = Task { await self.checkAllProfiles(reason: "background refresh") }
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

    /// Drops the bookkeeping of a removed account.
    func forget(profileID: UUID) {
        UserDefaults.standard.removeObject(forKey: notifiedKey(for: profileID))
    }

    // MARK: - Foreground

    /// Called when an account's inbox comes to the front and right after its login. Fetches that inbox
    /// (at most once a minute) and records everything currently unread as seen, because the user is
    /// looking at it. The next background check then only notifies about messages that arrive afterwards.
    func foregroundSync(profile: Profile) {
        let last = lastForegroundSync[profile.id] ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 else { return }
        lastForegroundSync[profile.id] = Date()
        Task { await check(profile: profile, postNotifications: false) }
    }

    // MARK: - The checks

    /// Checks every account. Used by the background task and by the `-checkNow` launch argument.
    @discardableResult
    func checkAllProfiles(reason: String, postNotifications: Bool = true) async -> Bool {
        guard !runningAll else { return true }
        runningAll = true
        defer { runningAll = false }

        let profiles = Profile.loadAll()
        note("CHECK ALL started (\(reason)), \(profiles.count) account(s)")
        let permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        note("Notification permission: \(Self.describe(permission))")

        var allSucceeded = true
        var unseenTotal = 0
        for profile in profiles {
            let result = await check(profile: profile, postNotifications: postNotifications)
            allSucceeded = allSucceeded && result.success
            unseenTotal += result.unseen
        }
        if postNotifications {
            try? await UNUserNotificationCenter.current().setBadgeCount(unseenTotal)
        }
        return allSucceeded
    }

    struct CheckResult {
        let success: Bool
        let unseen: Int
    }

    /// Fetches one account's inbox with that account's cookies and notifies about new unread messages.
    @discardableResult
    func check(profile: Profile, postNotifications: Bool) async -> CheckResult {
        guard !inProgress.contains(profile.id) else { return CheckResult(success: true, unseen: 0) }
        inProgress.insert(profile.id)
        defer { inProgress.remove(profile.id) }
        let tag = "[\(profile.name)]"

        let cookies = await Self.instagramCookies(for: profile)
        guard let session = cookies.first(where: { $0.name == "sessionid" }), !session.value.isEmpty else {
            return finish(tag, "skipped: not logged in", success: true)
        }
        let userAgent = UserDefaults.standard.string(forKey: Self.userAgentKey) ?? InboxAPI.fallbackUserAgent
        let csrfToken = cookies.first(where: { $0.name == "csrftoken" })?.value ?? ""
        let request = InboxAPI.request(cookies: cookies, csrfToken: csrfToken, userAgent: userAgent)
        let accountCount = Profile.loadAll().count

        let data: Data
        do {
            let (body, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return finish(tag, "failed: no HTTP response", success: false)
            }
            if http.statusCode == 401 || http.statusCode == 403 || InboxAPI.isLoginRequired(body) {
                if postNotifications { await notifyLoginRequired(profile: profile, accountCount: accountCount) }
                return finish(tag, "failed: Instagram wants a new login (HTTP \(http.statusCode))", success: false)
            }
            guard http.statusCode == 200 else {
                return finish(tag, "failed: Instagram answered HTTP \(http.statusCode)", success: false)
            }
            data = body
        } catch {
            return finish(tag, "failed: \(error.localizedDescription)", success: false)
        }

        guard let snapshot = InboxAPI.parse(data) else {
            return finish(tag, "failed: unexpected answer: \(InboxAPI.describeUnexpected(data))", success: false)
        }

        // The account's Instagram username names the profile in the account list and quick actions.
        if let username = snapshot.viewerUsername, !username.isEmpty {
            DispatchQueue.main.async { ProfileManager.shared.rename(profile.id, to: username) }
        }

        let key = notifiedKey(for: profile.id)
        var notified = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let fresh = InboxAPI.newMessages(in: snapshot, alreadyNotified: notified)
        let center = UNUserNotificationCenter.current()

        for thread in fresh {
            if postNotifications {
                let content = UNMutableNotificationContent()
                content.title = thread.title
                if accountCount > 1 { content.subtitle = profile.name }
                content.body = thread.preview
                content.sound = .default
                content.threadIdentifier = "\(profile.id.uuidString)-\(thread.id)"
                content.userInfo = ["thread_id": thread.id, "profile_id": profile.id.uuidString]
                let identifier = "\(profile.id.uuidString)-\(thread.id)-\(Int(thread.lastMessageTimestamp))"
                try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            }
            notified[thread.id] = thread.lastMessageTimestamp
        }
        // Keep the bookkeeping small: forget conversations that are no longer among the newest.
        notified = notified.filter { entry in snapshot.threads.contains { $0.id == entry.key } }
        UserDefaults.standard.set(notified, forKey: key)

        let verb = postNotifications ? "notified" : "marked as seen"
        _ = finish(tag, "ok: \(snapshot.threads.count) threads, \(snapshot.unseenCount) unseen, \(fresh.count) \(verb)", success: true)
        return CheckResult(success: true, unseen: snapshot.unseenCount)
    }

    private func notifyLoginRequired(profile: Profile, accountCount: Int) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "IG DM"
        content.body = accountCount > 1
            ? "Instagram signed out \(profile.name). Open the app to log in again."
            : "Instagram signed you out. Open the app to log in again."
        content.sound = .default
        content.userInfo = ["profile_id": profile.id.uuidString]
        let identifier = "login-required-\(profile.id.uuidString)"
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func notifiedKey(for profileID: UUID) -> String {
        "notifiedThreadTimestamps.\(profileID.uuidString)"
    }

    private func finish(_ tag: String, _ summary: String, success: Bool) -> CheckResult {
        note("CHECK \(tag) \(summary)")
        UserDefaults.standard.set("\(Date()) \(tag) \(summary)", forKey: lastCheckKey)
        return CheckResult(success: success, unseen: 0)
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

    private static func instagramCookies(for profile: Profile) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                profile.dataStore.httpCookieStore.getAllCookies { cookies in
                    continuation.resume(returning: cookies.filter { $0.domain.hasSuffix("instagram.com") })
                }
            }
        }
    }
}

/// Receives notification taps and hands the account and conversation to the UI.
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    @Published var pendingProfileID: UUID?
    @Published var pendingThreadID: String?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let profileID = (info["profile_id"] as? String).flatMap(UUID.init(uuidString:))
        let threadID = info["thread_id"] as? String
        DispatchQueue.main.async {
            self.pendingProfileID = profileID
            self.pendingThreadID = threadID
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The app is open, so the inbox already shows new messages; only the test notification is shown.
        completionHandler(notification.request.identifier == "test" ? [.banner, .sound] : [])
    }
}
