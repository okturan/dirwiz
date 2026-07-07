import Foundation
import os

private let log = Logger(subsystem: "com.dirwiz", category: "APFSIntelligence")

// MARK: - Clone Detection

/// Result of checking if duplicate files are APFS clones (shared physical blocks).
public struct CloneCheckResult: Sendable {
    public let group: DuplicateGroup
    /// Per-path allocated (physical) size from URLResourceValues.
    public let privateSizes: [String: UInt64]
    /// True when sharing confidence exceeds 0.5, indicating the files likely share
    /// physical blocks (APFS clones).
    public let areClones: Bool
    /// How much block sharing is implied (0 = fully independent, 1 = perfect sharing).
    public let sharingConfidence: Double
    /// Actual wasted space accounting for clone sharing.
    public let realWastedSpace: UInt64
}

// MARK: - Purgeable Space

public struct PurgeableSpaceInfo: Sendable {
    public let volumePath: String
    public let totalCapacity: UInt64
    public let availableCapacity: UInt64
    public let availableForOpportunistic: UInt64
    public let purgeableAmount: UInt64
}

// MARK: - Time Machine Snapshots

public struct TMSnapshot: Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let volumePath: String
}

public struct TMSnapshotInfo: Sendable {
    public let snapshots: [TMSnapshot]
    public let volumePath: String
}

// MARK: - Combined Result

public struct APFSInfo: Sendable {
    public let purgeableSpace: PurgeableSpaceInfo?
    public let tmSnapshots: TMSnapshotInfo?
}

// MARK: - APFSIntelligence

public struct APFSIntelligence: Sendable {

    public init() {}

    // MARK: - Clone Detection

    /// Check duplicate groups for APFS clone sharing by comparing allocated sizes.
    ///
    /// For each file in a group, queries `totalFileAllocatedSizeKey` (physical blocks
    /// including resource forks/xattrs). If the sum of allocated sizes across all copies
    /// is less than `fileSize * count`, the files share physical blocks (clones).
    public func checkClones(groups: [DuplicateGroup]) async -> [CloneCheckResult] {
        await withTaskGroup(of: CloneCheckResult?.self) { taskGroup in
            for group in groups {
                taskGroup.addTask {
                    self.checkSingleGroup(group)
                }
            }
            var results: [CloneCheckResult] = []
            results.reserveCapacity(groups.count)
            for await result in taskGroup {
                if let result { results.append(result) }
            }
            return results
        }
    }

