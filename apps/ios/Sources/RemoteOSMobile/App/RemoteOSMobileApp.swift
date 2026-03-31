import SwiftUI

@main
struct RemoteOSMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = RemoteOSAppStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .task {
                    await store.refreshHealth()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task {
                        await store.handleScenePhase(newPhase)
                    }
                }
        }
    }
}
