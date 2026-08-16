import AppKit

/// Copy / move / delete / rename, with Explorer's conflict handling.
///
/// Work runs on a background queue so a large copy never blocks the window.
/// When a name collides the queue blocks on a prompt presented on the main
/// thread, which is what lets the "对所有冲突执行此操作" checkbox work: the
/// answer is remembered and later collisions skip the prompt entirely.
enum FileOperations {

    enum Resolution {
        case replace, skip, keepBoth, cancel
    }

    struct Outcome {
        var succeeded = 0
        var skipped = 0
        var failures: [(url: URL, error: Error)] = []
        /// What actually happened on disk, for the undo history.
        var steps: [UndoStep] = []
    }

    private static let queue = DispatchQueue(label: "ExplorerMac.fileops", qos: .userInitiated)

    // MARK: - Names

    /// Windows' "保留两者" naming: "报告.txt" becomes "报告 (2).txt", and it keeps
    /// counting until the name is free. Folders get the suffix after the whole
    /// name since they have no extension to protect.
    static func uniqueURL(for url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// "新建文件夹", then "新建文件夹 (2)" — Explorer's naming for a new folder.
    static func newFolderURL(in directory: String) -> URL {
        uniqueURL(for: URL(fileURLWithPath: directory).appendingPathComponent("新建文件夹"))
    }

    // MARK: - Operations

    static func copy(_ urls: [URL], to directory: String,
                     presenter: NSWindow?,
                     completion: @escaping (Outcome) -> Void) {
        transfer(urls, to: directory, move: false, presenter: presenter, completion: completion)
    }

    static func move(_ urls: [URL], to directory: String,
                     presenter: NSWindow?,
                     completion: @escaping (Outcome) -> Void) {
        transfer(urls, to: directory, move: true, presenter: presenter, completion: completion)
    }

    private static func transfer(_ urls: [URL], to directory: String, move: Bool,
                                 presenter: NSWindow?,
                                 completion: @escaping (Outcome) -> Void) {
        queue.async {
            let manager = FileManager.default
            let destinationDirectory = URL(fileURLWithPath: directory)
            var outcome = Outcome()
            var blanketResolution: Resolution?

            for source in urls {
                var destination = destinationDirectory
                    .appendingPathComponent(source.lastPathComponent)

                // Moving something onto itself is a no-op, not an error.
                if move, source.path == destination.path {
                    outcome.skipped += 1
                    continue
                }
                // Copying into the same folder is Explorer's "make a duplicate".
                if !move, source.path == destination.path {
                    destination = uniqueURL(for: destination)
                }

                if manager.fileExists(atPath: destination.path) {
                    let resolution = blanketResolution
                        ?? askResolution(name: source.lastPathComponent,
                                         presenter: presenter,
                                         remembered: { blanketResolution = $0 })
                    switch resolution {
                    case .cancel:
                        DispatchQueue.main.async { completion(outcome) }
                        return
                    case .skip:
                        outcome.skipped += 1
                        continue
                    case .keepBoth:
                        destination = uniqueURL(for: destination)
                    case .replace:
                        // Replacing a directory needs it gone first; replaceItemAt
                        // only handles files.
                        try? manager.removeItem(at: destination)
                    }
                }

                do {
                    if move {
                        try manager.moveItem(at: source, to: destination)
                        outcome.steps.append(.moved(from: source, to: destination))
                    } else {
                        try manager.copyItem(at: source, to: destination)
                        outcome.steps.append(.created(destination))
                    }
                    outcome.succeeded += 1
                } catch {
                    outcome.failures.append((source, error))
                }
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Delete key: to the Trash, which is Explorer's Recycle Bin.
    static func trash(_ urls: [URL], completion: @escaping (Outcome) -> Void) {
        queue.async {
            var outcome = Outcome()
            for url in urls {
                do {
                    // The resulting URL is what makes 撤销 删除 possible; without
                    // it there is no way back out of the Trash.
                    var landed: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
                    if let inTrash = landed as URL? {
                        outcome.steps.append(.trashed(original: url, inTrash: inTrash))
                    }
                    outcome.succeeded += 1
                } catch {
                    outcome.failures.append((url, error))
                }
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Shift+Delete: gone for good.
    static func deletePermanently(_ urls: [URL], completion: @escaping (Outcome) -> Void) {
        queue.async {
            var outcome = Outcome()
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                    outcome.succeeded += 1
                } catch {
                    outcome.failures.append((url, error))
                }
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    static func rename(_ url: URL, to name: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination.path != url.path else { return url }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func createFolder(in directory: String) throws -> URL {
        let url = newFolderURL(in: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func createFile(in directory: String, name: String) throws -> URL {
        let url = uniqueURL(for: URL(fileURLWithPath: directory).appendingPathComponent(name))
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    // MARK: - Conflict prompt

    /// Blocks the worker queue while the sheet is up. Safe because the prompt
    /// is dispatched to the main thread and this never runs on it.
    private static func askResolution(name: String, presenter: NSWindow?,
                                      remembered: @escaping (Resolution) -> Void) -> Resolution {
        var choice: Resolution = .cancel
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "目标已包含名为“\(name)”的文件"
            alert.informativeText = "请选择要保留的文件。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "替换目标中的文件")
            alert.addButton(withTitle: "跳过该文件")
            alert.addButton(withTitle: "保留两者")
            alert.addButton(withTitle: "取消")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "为所有当前冲突执行此操作"

            let response: NSApplication.ModalResponse
            if let presenter {
                // A sheet would need an async completion handler, and the worker
                // is already blocked; a modal keeps the flow linear.
                NSApp.activate(ignoringOtherApps: true)
                presenter.makeKeyAndOrderFront(nil)
                response = alert.runModal()
            } else {
                response = alert.runModal()
            }

            switch response {
            case .alertFirstButtonReturn:  choice = .replace
            case .alertSecondButtonReturn: choice = .skip
            case .alertThirdButtonReturn:  choice = .keepBoth
            default:                       choice = .cancel
            }
            if alert.suppressionButton?.state == .on, choice != .cancel {
                remembered(choice)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return choice
    }

    // MARK: - Reporting

    static func report(_ outcome: Outcome, verb: String, in window: NSWindow?) {
        guard !outcome.failures.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "无法\(verb)\(outcome.failures.count) 个项目"
        alert.informativeText = outcome.failures.prefix(5)
            .map { "\($0.url.lastPathComponent)：\($0.error.localizedDescription)" }
            .joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
