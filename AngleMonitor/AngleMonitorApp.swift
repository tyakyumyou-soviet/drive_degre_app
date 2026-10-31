import SwiftUI

@main
struct AngleMonitorApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup { ContentView(model: model) }
    }
}
