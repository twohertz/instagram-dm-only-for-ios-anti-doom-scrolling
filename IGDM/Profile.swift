import Foundation
import UIKit
import WebKit
import os

/// One Instagram login inside the app. Each profile has its own cookie jar (website data store),
/// so several accounts stay logged in at the same time.
struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// nil means the app's original data store, so the first account keeps the login it already had.
    let storeIdentifier: UUID?

    /// The cookie jar for this account. WebKit objects must be used on the main thread.
    var dataStore: WKWebsiteDataStore {
        if let storeIdentifier { return WKWebsiteDataStore(forIdentifier: storeIdentifier) }
        return .default()
    }

    /// Deletes everything saved for this account (cookies, caches). Nothing may still be using the store.
    func wipe(completion: @escaping (Error?) -> Void) {
        if let storeIdentifier {
            WKWebsiteDataStore.remove(forIdentifier: storeIdentifier, completionHandler: completion)
        } else {
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                     modifiedSince: .distantPast) { completion(nil) }
        }
    }

    // MARK: - Persistence (plain UserDefaults, readable from any thread)

    private static let profilesKey = "profiles"
    private static let activeKey = "activeProfileID"

    static func loadAll() -> [Profile] {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([Profile].self, from: data),
           !profiles.isEmpty {
            return profiles
        }
        let first = [Profile(id: UUID(), name: "Account 1", storeIdentifier: nil)]
        saveAll(first)
        return first
    }

    static func saveAll(_ profiles: [Profile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    static func loadActiveID(in profiles: [Profile]) -> UUID {
        if let raw = UserDefaults.standard.string(forKey: activeKey), let id = UUID(uuidString: raw),
           profiles.contains(where: { $0.id == id }) {
            return id
        }
        return profiles[0].id
    }

    static func saveActiveID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: activeKey)
    }
}

/// Keeps the list of accounts, the active one, and one live web view per account. Main thread only.
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
    static let maxProfiles = 5

    @Published private(set) var profiles: [Profile]
    @Published private(set) var activeID: UUID
    @Published var showAccountSheet = false

    private var models: [UUID: WebModel] = [:]
    private let log = Logger(subsystem: AppInfo.bundleID, category: "profiles")

    private init() {
        let loaded = Profile.loadAll()
        profiles = loaded
        activeID = Profile.loadActiveID(in: loaded)
        updateShortcutItems()
    }

    var activeProfile: Profile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    var activeModel: WebModel {
        model(for: activeProfile)
    }

    func model(for profile: Profile) -> WebModel {
        if let existing = models[profile.id] { return existing }
        let model = WebModel(profile: profile)
        model.onAccountsGesture = { [weak self] in self?.showAccountSheet = true }
        models[profile.id] = model
        return model
    }

    func switchTo(_ id: UUID) {
        guard id != activeID, let profile = profiles.first(where: { $0.id == id }) else { return }
        activeID = id
        Profile.saveActiveID(id)
        log.notice("PROFILE switched to \(profile.name, privacy: .public)")
    }

    @discardableResult
    func addProfile() -> Profile? {
        guard profiles.count < Self.maxProfiles else { return nil }
        let profile = Profile(id: UUID(), name: "Account \(profiles.count + 1)", storeIdentifier: UUID())
        profiles.append(profile)
        Profile.saveAll(profiles)
        log.notice("PROFILE added \(profile.name, privacy: .public)")
        switchTo(profile.id)
        updateShortcutItems()
        return profile
    }

    /// Removes the account from the app and deletes its saved login. The last account is replaced by an empty one.
    func remove(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let profile = profiles[index]
        models[id] = nil                       // lets its web view go away
        profiles.remove(at: index)
        if profiles.isEmpty {
            profiles = [Profile(id: UUID(), name: "Account 1", storeIdentifier: UUID())]
        }
        Profile.saveAll(profiles)
        if activeID == id {
            activeID = profiles[0].id
            Profile.saveActiveID(activeID)
        }
        updateShortcutItems()
        log.notice("PROFILE removed \(profile.name, privacy: .public)")
        // Give the old web view a moment to disappear before its data is deleted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [log] in
            profile.wipe { error in
                if let error {
                    log.error("PROFILE wipe failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    log.notice("PROFILE data deleted for \(profile.name, privacy: .public)")
                }
            }
        }
    }

    /// Called once the Instagram username of an account is known.
    func rename(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles[index].name != name else { return }
        profiles[index].name = name
        Profile.saveAll(profiles)
        updateShortcutItems()
    }

    // MARK: - Home Screen quick actions (long-press the app icon)

    private static let switchAction = "profile.switch"
    private static let addAction = "profile.add"

    func updateShortcutItems() {
        var items = profiles.prefix(4).map { profile in
            UIApplicationShortcutItem(type: Self.switchAction,
                                      localizedTitle: profile.name,
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "person.crop.circle"),
                                      userInfo: ["profile_id": profile.id.uuidString as NSString])
        }
        if profiles.count < 4, profiles.count < Self.maxProfiles {
            items.append(UIApplicationShortcutItem(type: Self.addAction,
                                                   localizedTitle: "Add account",
                                                   localizedSubtitle: nil,
                                                   icon: UIApplicationShortcutIcon(systemImageName: "plus.circle"),
                                                   userInfo: nil))
        }
        UIApplication.shared.shortcutItems = items
    }

    /// Returns true when the quick action was understood.
    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        switch item.type {
        case Self.switchAction:
            guard let raw = item.userInfo?["profile_id"] as? String, let id = UUID(uuidString: raw) else { return false }
            switchTo(id)
            return true
        case Self.addAction:
            addProfile()
            return true
        default:
            return false
        }
    }
}
