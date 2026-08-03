import Foundation
import DirWizCore

public enum MenuBarNotificationEvent: Equatable, Sendable {
    case lowSpace(
        volumeName: String,
        volumePath: String,
        availableBytes: UInt64,
        thresholdBytes: UInt64
    )
    case growth(volumeName: String, path: String, deltaBytes: UInt64)
}

extension AppState {
    /// The one status composer used by both the sidebar and menu-bar panel. `now` is
    /// injectable so vocabulary tests do not race the clock.
    public func livingViewStatus(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> String {
        let pending = fsChanges.count
        if liveRefreshPaused {
            return pending > 0 ? "Paused · \(pending) folders pending" : "Paused"
        }
        switch liveRefreshDecision {
        case .storm(let count):
            return "\(SizeFormatter.shared.formatCount(count)) folders changed - too many to patch"
        case .deferred(let reason):
            switch reason {
            case .temporalDiffActive: return "\(pending) pending · waiting for the diff overlay"
            case .scanning: return "\(pending) pending · scanning"
            case .heavyTaskRunning: return "\(pending) pending · waiting for analysis"
            case .paused: return "Paused"
            }
        case .waitingForQuiescence, .waitingForInterval:
            return "\(pending) folders changed · updating shortly"
        case .apply:
            return "\(pending) folders changed · updating"
        case .idle:
            if let lastLiveApplyAt {
                let ago = Int(now - lastLiveApplyAt)
                return ago < 5 ? "Live · just updated" : "Live · updated \(ago)s ago"
            }
            return "Live"
        }
    }

    public var selectedVolumeName: String {
        guard let selectedVolume else { return "No Volume"
        }
        let volumePath = selectedFolderVolumePath ?? selectedVolume.path
        if let match = availableVolumes.first(where: { $0.url.path == volumePath }) {
            return match.name
        }
        return volumePath == "/" ? "Macintosh HD" : URL(fileURLWithPath: volumePath).lastPathComponent
    }

    public var menuBarIconState: MenuBarIconState {
        MenuBarIconState.forAppState(
            isScanning: scanProgress.isScanning || isApplyingChanges,
            isLowSpace: isLowSpace
        )
    }

    public var menuBarSnapshot: MenuBarSnapshot {
        let path = selectedVolume?.path ?? fileTree?.rootPath ?? ""
        let scanStatus: String? = scanProgress.isScanning
            ? (scanProgress.currentPath.isEmpty ? "Scanning…" : scanProgress.currentPath)
            : (isApplyingChanges ? "Applying filesystem changes…" : nil)
        return MenuBarSnapshotComposer.compose(.init(
            volumeName: selectedVolumeName,
            volumePath: path,
            gauge: menuBarVolumeGauge,
            trendHistory: storageTrendHistory,
            latestCheckpointSummary: temporalDiff.availableCheckpoints.first?.summary,
            changes: fsChanges,
            livingViewStatus: livingViewStatus(),
            scanStatus: scanStatus
        ))
    }

    /// The only implicit filesystem read owned by the panel. Callers invoke it once on
    /// presentation; it neither scans nor touches analyzers.
    @discardableResult
    public func refreshMenuBarVolumeStats(now: Date = Date()) -> MenuBarVolumeGauge? {
        guard let path = selectedVolume?.path ?? fileTree?.rootPath else {
            menuBarVolumeGauge = nil
            isLowSpace = false
            return nil
        }
        guard selectedMountTraversalScope == .selectedVolume,
              let sample = VolumeByteStatsReader.readSample(path: path) else {
            menuBarVolumeGauge = nil
            isLowSpace = false
            return nil
        }
        evaluateMenuBarVolumeGauge(sample.gauge, volumePath: sample.mountPath, now: now)
        return sample.gauge
    }

    /// Pure-input shell used after the one statfs and by deterministic policy tests.
    /// Keeping it separate makes notification behavior testable without fabricating a disk.
    public func evaluateMenuBarVolumeGauge(
        _ gauge: MenuBarVolumeGauge,
        volumePath path: String,
        now: Date = Date()
    ) {
        menuBarVolumeGauge = gauge
        let configuration = LowSpacePolicy.Configuration(
            thresholdFraction: min(max(lowSpaceThresholdPercent / 100, 0.01), 1)
        )
        let oldState = lowSpacePolicyStates[path] ?? .init()
        let decision = LowSpacePolicy.decide(.init(
            availableBytes: gauge.availableBytes,
            totalBytes: gauge.totalBytes,
            configuration: configuration,
            state: oldState,
            now: now
        ))
        lowSpacePolicyStates[path] = decision.state
        isLowSpace = decision.isLowSpace
        persistLowSpacePolicyStates()

        if decision.action == .fire, lowSpaceNotificationsEnabled {
            postMenuBarNotification?(.lowSpace(
                volumeName: selectedVolumeName,
                volumePath: path,
                availableBytes: gauge.availableBytes,
                thresholdBytes: decision.thresholdBytes
            ))
        }
    }

    func emitGrowthNotificationIfNeeded(for checkpoint: SnapshotCheckpoint) {
        guard growthNotificationsEnabled,
              let growth = checkpoint.summary?.topGrown.max(by: {
                  $0.deltaBytes < $1.deltaBytes
              }),
              growth.deltaBytes > 0 else { return }
        let threshold = UInt64(growthNotificationThresholdGiB * Double(LowSpacePolicy.gibibyte))
        guard UInt64(growth.deltaBytes) >= threshold else { return }
        postMenuBarNotification?(.growth(
            volumeName: selectedVolumeName,
            path: growth.path,
            deltaBytes: UInt64(growth.deltaBytes)
        ))
    }

    public func rememberRecentVolume(path: String) {
        guard !path.isEmpty else { return }
        recentVolumePaths.removeAll { $0 == path }
        recentVolumePaths.insert(path, at: 0)
        if recentVolumePaths.count > 5 { recentVolumePaths.removeLast(recentVolumePaths.count - 5) }
        defaults.set(recentVolumePaths, forKey: AppState.recentVolumePathsKey)
    }

    func rearmLowSpacePolicyForNotificationEnable() {
        for path in lowSpacePolicyStates.keys {
            lowSpacePolicyStates[path]?.isArmed = true
        }
        persistLowSpacePolicyStates()
    }

    public var lastScannedVolumePath: String? {
        defaults.string(forKey: AppState.lastScannedVolumePathKey)
    }

    private func persistLowSpacePolicyStates() {
        guard let data = try? JSONEncoder().encode(lowSpacePolicyStates) else { return }
        defaults.set(data, forKey: AppState.lowSpacePolicyStatesKey)
    }
}
