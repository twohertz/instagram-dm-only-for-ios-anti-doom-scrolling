import SwiftUI

/// The whole UI: the active account's Instagram web view, edge to edge, plus a brief notice when
/// something is wrong. The account list is a sheet behind a hidden gesture (see `AccountSheet`).
struct ContentView: View {
    @ObservedObject private var profiles = ProfileManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let model = profiles.activeModel
        ZStack(alignment: .bottom) {
            // Same colour as Instagram's page behind the status bar (white / black with the system theme).
            Color(.systemBackground)
                .ignoresSafeArea()

            // The page starts below the status bar and runs to the bottom edge, like Safari.
            WebView(model: model)
                .id(profiles.activeID)
                .ignoresSafeArea(.container, edges: .bottom)

            ProblemNotice(model: model)
        }
        .ignoresSafeArea(.keyboard)   // the web view handles the keyboard itself
        .sheet(isPresented: $profiles.showAccountSheet) { AccountSheet() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { profiles.activeModel.appBecameActive() }
        }
    }
}

/// The short notice shown over the page when something is wrong (for example Instagram refusing to answer).
private struct ProblemNotice: View {
    @ObservedObject var model: WebModel

    var body: some View {
        Group {
            if let problem = model.problem {
                Text(problem)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.problem)
    }
}
