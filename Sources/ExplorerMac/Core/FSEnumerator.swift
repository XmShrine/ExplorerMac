import Foundation

/// Bulk directory enumeration built on `getattrlistbulk(2)`.
///
/// This is the fastest listing path on APFS: one syscall returns a packed
/// buffer of many entries, each carrying name, type, size, dates and flags, so
/// a directory listing costs no per-file `stat`. `NSDirectoryEnumerator` with
/// resource-value prefetch still round-trips per item and is roughly an order
/// of magnitude slower on the large directories Explorer is expected to open
/// without stuttering.
enum FSEnumerator {

    // attrgroup_t bits. Declared here because the Darwin overlay exposes these
    // as macros that do not import cleanly as typed constants.
    private static let ATTR_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
    private static let ATTR_CMN_NAME: UInt32          = 0x0000_0001
    private static let ATTR_CMN_OBJTYPE: UInt32       = 0x0000_0008
    private static let ATTR_CMN_CRTIME: UInt32        = 0x0000_0200
    private static let ATTR_CMN_MODTIME: UInt32       = 0x0000_0400
    private static let ATTR_CMN_FILEID: UInt32        = 0x0200_0000
    private static let ATTR_CMN_FLAGS: UInt32         = 0x4000_0000
    private static let ATTR_FILE_DATALENGTH: UInt32   = 0x0000_0200

    private static let FSOPT_NOFOLLOW: UInt64          = 0x0000_0001
    private static let FSOPT_PACK_INVAL_ATTRS: UInt64  = 0x0000_0008

    private static let VREG: UInt32 = 1
    private static let VDIR: UInt32 = 2
    private static let VLNK: UInt32 = 5

    private static let UF_HIDDEN: UInt32 = 0x0000_8000

    /// 256 KiB holds a few thousand entries per syscall, which is where the
    /// syscall-count curve flattens out; larger buffers stop paying for
    /// themselves and just cost resident memory.
    private static let bufferSize = 256 * 1024

    /// Field offsets within one packed entry. `FSOPT_PACK_INVAL_ATTRS` makes
    /// the kernel emit every requested attribute even when it does not apply
    /// (a directory has no `ATTR_FILE_DATALENGTH`), which fixes the layout and
    /// lets us read at constant offsets instead of walking the returned-attrs
    /// bitmap field by field.
    private enum Offset {
        static let returnedAttrs = 4      // attribute_set_t, 5 x u_int32
        static let name          = 24     // attrreference_t
        static let objType       = 32     // fsobj_type_t
        static let crTime        = 36     // struct timespec
        static let modTime       = 52     // struct timespec
        static let fileID        = 68     // u_int64
        static let flags         = 76     // u_int32
        static let dataLength    = 80     // off_t
    }

    struct Result {
        var entries: [FileEntry] = []
        var errno: Int32 = 0
    }

    /// Enumerates `path`, invoking `batch` on each syscall's worth of entries so
    /// the caller can stream rows into the UI while the walk is still running.
    /// `shouldStop` is polled between batches to make navigation cancel promptly.
    static func enumerate(
        path: String,
        batch: ([FileEntry]) -> Void,
        shouldStop: () -> Bool = { false }
    ) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY, 0)
        guard fd >= 0 else { return Darwin.errno }
        defer { close(fd) }

        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE
            | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_FILEID | ATTR_CMN_FLAGS
        attrs.fileattr = ATTR_FILE_DATALENGTH

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize, alignment: MemoryLayout<UInt64>.alignment)
        defer { buffer.deallocate() }

        let options = FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS

        while true {
            if shouldStop() { return 0 }

            let count = withUnsafeMutablePointer(to: &attrs) { attrPtr in
                getattrlistbulk(fd, attrPtr, buffer, bufferSize, options)
            }
            if count < 0 { return Darwin.errno }
            if count == 0 { return 0 }   // end of directory

            var out: [FileEntry] = []
            out.reserveCapacity(Int(count))

            var cursor = buffer
            for _ in 0..<count {
                let length = cursor.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                if let entry = parse(cursor) { out.append(entry) }
                cursor = cursor.advanced(by: Int(length))
            }
            batch(out)
        }
    }

    /// Decodes one packed entry. Returns nil for `.` / `..`, which the kernel
    /// does not emit here but which we guard anyway.
    private static func parse(_ p: UnsafeRawPointer) -> FileEntry? {
        // attrreference_t: { int32 attr_dataoffset; uint32 attr_length }
        let nameOffset = p.loadUnaligned(fromByteOffset: Offset.name, as: Int32.self)
        let nameLength = p.loadUnaligned(fromByteOffset: Offset.name + 4, as: UInt32.self)
        guard nameLength > 1 else { return nil }

        let namePtr = p.advanced(by: Offset.name + Int(nameOffset))
            .assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePtr)
        if name == "." || name == ".." { return nil }

        let objType = p.loadUnaligned(fromByteOffset: Offset.objType, as: UInt32.self)
        let flags   = p.loadUnaligned(fromByteOffset: Offset.flags, as: UInt32.self)
        let fileID  = p.loadUnaligned(fromByteOffset: Offset.fileID, as: UInt64.self)
        let size    = p.loadUnaligned(fromByteOffset: Offset.dataLength, as: Int64.self)

        let crSec  = p.loadUnaligned(fromByteOffset: Offset.crTime, as: Int.self)
        let modSec = p.loadUnaligned(fromByteOffset: Offset.modTime, as: Int.self)

        let isDir = objType == VDIR
        return FileEntry(
            name: name,
            isDirectory: isDir,
            isSymlink: objType == VLNK,
            // Explorer hides both dotfiles (when a volume carries them) and
            // anything the filesystem marks hidden; macOS uses UF_HIDDEN for
            // the latter on entries like /Volumes and /usr.
            isHidden: name.hasPrefix(".") || (flags & UF_HIDDEN) != 0,
            size: isDir ? 0 : max(0, size),
            modified: Date(timeIntervalSince1970: TimeInterval(modSec)),
            created: Date(timeIntervalSince1970: TimeInterval(crSec)),
            fileID: fileID
        )
    }
}
