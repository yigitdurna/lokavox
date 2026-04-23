import SwiftUI

@main
struct LokaVoxApp: App {
    @State private var viewModel = TranscriptionViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(vm: viewModel)
        }
    }
}
