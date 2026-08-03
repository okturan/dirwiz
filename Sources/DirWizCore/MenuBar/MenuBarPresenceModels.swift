import Foundation
import Darwin

/// One volume-stat sample used by the menu bar gauge. The shell obtains this with one
/// `URLResourceValues` read when the panel opens; everything after that is pure composition.
public struct MenuBarVolumeGauge: Equatable, Sendable {
    public let usedBytes: UInt64
    public let availableBytes: UInt64
    public let totalBytes: UInt64

    public init(availableBytes: UInt64, totalBytes: UInt64) {
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.usedBytes = totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

/// Exactly one `statfs(2)` call. The menu panel uses this instead of URL resource-value
/// helpers whose implementation may issue several metadata reads.
public enum VolumeByteStatsReader {
    public static func read(path: String) -> MenuBarVolumeGauge? {
        readVolumeByteStats(path: path)
    }
}

private func readVolumeByteStats(path: String) -> MenuBarVolumeGauge? {
    var statistics = statfs()
    guard statfs(path, &statistics) == 0 else { return nil }
    let blockSize = UInt64(max(statistics.f_bsize, 0))
    let totalBlocks = statistics.f_blocks
    let availableBlocks = statistics.f_bavail > 0 ? UInt64(statistics.f_bavail) : 0
    let total = totalBlocks.multipliedReportingOverflow(by: blockSize)
    let available = availableBlocks.multipliedReportingOverflow(by: blockSize)
    guard !total.overflow, !available.overflow else { return nil }
    return MenuBarVolumeGauge(
        availableBytes: min(available.partialValue, total.partialValue),
        totalBytes: total.partialValue
    )
}

public struct MenuBarTrendPoint: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let availableBytes: UInt64

    public init(date: Date, availableBytes: UInt64) {
        self.date = date
        self.availableBytes = availableBytes
    }
}

public struct MenuBarGrowthItem: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let deltaBytes: UInt64

    public init(path: String, deltaBytes: UInt64) {
        self.path = path
        self.deltaBytes = deltaBytes
    }
}

public struct MenuBarChangingItem: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let changeCount: Int
    public let hasCreations: Bool
    public let hasDeletions: Bool

    public init(
        path: String,
        changeCount: Int,
        hasCreations: Bool,
        hasDeletions: Bool
    ) {
        self.path = path
        self.changeCount = changeCount
        self.hasCreations = hasCreations
        self.hasDeletions = hasDeletions
    }
}

/// The complete, immutable payload rendered by `MenuBarPanel`. It contains no callbacks
/// and performs no I/O, which makes opening the panel unable to accidentally start work.
public struct MenuBarSnapshot: Equatable, Sendable {
    public let volumeName: String
    public let volumePath: String
    public let gauge: MenuBarVolumeGauge?
    public let trend: [MenuBarTrendPoint]
    public let growers: [MenuBarGrowthItem]
    public let changingNow: [MenuBarChangingItem]
    public let livingViewStatus: String
    public let scanStatus: String?

    public init(
        volumeName: String,
        volumePath: String,
        gauge: MenuBarVolumeGauge?,
        trend: [MenuBarTrendPoint],
        growers: [MenuBarGrowthItem],
        changingNow: [MenuBarChangingItem],
        livingViewStatus: String,
        scanStatus: String?
    ) {
        self.volumeName = volumeName
        self.volumePath = volumePath
        self.gauge = gauge
        self.trend = trend
        self.growers = growers
        self.changingNow = changingNow
        self.livingViewStatus = livingViewStatus
        self.scanStatus = scanStatus
    }
}

/// Deterministically projects already-published application facts into the compact menu
/// bar vocabulary. The caller supplies the single live volume-stat sample separately.
public enum MenuBarSnapshotComposer {
    public struct Input: Sendable {
        public let volumeName: String
        public let volumePath: String
        public let gauge: MenuBarVolumeGauge?
        public let trendHistory: [ScanSummary]
        public let latestCheckpointSummary: CheckpointChangeSummary?
        public let changes: [DirectoryChangeSummary]
        public let livingViewStatus: String
        public let scanStatus: String?

        public init(
            volumeName: String,
            volumePath: String,
            gauge: MenuBarVolumeGauge?,
            trendHistory: [ScanSummary],
            latestCheckpointSummary: CheckpointChangeSummary?,
            changes: [DirectoryChangeSummary],
            livingViewStatus: String,
            scanStatus: String?
        ) {
            self.volumeName = volumeName
            self.volumePath = volumePath
            self.gauge = gauge
            self.trendHistory = trendHistory
            self.latestCheckpointSummary = latestCheckpointSummary
            self.changes = changes
            self.livingViewStatus = livingViewStatus
            self.scanStatus = scanStatus
        }
    }

