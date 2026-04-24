import SwiftUI

@main
struct LokaVoxApp: App {
    @State private var viewModel = TranscriptionViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(vm: viewModel)
                .onOpenURL { url in
                    guard url.scheme == "lokavox", url.host == "record" else { return }
                    Task { await viewModel.handleRecordRequest() }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        viewModel.handleAppBackgrounded()
                    }
                }
        }
    }
}
