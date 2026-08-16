import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fonts must be registered before any view measures text, otherwise
        // the first layout pass caches metrics from the fallback face.
        FontManager.bootstrap()

        // Explorer follows the Windows theme; here that maps onto the macOS
        // appearance. `--dark` / `--light` pin it for checking both renderings.
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }

        let controller = MainWindowController()
        self.controller = controller
        controller.window?.center()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let path = Self.snapshotPath() {
            scheduleSnapshot(to: path)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Snapshot mode

    /// `--snapshot <file.png> [--path <dir>]` writes a capture of the window and
    /// exits, so the rendering can be inspected without granting Screen
    /// Recording to the terminal.
    private static func snapshotPath() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    private func scheduleSnapshot(to path: String) {
        // Anything that has to settle before the capture is kicked off here,
        // not inside `writeSnapshot`. The main queue is serial: while the
        // capture block runs, no other main-queue work can, so async results
        // scheduled from a background queue would never land in time.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--search"), index + 1 < args.count {
            let query = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.controller?.debugSearch(query)
            }
        }
        // Give the background enumeration a beat to deliver its first batches.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.writeSnapshot(to: path)
            NSApp.terminate(nil)
        }
    }

    /// Asks the window server for the pixels it actually composited for this
    /// window.
    ///
    /// The obvious alternatives both lie. Re-running the view hierarchy through
    /// `dataWithPDF` or `cacheDisplay` reports what the views *would* draw, and
    /// happily showed a perfect window while the real one was missing its whole
    /// top half — that discrepancy hid a compositing bug for a long time.
    /// Rendering the layer tree with `CALayer.render(in:)` is closer but still
    /// not what reaches the screen. Only this is ground truth.
    private func writeSnapshot(to path: String) {
        guard let window = controller?.window else { return }

        // `--menu file|empty` captures the context-menu panel instead of the
        // main window; the menu has its own window and never appears in a
        // capture of the browser.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--properties"), index + 1 < args.count,
           let number = controller?.debugShowProperties(onItem: args[index + 1] == "file") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            capture(windowNumber: number, to: path)
            return
        }
        if let index = args.firstIndex(of: "--menu"), index + 1 < args.count,
           let number = controller?.debugShowContextMenu(onItem: args[index + 1] == "file") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            capture(windowNumber: number, to: path)
            return
        }
        capture(windowNumber: window.windowNumber, to: path)
    }

    private func capture(windowNumber: Int, to path: String) {
        guard let shot = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(windowNumber),
            [.boundsIgnoreFraming, .bestResolution]) else {
            FileHandle.standardError.write("window capture failed\n".data(using: .utf8)!)
            return
        }
        let rep = NSBitmapImageRep(cgImage: shot)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(
            "snapshot \(shot.width)x\(shot.height) -> \(path)\n".data(using: .utf8)!)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
