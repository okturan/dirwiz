import Foundation

/// Modified-date presets for the search filter bar.
///
/// Bounds are computed from a caller-supplied `now` rather than read from the clock, so the
/// mapping is testable and so a long-lived view cannot keep filtering against the timestamp
/// it was first rendered at - callers recompute at search time.
public enum SearchDatePreset: String, CaseIterable, Sendable, Identifiable {
    case any
    case last24Hours
    case last7Days
    case last30Days
    case lastYear
    case olderThan1Year
    case olderThan2Years

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any:             return "Any Date"
        case .last24Hours:     return "Last 24 hours"
        case .last7Days:       return "Last 7 days"
        case .last30Days:      return "Last 30 days"
        case .lastYear:        return "Last year"
        case .olderThan1Year:  return "Older than 1 year"
        case .olderThan2Years: return "Older than 2 years"
        }
    }

    private static let day: UInt32 = 86_400

    /// Inclusive Unix-seconds bounds, or nil for "no constraint".
    ///
    /// Saturates at zero rather than wrapping: `now` is unsigned, and a clock skewed to
    /// near-epoch would otherwise underflow into a far-future bound that matches nothing.
    public func bounds(now: UInt32) -> (after: UInt32?, before: UInt32?) {
        func ago(_ days: UInt32) -> UInt32 {
            let delta = days &* SearchDatePreset.day
            return now > delta ? now - delta : 0
        }
        switch self {
        case .any:             return (nil, nil)
        case .last24Hours:     return (ago(1), nil)
        case .last7Days:       return (ago(7), nil)
        case .last30Days:      return (ago(30), nil)
        case .lastYear:        return (ago(365), nil)
        case .olderThan1Year:  return (nil, ago(365))
        case .olderThan2Years: return (nil, ago(730))
        }
    }
}