    private func checkSingleGroup(_ group: DuplicateGroup) -> CloneCheckResult? {
        var privateSizes: [String: UInt64] = [:]
        var totalAllocated: UInt64 = 0

        for path in group.paths {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey]
            ) else {
                // If we can't read one file, skip entire group — incomplete data
                return nil
            }
            let allocated = UInt64(values.totalFileAllocatedSize ?? 0)
            privateSizes[path] = allocated
            totalAllocated += allocated
        }

        guard group.paths.count >= 2 else { return nil }
        let assessment = Self.assessCloneSharing(allocatedSizes: Array(privateSizes.values))

        return CloneCheckResult(
            group: group,
            privateSizes: privateSizes,
            areClones: assessment.areClones,
            sharingConfidence: assessment.sharingConfidence,
            realWastedSpace: assessment.realWastedSpace
        )
    }

    static func assessCloneSharing(allocatedSizes: [UInt64]) -> (areClones: Bool, sharingConfidence: Double, realWastedSpace: UInt64) {
        guard let oneCopyAllocated = allocatedSizes.max(), allocatedSizes.count >= 2 else {
            return (false, 0.0, 0)
        }

        let totalAllocated = allocatedSizes.reduce(0, +)
        let count = allocatedSizes.count

        // Confidence represents how much block sharing is implied:
        //   1.0 = perfect sharing (totalAllocated == oneCopyAllocated)
        //   0.0 = no sharing (each copy fully independent)
        // The denominator is how much extra allocation we'd expect with zero sharing.
        let expectedIndependentExtra = Double(oneCopyAllocated) * Double(max(1, count - 1))
        let actualExtra = Double(totalAllocated) - Double(oneCopyAllocated)
        let sharingConfidence: Double
        if expectedIndependentExtra > 0 {
            sharingConfidence = max(0.0, min(1.0, 1.0 - actualExtra / expectedIndependentExtra))
        } else {
            sharingConfidence = 0.0
        }

        let areClones = sharingConfidence > 0.5

        let realWastedSpace = totalAllocated > oneCopyAllocated
            ? totalAllocated - oneCopyAllocated
            : 0
        return (areClones, sharingConfidence, realWastedSpace)
    }

    // MARK: - Purgeable Space

    /// Query purgeable space for a volume using URLResourceValues.
    ///
    /// Purgeable amount = opportunistic available - regular available.
    /// This includes caches, Time Machine local snapshots, and other data
    /// macOS can purge under storage pressure.
    public func queryPurgeableSpace(volumePath: String) async -> PurgeableSpaceInfo? {
        let url = URL(fileURLWithPath: volumePath)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ]) else {
            return nil
        }

        let total = UInt64(values.volumeTotalCapacity ?? 0)
        let available = UInt64(values.volumeAvailableCapacity ?? 0)
        let opportunistic = UInt64(values.volumeAvailableCapacityForOpportunisticUsage ?? 0)
        let purgeable = opportunistic > available ? opportunistic - available : 0

        return PurgeableSpaceInfo(
            volumePath: volumePath,
            totalCapacity: total,
            availableCapacity: available,
            availableForOpportunistic: opportunistic,
            purgeableAmount: purgeable
        )
    }

    // MARK: - Time Machine Snapshots

    /// List Time Machine local snapshots by running `tmutil listlocalsnapshots`.
    ///
    /// Parses snapshot names like `com.apple.TimeMachine.2024-01-15-120000.local`
    /// to extract dates. Returns nil if tmutil fails or is unavailable.
    public func listTMSnapshots(volumePath: String) async -> TMSnapshotInfo? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volumePath]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("Failed to run tmutil listlocalsnapshots: \(error.localizedDescription)")
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        var snapshots: [TMSnapshot] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Lines look like:
            //   com.apple.TimeMachine.2024-01-15-120000.local
            // or on newer macOS:
            //   Snapshots for disk /:\n  com.apple.TimeMachine.2024-01-15-120000.local
            guard trimmed.contains("com.apple.TimeMachine.") else { continue }

            let snapshotName = trimmed
            // Extract the date portion between "com.apple.TimeMachine." and ".local"
            guard let dateRange = extractSnapshotDate(from: snapshotName) else { continue }
            guard let date = formatter.date(from: dateRange) else { continue }

            snapshots.append(TMSnapshot(
                id: snapshotName,
                date: date,
                volumePath: volumePath
            ))
        }

        snapshots.sort { $0.date > $1.date }

        return TMSnapshotInfo(snapshots: snapshots, volumePath: volumePath)
    }

    /// Extract date string from a TM snapshot name.
    /// Input:  `com.apple.TimeMachine.2024-01-15-120000.local`
    /// Output: `2024-01-15-120000`
    private func extractSnapshotDate(from name: String) -> String? {
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        guard let prefixRange = name.range(of: prefix),
              let suffixRange = name.range(of: suffix, range: prefixRange.upperBound..<name.endIndex)
        else { return nil }
        let dateStr = String(name[prefixRange.upperBound..<suffixRange.lowerBound])
        // Validate format: expect "YYYY-MM-DD-HHMMSS" (19 chars)
        guard dateStr.count >= 17 else { return nil }
        return dateStr
    }

    // MARK: - Combined Query

    /// Run purgeable space and Time Machine snapshot queries in parallel.
    public func analyze(volumePath: String) async -> APFSInfo {
        async let purgeable = queryPurgeableSpace(volumePath: volumePath)
        async let snapshots = listTMSnapshots(volumePath: volumePath)
        return APFSInfo(
            purgeableSpace: await purgeable,
            tmSnapshots: await snapshots
        )
    }
}
