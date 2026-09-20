import SwiftUI

@main
struct OfflineMusicApp: App {
    @StateObject private var store = MusicStore()
    @StateObject private var player = AudioPlayerService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = PerformanceDiagnostics.launchStartedAt
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(player)
                .preferredColorScheme(store.theme.colorScheme)
                .tint(store.accentChoice.color)
                .task {
                    await store.load()
                    player.configure(with: store)
                    store.attach(player: player)
                    Task { @MainActor in
                        await store.reconcileDocumentsInBackground()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        player.persistPosition()
                    }
                }
        }
    }
}
