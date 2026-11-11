import DeskShared
import SwiftUI

@main
struct YahaDeskApp: App {
    @StateObject private var device = DeviceStore()
    @StateObject private var cloud = CloudStore()
    @StateObject private var recordings = RecordingStore()
    @StateObject private var ai = AIPolish()
    @StateObject private var phoneMic = PhoneMic()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(device)
                .environmentObject(cloud)
                .environmentObject(recordings)
                .environmentObject(ai)
                .environmentObject(phoneMic)
                .onChange(of: phase) { if phase == .active { Task { await recordings.renew() } } }
        }
    }
}