    public static func compose(
        _ input: Input,
        maximumTrendPoints: Int = 30,
        maximumGrowers: Int = 3,
        maximumChangingItems: Int = 4
    ) -> MenuBarSnapshot {
        let trend = input.trendHistory
            .filter { $0.rootPath == input.volumePath }
            .sorted { $0.date < $1.date }
            .suffix(max(0, maximumTrendPoints))
            .map { MenuBarTrendPoint(date: $0.date, availableBytes: $0.totalFree) }

        let growers = (input.latestCheckpointSummary?.topGrown ?? [])
            .filter { $0.deltaBytes > 0 }
            .sorted {
                if $0.deltaBytes == $1.deltaBytes { return $0.path < $1.path }
                return $0.deltaBytes > $1.deltaBytes
            }
            .prefix(max(0, maximumGrowers))
            .map {
                MenuBarGrowthItem(path: $0.path, deltaBytes: UInt64($0.deltaBytes))
            }

        let changing = input.changes
            .sorted {
                if $0.changeCount == $1.changeCount { return $0.path < $1.path }
                return $0.changeCount > $1.changeCount
            }
            .prefix(max(0, maximumChangingItems))
            .map {
                MenuBarChangingItem(
                    path: $0.path,
                    changeCount: $0.changeCount,
                    hasCreations: $0.hasCreations,
                    hasDeletions: $0.hasDeletions
                )
            }

        return MenuBarSnapshot(
            volumeName: input.volumeName,
            volumePath: input.volumePath,
            gauge: input.gauge,
            trend: Array(trend),
            growers: Array(growers),
            changingNow: Array(changing),
            livingViewStatus: input.livingViewStatus,
            scanStatus: input.scanStatus
        )
    }
}

/// The icon does not inspect system state itself. Low-space state is the policy's latched
/// output, so the warning survives small fluctuations until genuine recovery.
public enum MenuBarIconState: String, Equatable, Sendable {
    case idle
    case scanning
    case lowSpace

    public static func forAppState(isScanning: Bool, isLowSpace: Bool) -> MenuBarIconState {
        if isLowSpace { return .lowSpace }
        if isScanning { return .scanning }
        return .idle
    }
}

public enum ResidencyPolicy {
    public enum LastWindowAction: Equatable, Sendable {
        case remainRunningAsAccessory
        case terminate
    }

    public static func policyAfterLastWindowClosed(
        residencyEnabled: Bool
    ) -> LastWindowAction {
        residencyEnabled ? .remainRunningAsAccessory : .terminate
    }
}

/// Pure low-space hysteresis. `State` is stored per volume by the UI shell; `now` is an
/// input so every boundary is testable without waiting for the clock.
public enum LowSpacePolicy {
    public static let gibibyte: UInt64 = 1_073_741_824

    public struct Configuration: Equatable, Sendable {
        public var thresholdFraction: Double
        public var thresholdCapBytes: UInt64
        public var rearmMarginBytes: UInt64
        public var rearmMarginFraction: Double
        public var minimumFireInterval: TimeInterval

        public init(
            thresholdFraction: Double = 0.10,
            thresholdCapBytes: UInt64 = 25 * LowSpacePolicy.gibibyte,
            rearmMarginBytes: UInt64 = 5 * LowSpacePolicy.gibibyte,
            rearmMarginFraction: Double = 0.05,
            minimumFireInterval: TimeInterval = 86_400
        ) {
            self.thresholdFraction = min(max(thresholdFraction, 0), 1)
            self.thresholdCapBytes = thresholdCapBytes
            self.rearmMarginBytes = rearmMarginBytes
            self.rearmMarginFraction = min(max(rearmMarginFraction, 0), 1)
            self.minimumFireInterval = max(0, minimumFireInterval)
        }

        public func thresholdBytes(totalBytes: UInt64) -> UInt64 {
            guard totalBytes > 0 else { return 0 }
            let proportional = LowSpacePolicy.fractionBytes(
                totalBytes: totalBytes,
                fraction: thresholdFraction
            )
            return min(proportional, thresholdCapBytes)
        }
    }

    public struct State: Codable, Equatable, Sendable {
        public var isArmed: Bool
        public var lastFiredAt: Date?

        public init(isArmed: Bool = true, lastFiredAt: Date? = nil) {
            self.isArmed = isArmed
            self.lastFiredAt = lastFiredAt
        }
    }

    public struct Input: Sendable {
        public let availableBytes: UInt64
        public let totalBytes: UInt64
        public let configuration: Configuration
        public let state: State
        public let now: Date

        public init(
            availableBytes: UInt64,
            totalBytes: UInt64,
            configuration: Configuration = .init(),
            state: State = .init(),
            now: Date
        ) {
            self.availableBytes = availableBytes
            self.totalBytes = totalBytes
            self.configuration = configuration
            self.state = state
            self.now = now
        }
    }

