import Foundation

/// Explorer's column formatting. These are deliberately not `ByteCountFormatter`
/// or `DateFormatter.dateStyle` output: Windows rounds sizes up to whole KB in
/// the details view, groups thousands, and writes dates as a non-padded
/// `yyyy/M/d HH:mm` on zh-CN. macOS' locale defaults produce visibly different
/// strings for both.
enum WinFormat {

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.maximumFractionDigits = 0
        return f
    }()

    private static let listDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日, HH:mm:ss"
        return f
    }()

    /// Details-view size column: whole kilobytes, rounded up, thousands-grouped.
    /// A 1-byte file reads "1 KB" and a 0-byte file reads "0 KB", both matching
    /// Explorer. Folders render empty.
    static func listSize(_ entry: FileEntry) -> String {
        guard !entry.isDirectory else { return "" }
        let kb = entry.size == 0 ? 0 : (entry.size + 1023) / 1024
        let n = grouping.string(from: NSNumber(value: kb)) ?? "\(kb)"
        return "\(n) KB"
    }

    /// Status bar / properties style: "1.23 MB (1,289,748 字节)".
    static func detailedSize(_ bytes: Int64) -> String {
        let units = ["字节", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(grouping.string(from: NSNumber(value: bytes)) ?? "\(bytes)") 字节"
        }
        return String(format: "%.2f %@", value, units[unit])
    }

    static func listDateString(_ date: Date) -> String { listDate.string(from: date) }
    static func fullDateString(_ date: Date) -> String { fullDate.string(from: date) }
}
