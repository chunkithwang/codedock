import SwiftUI

@main
struct CodedockWatchApp: App {
    @StateObject private var connection = WatchConnection()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(connection)
        }
    }
}
