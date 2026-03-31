import SwiftUI

struct RootView: View {
    let store: RemoteOSAppStore

    var body: some View {
        Group {
            if store.hasPersistedClientSession {
                SessionView(store: store)
            } else {
                PairingView(store: store)
            }
        }
        .background(Color.roBackground)
        .preferredColorScheme(.dark)
        .tint(Color.roAccent)
    }
}
