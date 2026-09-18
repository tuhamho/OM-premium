import SwiftUI

@main
struct OfflineMusicApp: App {
    @StateObject private var store = MusicStore()
    @StateObject private var player = AudioPlayerService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .task {
                    await store.load()
                    player.configure(with: store)
                }
        }
    }
}
