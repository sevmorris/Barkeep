import SwiftUI

@main
struct BarkeepApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environment(appState)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    await checkForUpdates(silent: true, appState: appState)
                }
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Barkeep Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await checkForUpdates(silent: false, appState: appState) }
                }
            }

            CommandGroup(after: .newItem) {
                Button("Choose Brewfile…") {
                    appState.showBrewfilePicker = true
                }
                .keyboardShortcut("O", modifiers: .command)

                Button("Refresh") {
                    NotificationCenter.default.post(name: .barkeepRefresh, object: nil)
                }
                .keyboardShortcut("R", modifiers: .command)
            }
        }

        Window("Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
    }
}

extension Notification.Name {
    static let barkeepRefresh = Notification.Name("barkeepRefresh")
}