    public enum Action: Equatable, Sendable {
        case hold
        case fire
    }

    public struct Decision: Equatable, Sendable {
        public let action: Action
        public let state: State
        public let isLowSpace: Bool
        public let thresholdBytes: UInt64

        public init(action: Action, state: State, isLowSpace: Bool, thresholdBytes: UInt64) {
            self.action = action
            self.state = state
            self.isLowSpace = isLowSpace
            self.thresholdBytes = thresholdBytes
        }
    }

    public static func decide(_ input: Input) -> Decision {
        let threshold = input.configuration.thresholdBytes(totalBytes: input.totalBytes)
        guard input.totalBytes > 0 else {
            return Decision(action: .hold, state: input.state, isLowSpace: false, thresholdBytes: 0)
        }

        let isLow = input.availableBytes <= threshold
        let proportionalMargin = fractionBytes(
            totalBytes: input.totalBytes,
            fraction: input.configuration.rearmMarginFraction
        )
        let rearmMargin = min(input.configuration.rearmMarginBytes, proportionalMargin)
        let recoveryBoundary = threshold.addingReportingOverflow(rearmMargin)
        let recovery = recoveryBoundary.overflow ? UInt64.max : recoveryBoundary.partialValue
        var state = input.state

        if input.availableBytes >= recovery {
            state.isArmed = true
            return Decision(action: .hold, state: state, isLowSpace: false, thresholdBytes: threshold)
        }

        // Once a crossing disarms the policy, warning state remains latched throughout
        // the hysteresis band. It clears only at the recovery boundary above.
        if !state.isArmed {
            return Decision(action: .hold, state: state, isLowSpace: true, thresholdBytes: threshold)
        }

        guard isLow else {
            return Decision(action: .hold, state: state, isLowSpace: false, thresholdBytes: threshold)
        }

        // A crossing inside the daily cap is consumed, not delayed. Otherwise staying low
        // until tomorrow would manufacture a second "crossing" without any recovery.
        if let last = state.lastFiredAt,
           input.now.timeIntervalSince(last) < input.configuration.minimumFireInterval {
            state.isArmed = false
            return Decision(action: .hold, state: state, isLowSpace: true, thresholdBytes: threshold)
        }

        state.isArmed = false
        state.lastFiredAt = input.now
        return Decision(action: .fire, state: state, isLowSpace: true, thresholdBytes: threshold)
    }

    private static func fractionBytes(totalBytes: UInt64, fraction: Double) -> UInt64 {
        let value = Double(totalBytes) * fraction
        guard value.isFinite, value < Double(UInt64.max) else { return UInt64.max }
        return UInt64(max(value, 0))
    }
}

public struct CachedLargestFile: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: UInt64

    public init(path: String, sizeBytes: UInt64) {
        self.path = path
        self.sizeBytes = sizeBytes
    }
}

public struct CachedLargestFilesResult: Equatable, Sendable {
    public let files: [CachedLargestFile]
    public let cacheSavedAt: Date

    public init(files: [CachedLargestFile], cacheSavedAt: Date) {
        self.files = files
        self.cacheSavedAt = cacheSavedAt
    }
}

/// Read-only intent query over an existing tree. It never calls `FileScanner` and builds
/// paths only for the bounded winning set, so a ten-file shortcut stays cheap on huge trees.
public enum CachedTreeQuery {
    public static func largestFiles(
        in tree: FileTree,
        cacheSavedAt: Date,
        count requestedCount: Int
    ) -> CachedLargestFilesResult {
        let limit = min(max(requestedCount, 1), 100)
        let snapshot = tree.pathBuildingSnapshot()
        var winners: [(index: UInt32, size: UInt64)] = []
        winners.reserveCapacity(limit)

        for (index, node) in snapshot.nodes.enumerated() where !node.isDirectory {
            let candidate = (index: UInt32(index), size: node.displaySize)
            let insertion = winners.firstIndex {
                candidate.size > $0.size || (candidate.size == $0.size && candidate.index < $0.index)
            } ?? winners.endIndex
            if insertion < limit {
                winners.insert(candidate, at: insertion)
                if winners.count > limit { winners.removeLast() }
            } else if winners.count < limit {
                winners.append(candidate)
            }
        }

        let files = winners.map {
            CachedLargestFile(
                path: FileTree.pathFromSnapshot(
                    at: $0.index,
                    nodes: snapshot.nodes,
                    stringPool: snapshot.stringPool,
                    rootPath: snapshot.rootPath
                ),
                sizeBytes: $0.size
            )
        }
        return CachedLargestFilesResult(files: files, cacheSavedAt: cacheSavedAt)
    }
}
