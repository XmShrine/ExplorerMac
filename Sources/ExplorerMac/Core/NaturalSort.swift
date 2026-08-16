import Foundation

/// Reimplementation of Windows' `StrCmpLogicalW`, the comparator Explorer uses
/// for every name column. Getting this wrong is the usual tell of a clone:
/// plain lexicographic ordering puts "file10" before "file2", and a naive
/// case-insensitive compare loses the tiebreak Explorer applies for names that
/// differ only in case.
///
/// Semantics matched against shlwapi:
///   - runs of ASCII digits compare as numbers, ignoring leading zeros
///   - a shorter zero-prefix wins the tiebreak when the numeric values are equal
///   - non-digit runs compare case-insensitively, uppercase winning ties
///   - digits sort before letters
enum NaturalSort {

    /// Comparison runs on the strings' contiguous UTF-8 buffers. Materialising
    /// a `[UInt16]` per operand instead — the obvious way to write this — costs
    /// two heap allocations on every comparison, which at ~2M comparisons per
    /// sort of a large directory dominates the entire listing time.
    ///
    /// UTF-8 byte order matches code-point order, so ordering is unchanged, and
    /// the digit runs Windows cares about are ASCII either way.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        var lhs = a, rhs = b
        return lhs.withUTF8 { l in rhs.withUTF8 { r in compare(l, r) } }
    }

    private static func compare(_ lhs: UnsafeBufferPointer<UInt8>,
                                _ rhs: UnsafeBufferPointer<UInt8>) -> ComparisonResult {
        var i = 0, j = 0
        // Remembered case difference, applied only if the strings are otherwise equal.
        var caseTiebreak: ComparisonResult = .orderedSame
        // Remembered zero-padding difference, same deal.
        var zeroTiebreak: ComparisonResult = .orderedSame

        while i < lhs.count && j < rhs.count {
            let ca = lhs[i], cb = rhs[j]
            let aDigit = isDigit(ca), bDigit = isDigit(cb)

            if aDigit && bDigit {
                // Skip leading zeros on both sides, remembering which had more.
                var zi = i, zj = j
                while zi < lhs.count && lhs[zi] == 0x30 { zi += 1 }
                while zj < rhs.count && rhs[zj] == 0x30 { zj += 1 }
                let zerosA = zi - i, zerosB = zj - j
                if zeroTiebreak == .orderedSame && zerosA != zerosB {
                    zeroTiebreak = zerosA < zerosB ? .orderedAscending : .orderedDescending
                }

                // Measure both digit runs.
                var ei = zi, ej = zj
                while ei < lhs.count && isDigit(lhs[ei]) { ei += 1 }
                while ej < rhs.count && isDigit(rhs[ej]) { ej += 1 }
                let lenA = ei - zi, lenB = ej - zj

                if lenA != lenB {
                    // More significant digits means a larger number.
                    return lenA < lenB ? .orderedAscending : .orderedDescending
                }
                // Equal width: first differing digit decides.
                var k = 0
                while k < lenA {
                    if lhs[zi + k] != rhs[zj + k] {
                        return lhs[zi + k] < rhs[zj + k] ? .orderedAscending : .orderedDescending
                    }
                    k += 1
                }
                i = ei
                j = ej
                continue
            }

            if aDigit != bDigit {
                // Digits sort ahead of everything non-digit.
                return aDigit ? .orderedAscending : .orderedDescending
            }

            let fa = fold(ca), fb = fold(cb)
            if fa != fb {
                return fa < fb ? .orderedAscending : .orderedDescending
            }
            if caseTiebreak == .orderedSame && ca != cb {
                // Uppercase sorts first among otherwise-equal names.
                caseTiebreak = ca < cb ? .orderedAscending : .orderedDescending
            }
            i += 1
            j += 1
        }

        if i < lhs.count { return .orderedDescending }
        if j < rhs.count { return .orderedAscending }
        if zeroTiebreak != .orderedSame { return zeroTiebreak }
        return caseTiebreak
    }

    static func less(_ a: String, _ b: String) -> Bool {
        compare(a, b) == .orderedAscending
    }

    @inline(__always)
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    /// Uppercase-fold for ASCII, which is where Explorer's ordering is actually
    /// observable; anything above ASCII compares by code unit.
    @inline(__always)
    private static func fold(_ c: UInt8) -> UInt8 {
        (c >= 0x61 && c <= 0x7A) ? c - 0x20 : c
    }
}
