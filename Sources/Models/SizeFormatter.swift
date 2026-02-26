import Foundation

/// Formats byte sizes into human-readable strings.
public struct SizeFormatter: Sendable {
    public static let shared = SizeFormatter()

    private static let units: [(String, UInt64)] = [
        ("TB", 1_099_511_627_776),
        ("GB", 1_073_741_824),
        ("MB", 1_048_576),
        ("KB", 1_024),
    ]

    public func format(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 B" }
        for (unit, threshold) in Self.units {
            if bytes >= threshold {
                let value = Double(bytes) / Double(threshold)
                if value >= 100 {
                    return String(format: "%.0f %@", value, unit)
                } else if value >= 10 {
                    return String(format: "%.1f %@", value, unit)
                } else {
                    return String(format: "%.2f %@", value, unit)
                }
            }
        }
        return "\(bytes) B"
    }

    /// Format with explicit decimal places.
    public func format(_ bytes: UInt64, decimals: Int) -> String {
        if bytes == 0 { return "0 B" }
        for (unit, threshold) in Self.units {
            if bytes >= threshold {
                let value = Double(bytes) / Double(threshold)
                return String(format: "%.\(decimals)f %@", value, unit)
            }
        }
        return "\(bytes) B"
    }

    /// Format as percentage.
    public func percentage(_ part: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "0%" }
        let pct = Double(part) / Double(total) * 100
        if pct >= 10 {
            return String(format: "%.1f%%", pct)
        } else if pct >= 1 {
            return String(format: "%.2f%%", pct)
        } else if pct >= 0.01 {
            return String(format: "%.2f%%", pct)
        } else {
            return "<0.01%"
        }
    }

    /// Format file count with thousands separator (thread-safe, no NumberFormatter).
    public func formatCount(_ count: Int) -> String {
        if count == 0 { return "0" }
        let isNegative = count < 0
        var n = isNegative ? -count : count
        var parts: [String] = []
        while n > 0 {
            parts.append(String(n % 1000))
            n /= 1000
        }
        let first = parts.removeLast()
        let result = ([first] + parts.reversed().map { String(format: "%03d", Int($0)!) }).joined(separator: ",")
        return isNegative ? "-" + result : result
    }
}
