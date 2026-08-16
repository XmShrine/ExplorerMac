import AppKit

/// The 属性 dialog.
///
/// Deliberately styled unlike the rest of the app: Windows 11 never modernised
/// this sheet, so it is still the legacy Win32 dialog — a tab control, a flat
/// grey field, label/value rows separated by etched lines, and 75x23 buttons in
/// the bottom-right corner. Matching Explorer means matching that break in
/// visual language, not smoothing it over.
///
/// One deliberate deviation: Windows keeps this dialog light even in dark mode
/// because it predates theming. Following the app's theme instead reads as
/// intentional rather than broken.
final class PropertiesWindow: NSWindowController, NSWindowDelegate {

    private let urls: [URL]
    private let body = PropertiesBodyView()
    private var scanner: FolderScanner?

    init(urls: [URL]) {
        self.urls = urls
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 396, height: 508),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.delegate = self

        let root = ContainerView()
        window.contentView = root
        root.addSubview(body)
        // Same lift the main window needs: an unowned layer in the content
        // view's sublayer stack otherwise composites over our content.
        body.wantsLayer = true
        body.layer?.zPosition = 1
        root.onLayout = { [weak self] in
            guard let self, let content = window.contentView else { return }
            self.body.frame = content.bounds
        }

        body.title = urls.count == 1
            ? "\(urls[0].lastPathComponent) 属性"
            : "\(urls.count) 个项目 属性"
        body.onClose = { [weak self] in self?.close() }
        body.onApply = { [weak self] in self?.applyChanges() }

        populate()
        fitToContent()
    }

    /// Windows sizes this dialog to its rows; leaving a fixed height would show
    /// a band of empty panel above the buttons.
    private func fitToContent() {
        guard let window else { return }
        var frame = window.frame
        let height = body.preferredHeight
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    private func populate() {
        let manager = FileManager.default
        guard let first = urls.first else { return }

        if urls.count == 1 {
            let values = try? first.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                .creationDateKey, .contentModificationDateKey, .contentAccessDateKey,
            ])
            let isDirectory = values?.isDirectory ?? false

            body.icon = isDirectory
                ? WinIcons.shell(.folder, size: 32)
                : WinIcons.icon(for: syntheticEntry(for: first), size: 32)
            body.name = first.lastPathComponent
            body.nameEditable = true

            var rows: [PropertiesBodyView.Row] = []
            rows.append(.value("文件类型:", typeDescription(for: first, isDirectory: isDirectory)))
            if !isDirectory, let app = NSWorkspace.shared.urlForApplication(toOpen: first) {
                rows.append(.value("打开方式:", manager.displayName(atPath: app.path)))
            }
            rows.append(.separator)
            rows.append(.value("位置:", VolumeMapper.shared.windowsPath(
                from: first.deletingLastPathComponent().path)))

            if isDirectory {
                // A folder's size is the whole subtree, so Explorer shows a
                // running total while it walks.
                rows.append(.value("大小:", "正在计算..."))
                rows.append(.value("占用空间:", "正在计算..."))
                rows.append(.value("包含:", "正在计算..."))
                body.rows = rows + trailingRows(for: first, values: values, isDirectory: true)
                startScan(of: first)
            } else {
                let size = Int64(values?.fileSize ?? 0)
                let allocated = Int64(values?.totalFileAllocatedSize ?? 0)
                rows.append(.value("大小:", sizeText(size)))
                rows.append(.value("占用空间:", sizeText(allocated)))
                body.rows = rows + trailingRows(for: first, values: values, isDirectory: false)
            }
        } else {
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true }.count
            body.icon = WinIcons.shell(.file, size: 32)
            body.name = "\(urls.count - folders) 个文件，\(folders) 个文件夹"
            body.nameEditable = false
            body.rows = [
                .value("类型:", "多种类型"),
                .separator,
                .value("位置:", VolumeMapper.shared.windowsPath(
                    from: first.deletingLastPathComponent().path)),
                .value("大小:", "正在计算..."),
                .separator,
            ]
            startScan(ofAll: urls)
        }
    }

    private func trailingRows(for url: URL, values: URLResourceValues?,
                              isDirectory: Bool) -> [PropertiesBodyView.Row] {
        var rows: [PropertiesBodyView.Row] = [.separator]
        if let created = values?.creationDate {
            rows.append(.value("创建时间:", WinFormat.fullDateString(created)))
        }
        if let modified = values?.contentModificationDate {
            rows.append(.value(isDirectory ? "修改时间:" : "修改时间:",
                               WinFormat.fullDateString(modified)))
        }
        if !isDirectory, let accessed = values?.contentAccessDate {
            rows.append(.value("访问时间:", WinFormat.fullDateString(accessed)))
        }
        rows.append(.separator)

        let readOnly = !FileManager.default.isWritableFile(atPath: url.path)
        let hidden = url.lastPathComponent.hasPrefix(".")
            || (((try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden) ?? false)
        rows.append(.attributes(readOnly: readOnly, hidden: hidden))
        return rows
    }

    /// The list view keys its icon off a `FileEntry`; build a throwaway one so
    /// the dialog shows exactly the same icon the row does.
    private func syntheticEntry(for url: URL) -> FileEntry {
        FileEntry(name: url.lastPathComponent, isDirectory: false, isSymlink: false,
                  isHidden: false, size: 0, modified: Date(), created: Date(), fileID: 0)
    }

    private func typeDescription(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "文件夹" }
        let entry = syntheticEntry(for: url)
        let ext = url.pathExtension.lowercased()
        let name = FileTypeNamer.name(for: entry)
        return ext.isEmpty ? name : "\(name) (.\(ext))"
    }

    private func sizeText(_ bytes: Int64) -> String {
        // Explorer shows the friendly unit and the exact byte count together.
        "\(WinFormat.detailedSize(bytes)) (\(WinFormat.detailedSize(bytes) == "\(bytes) 字节" ? "" : "\(bytes.formattedGrouped) 字节"))"
            .replacingOccurrences(of: " ()", with: "")
    }

    // MARK: - Recursive size

    private func startScan(of folder: URL) { startScan(ofAll: [folder]) }

    private func startScan(ofAll roots: [URL]) {
        let scanner = FolderScanner()
        self.scanner = scanner
        scanner.scan(roots: roots) { [weak self] progress, finished in
            guard let self else { return }
            self.body.updateValue(for: "大小:", to: self.sizeText(progress.bytes))
            self.body.updateValue(for: "占用空间:", to: self.sizeText(progress.allocated))
            self.body.updateValue(
                for: "包含:",
                to: "\(progress.files.formattedGrouped) 个文件，"
                    + "\(progress.folders.formattedGrouped) 个文件夹")
            _ = finished
        }
    }

    // MARK: - Apply

    private func applyChanges() {
        guard urls.count == 1, let url = urls.first else { close(); return }
        let manager = FileManager.default

        if body.nameEditable, !body.name.isEmpty, body.name != url.lastPathComponent {
            _ = try? FileOperations.rename(url, to: body.name)
        }
        if let attributes = body.attributes {
            // 只读 maps onto the write permission bits; 隐藏 onto UF_HIDDEN,
            // which is the flag Explorer's hidden attribute corresponds to.
            if var permissions = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions]
                as? NSNumber {
                var mode = permissions.uint16Value
                if attributes.readOnly { mode &= ~UInt16(0o222) } else { mode |= UInt16(0o200) }
                permissions = NSNumber(value: mode)
                try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
            var values = URLResourceValues()
            values.isHidden = attributes.hidden
            var mutable = url
            try? mutable.setResourceValues(values)
        }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        scanner?.cancel()
        scanner = nil
    }

    private final class ContainerView: NSView {
        var onLayout: (() -> Void)?
        override func layout() { super.layout(); onLayout?() }
    }
}

