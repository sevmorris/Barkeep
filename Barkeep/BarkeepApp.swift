import SwiftUI

/// Decides, before anything else runs, whether this launch is the app or only
/// the host for the unit tests.
///
/// Xcode runs the tests inside this app, so a test run used to launch all of
/// it: AppState resolved the saved Brewfile bookmark from the app's real
/// defaults and wrote it straight back — or removed it, if it no longer
/// resolved — the window parsed that Brewfile and started watching it, the
/// launch checked for updates, and SwiftUI recorded the window's frame.
/// Hosting tests, the app now starts with no window, no AppState and no
/// update check.
@main
enum AppLauncher {
    static func main() {
        if isHostingTests {
            TestHostApp.main()
        } else {
            BarkeepApp.main()
        }
    }

    /// XCTest is already loaded when main() runs in a test host — Swift
    /// Testing's included — and is never linked into the app itself. The
    /// session identifier is Xcode's own mark of a test launch, checked as
    /// well in case XCTest ever loads later.
    static let isHostingTests =
        NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
}

/// A scene with no window: while the app hosts the tests, nothing of the real
/// app is built.
private struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

extension UserDefaults {
    /// Where the app keeps what it stores in defaults. It is the app's own
    /// domain — except in a test run, where `.standard` is that same domain,
    /// the developer's real settings, because the tests run inside the app.
    /// A test run gets a scratch suite in its place, so a test that forgets
    /// to pass a store of its own still cannot reach the real one. Nothing in
    /// the app names `.standard`; it goes through here.
    ///
    /// The scratch suite is named by a path in the temporary folder, which
    /// keeps its file out of ~/Library/Preferences, where the App Preferences
    /// source's io.github.sevmorris.* pattern would back it up.
    static let app: UserDefaults = AppLauncher.isHostingTests
        ? UserDefaults(suiteName: FileManager.default.temporaryDirectory
            .appendingPathComponent("io.github.sevmorris.Barkeep.tests").path)!
        : .standard
}

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
        .windowToolbarStyle(.unified)
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
    static let barkeepRefresh          = Notification.Name("barkeepRefresh")

}
