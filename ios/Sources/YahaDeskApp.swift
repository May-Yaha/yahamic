import SwiftUI

@main
struct YahaDeskApp: App {
    @StateObject private var device = DeviceStore()
    @StateObject private var cloud = CloudStore()
    @StateObject private var recordings = RecordingStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(device)
                .environmentObject(cloud)
                .environmentObject(recordings)
        }
    }
}