extension BinaryInteger {
    /// Thousands-grouped, the way Explorer prints byte counts.
    var formattedGrouped: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: Int64(self))) ?? "\(self)"
    }
}

/// Walks a subtree totalling sizes, reporting progress as it goes.
///
/// Reuses the same `getattrlistbulk` enumerator the list view uses, so a large
/// folder totals in roughly the time it takes to list it rather than the time a
/// per-file `stat` walk would need.
final class FolderScanner {

    struct Progress {
        var bytes: Int64 = 0
        var allocated: Int64 = 0
        var files: Int = 0
        var folders: Int = 0
    }

    private let queue = DispatchQueue(label: "ExplorerMac.foldersize", qos: .utility)
    private var cancelled = false
    private let lock = NSLock()

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func scan(roots: [URL], progress: @escaping (Progress, Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var total = Progress()
            var lastReport = Date.distantPast

            func report(_ finished: Bool) {
                let snapshot = total
                DispatchQueue.main.async { progress(snapshot, finished) }
            }

            var stack = roots
            while let current = stack.popLast() {
                if self.isCancelled { return }

                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: current.path,
                                                     isDirectory: &isDirectory) else { continue }
                if !isDirectory.boolValue {
                    let size = Int64((try? current.resourceValues(forKeys: [.fileSizeKey]))?
                        .fileSize ?? 0)
                    total.files += 1
                    total.bytes += size
                    total.allocated += Self.allocated(size)
                    continue
                }

                _ = FSEnumerator.enumerate(path: current.path, batch: { entries in
                    for entry in entries {
                        if entry.isDirectory {
                            total.folders += 1
                            stack.append(current.appendingPathComponent(entry.name))
                        } else {
                            total.files += 1
                            total.bytes += entry.size
                            total.allocated += Self.allocated(entry.size)
                        }
                    }
                }, shouldStop: { self.isCancelled })

                // Throttle so a huge tree does not flood the main thread.
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    report(false)
                }
            }
            guard !self.isCancelled else { return }
            report(true)
        }
    }

    /// Windows' 占用空间 is the size rounded up to the allocation unit. APFS
    /// clones and compression can make the true figure smaller; this is the
    /// number Explorer would print.
    private static func allocated(_ size: Int64) -> Int64 {
        let unit: Int64 = 4096
        return size == 0 ? 0 : ((size + unit - 1) / unit) * unit
    }
}
