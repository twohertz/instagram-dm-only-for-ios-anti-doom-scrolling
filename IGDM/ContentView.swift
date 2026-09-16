import SwiftUI

/// The whole UI: the Instagram web view, edge to edge, plus a brief notice when something is wrong.
struct ContentView: View {
    @StateObject private var model = WebModel()
    @ObservedObject private var router = NotificationRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            // Same colour as Instagram's page behind the status bar (white / black with the system theme).
            Color(.systemBackground)
                .ignoresSafeArea()

            // The page starts below the status bar and runs to the bottom edge, like Safari.
            WebView(model: model)
                .ignoresSafeArea(.container, edges: .bottom)

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
        .ignoresSafeArea(.keyboard)   // the web view handles the keyboard itself
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.appBecameActive()
                openPendingThread()
            }
        }
        .onChange(of: router.pendingThreadID) { _, _ in openPendingThread() }
        .onAppear(perform: openPendingThread)
    }

    /// A tapped notification carries the conversation to open.
    private func openPendingThread() {
        guard let id = router.pendingThreadID else { return }
        router.pendingThreadID = nil
        model.open(threadID: id)
    }
}
