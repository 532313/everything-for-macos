import AppKit

/// Everything — instant file search for macOS.
///
/// Entry point: plain AppKit bootstrap (no SwiftUI, no XIB) so the whole app
/// builds with the Xcode command line tools alone.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var signalSources: [DispatchSourceSignal] = []

    /// SIGTERM/SIGINT must still flush the index cache: AppKit's normal
    /// termination path does not run for signals.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                AppController.shared.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        AppController.shared.start()
        MainWindowController.shared.showWindow(nil)
        MainWindowController.shared.window?.makeKeyAndOrderFront(nil)
        MainWindowController.shared.focusSearchField()
        NSApp.activate(ignoringOtherApps: true)

        if let dir = ProcessInfo.processInfo.environment["EVERYTHING_UI_SMOKE"],
           let smoke = UISmokeTest(outputDirectory: dir) {
            smoke.start(controller: MainWindowController.shared)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowController.shared.showWindow(nil)
        }
        MainWindowController.shared.focusSearchField()
        return true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.mainMenu = MainMenuBuilder.build()
application.run()
