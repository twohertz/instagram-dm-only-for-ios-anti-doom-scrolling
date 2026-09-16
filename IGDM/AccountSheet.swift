import SwiftUI

/// Hidden behind a three-finger tap or a two-finger hold on the page: switch, add or remove accounts.
struct AccountSheet: View {
    @ObservedObject private var profiles = ProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var removal: Profile?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            profiles.switchTo(profile.id)
                            dismiss()
                        } label: {
                            HStack {
                                Label(profile.name, systemImage: "person.crop.circle")
                                Spacer()
                                if profile.id == profiles.activeID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        if let index = offsets.first { removal = profiles.profiles[index] }
                    }
                } footer: {
                    Text("Swipe left on an account to remove it from this app, which logs it out here. You can also switch by long-pressing the app icon on the Home Screen.")
                }

                if profiles.profiles.count < ProfileManager.maxProfiles {
                    Section {
                        Button {
                            profiles.addProfile()
                            dismiss()
                        } label: {
                            Label("Add account", systemImage: "plus.circle")
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .confirmationDialog("Remove \(removal?.name ?? "this account")?",
                            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                            titleVisibility: .visible) {
            Button("Remove and log out", role: .destructive) {
                if let removal { profiles.remove(removal.id) }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("The login saved for this account is deleted from the app. Instagram itself is not affected.")
        }
    }
}
