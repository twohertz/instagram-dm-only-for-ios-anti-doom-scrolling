import SwiftUI
import UserNotifications

enum AppInfo {
    /// The app's bundle identifier, used for the log subsystem and the background task name.
    static let bundleID = Bundle.main.bundleIdentifier ?? "igdm"
}

@main
struct IGDMApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DMNotifier.shared.registerBackgroundTask()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        #if DEBUG
        let arguments = CommandLine.arguments
        if arguments.contains("-checkNow") {
            Task { await DMNotifier.shared.checkForNewMessages(reason: "launch argument", postNotifications: false) }
        }
        if arguments.contains("-testNotification") {
            DMNotifier.shared.postTestNotification()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: DMNotifier.shared.scheduleNextCheck()
            case .active:
                DMNotifier.shared.clearBadge()
                DMNotifier.shared.foregroundSync()
            default: break
            }
        }
    }
}
