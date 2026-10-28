import SwiftUI

@main
@MainActor
struct SCOPECaptureApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var bluetooth = BLERecorder()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(bluetooth)
                .onAppear { model.bluetooth = bluetooth }
        }
    }
}
