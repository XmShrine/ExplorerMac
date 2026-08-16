import AppKit
import QuickLookThumbnailing

/// Thumbnails for the file list.
///
/// Explorer swaps the generic type icon for a real preview on anything with
/// visual content, even at the 16pt size the details view uses. The rules that
/// keep it cheap: only ask for types that can actually produce a preview, never
/// block a draw pass, and let a scroll invalidate requests that are no longer
/// on screen — otherwise flicking through a folder of ten thousand photos
/// queues ten thousand generations for rows nobody is looking at any more.
final class ThumbnailProvider {

    static let shared = ThumbnailProvider()

    /// Bounded so a huge folder cannot grow the cache without limit; the number
    /// is generous next to a screenful of rows.
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2048
        return cache
    }()

    /// Keys currently being generated, so repeated draw passes over the same
    /// row do not queue the work again.
    private var inFlight: Set<String> = []
    /// Keys that produced nothing; retrying them on every scroll would be pure
    /// waste.
    private var failed: Set<String> = []
    private let lock = NSLock()

    /// Bumped whenever the listing changes. Results tagged with a stale
    /// generation are dropped instead of painting over the new contents.
    private var generation: Int64 = 0

    private let generator = QLThumbnailGenerator.shared

    private init() {}

    /// Extensions worth asking Quick Look about. Everything else keeps its
    /// type icon, which is both faster and what Explorer shows.
    private static let previewable: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "heif", "tiff", "tif",
        "svg", "ico", "icns", "psd", "raw", "cr2", "nef", "arw", "dng",
        "pdf", "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv",
        "key", "pages", "numbers", "app",
    ]

    static func canPreview(_ entry: FileEntry) -> Bool {
        !entry.isDirectory && previewable.contains(entry.ext)
    }

    func invalidateAll() {
        lock.lock()
        generation &+= 1
        inFlight.removeAll()
        failed.removeAll()
        lock.unlock()
    }

    private func key(for url: URL, entry: FileEntry, size: CGFloat) -> String {
        // Modification time is part of the key so an edited file re-renders
        // rather than serving a stale preview.
        "\(url.path)|\(entry.modified.timeIntervalSince1970)|\(entry.size)|\(Int(size))"
    }

    /// Returns a cached thumbnail immediately, or nil after scheduling one.
    /// `onReady` fires on the main thread only if the request is still current.
    func thumbnail(for url: URL, entry: FileEntry, size: CGFloat,
                   onReady: @escaping () -> Void) -> NSImage? {
        guard Self.canPreview(entry) else { return nil }
        let cacheKey = key(for: url, entry: entry, size: size)

        if let hit = cache.object(forKey: cacheKey as NSString) { return hit }

        lock.lock()
        if inFlight.contains(cacheKey) || failed.contains(cacheKey) {
            lock.unlock()
            return nil
        }
        inFlight.insert(cacheKey)
        let requestGeneration = generation
        lock.unlock()

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail)

        generator.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let self else { return }
            self.lock.lock()
            self.inFlight.remove(cacheKey)
            let stale = requestGeneration != self.generation
            if representation == nil { self.failed.insert(cacheKey) }
            self.lock.unlock()

            guard !stale, let representation else { return }
            // Keep the generated pixel dimensions rather than forcing a square:
            // the caller letterboxes, and a square NSImage would stretch a wide
            // photo to fit the cell.
            let cgImage = representation.cgImage
            let image = NSImage(cgImage: cgImage,
                                size: NSSize(width: CGFloat(cgImage.width) / scale,
                                             height: CGFloat(cgImage.height) / scale))
            self.cache.setObject(image, forKey: cacheKey as NSString)
            DispatchQueue.main.async { onReady() }
        }
        return nil
    }
}
