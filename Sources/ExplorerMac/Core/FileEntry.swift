import Foundation

/// One row in a directory listing. Kept as a struct of flat fields so a
/// 500k-entry listing stays in a contiguous array with no per-item allocation
/// beyond the name string itself.
struct FileEntry {
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool
    var isHidden: Bool
    var size: Int64
    var modified: Date
    var created: Date
    var fileID: UInt64
    /// Directory this entry lives in, or nil when it belongs to the directory
    /// currently being listed. Only search results, which span folders, set it.
    var directory: String?

    /// Whether two listings entries describe the same file in the same state.
    /// Used to decide if a refresh changed anything worth repainting.
    func isSame(as other: FileEntry) -> Bool {
        fileID == other.fileID && size == other.size
            && modified == other.modified && name == other.name
            && isHidden == other.isHidden
    }

    /// Lowercased extension without the dot. Empty for folders / extensionless files.
    var ext: String {
        guard !isDirectory else { return "" }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

/// Explorer's "类型" column. Windows resolves this through the registry's
/// ProgID chain; we mirror the strings for the extensions Explorer ships
/// descriptions for and fall back to Windows' own "XXX 文件" pattern.
enum FileTypeNamer {
    private static let known: [String: String] = [
        "txt": "文本文档", "rtf": "RTF 格式", "log": "文本文档",
        "doc": "Microsoft Word 97-2003 文档", "docx": "Microsoft Word 文档",
        "xls": "Microsoft Excel 97-2003 工作表", "xlsx": "Microsoft Excel 工作表",
        "ppt": "Microsoft PowerPoint 97-2003 演示文稿", "pptx": "Microsoft PowerPoint 演示文稿",
        "pdf": "Microsoft Edge PDF 文档",
        "zip": "压缩(zipped)文件夹", "7z": "7Z 文件", "rar": "RAR 文件",
        "gz": "GZ 文件", "tar": "TAR 文件",
        "png": "PNG 文件", "jpg": "JPG 文件", "jpeg": "JPEG 文件",
        "gif": "GIF 文件", "bmp": "BMP 文件", "webp": "WEBP 文件",
        "heic": "HEIC 文件", "svg": "SVG 文档", "ico": "图标",
        "mp3": "MP3 文件", "wav": "WAV 文件", "flac": "FLAC 文件",
        "m4a": "M4A 文件", "aac": "AAC 文件",
        "mp4": "MP4 视频", "mov": "MOV 文件", "avi": "AVI 文件",
        "mkv": "MKV 文件", "webm": "WEBM 文件",
        "exe": "应用程序", "dll": "应用程序扩展", "sys": "系统文件",
        "bat": "Windows 批处理文件", "cmd": "Windows 命令脚本",
        "ps1": "Windows PowerShell 脚本", "msi": "Windows Installer 程序包",
        "lnk": "快捷方式", "url": "Internet 快捷方式",
        "ini": "配置设置", "cfg": "CFG 文件", "conf": "CONF 文件",
        "json": "JSON 文件", "xml": "XML 文档", "yml": "YML 文件", "yaml": "YAML 文件",
        "html": "Microsoft Edge HTML Document", "htm": "Microsoft Edge HTML Document",
        "css": "层叠样式表文档", "js": "JavaScript 文件", "ts": "TS 文件",
        "c": "C 文件", "h": "H 文件", "cpp": "CPP 文件", "hpp": "HPP 文件",
        "cs": "C# 源文件", "java": "JAVA 文件", "py": "Python 文件",
        "swift": "SWIFT 文件", "rs": "RS 文件", "go": "GO 文件", "rb": "RB 文件",
        "sh": "SH 文件", "md": "MD 文件",
        "ttf": "TrueType 字体文件", "otf": "OpenType 字体文件",
        "iso": "光盘映像文件", "dmg": "DMG 文件", "app": "应用程序",
        "db": "Data Base File", "sqlite": "SQLITE 文件",
        "jar": "JAR 文件", "class": "CLASS 文件",
    ]

    static func name(for entry: FileEntry) -> String {
        if entry.isDirectory { return "文件夹" }
        let e = entry.ext
        if e.isEmpty { return "文件" }
        if let known = known[e] { return known }
        return "\(e.uppercased()) 文件"
    }
}
