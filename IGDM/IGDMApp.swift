import SwiftUI
import UserNotifications

enum AppInfo {
    /// The app's bundle identifier, used for the log subsystem and the background task name.
    static let bundleID = Bundle.main.bundleIdentifier ?? "igdm"
}

@main
struct IGDMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DMNotifier.shared.registerBackgroundTask()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        #if DEBUG
        let arguments = CommandLine.arguments
        if arguments.contains("-checkNow") {
            Task { await DMNotifier.shared.checkAllProfiles(reason: "launch argument", postNotifications: false) }
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
            case .background:
                DMNotifier.shared.scheduleNextCheck()
                ProfileManager.shared.updateShortcutItems()
            case .active:
                DMNotifier.shared.clearBadge()
            default:
                break
            }
        }
    }
}

/// Only here so the scene delegate below can receive Home Screen quick actions.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// Home Screen quick actions (long-press on the app icon) arrive here, both on a cold start and while running.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            ProfileManager.shared.handle(item)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(ProfileManager.shared.handle(shortcutItem))
    }
}
