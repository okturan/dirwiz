import Foundation
import Testing
import AppKit
import SwiftUI
@testable import DirWizCore
@testable import DirWizUI

@Suite("Menu Bar Presence Policy Tests")
struct MenuBarPresencePolicyTests {
    private let gib = LowSpacePolicy.gibibyte

    @Test("Snapshot composer sorts and bounds published inputs deterministically")
    func snapshotComposition() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let checkpoint = CheckpointChangeSummary(
            totalDelta: 10,
            topGrown: [
                .init(path: "/z", deltaBytes: 5),
                .init(path: "/a", deltaBytes: 5),
                .init(path: "/ignored", deltaBytes: -1),
            ],
            topShrunk: [], deletedCount: 0, deletedBytes: 0, addedCount: 2
        )
        let changes = [
            change("/b", count: 2, created: true),
            change("/a", count: 2, deleted: true),
            change("/c", count: 1),
        ]

        let result = MenuBarSnapshotComposer.compose(.init(
            volumeName: "Test Disk",
            volumePath: "/Volumes/Test",
            gauge: .init(availableBytes: 40, totalBytes: 100),
            trendHistory: [
                summary(date: newer, path: "/Volumes/Test", free: 40),
                summary(date: older, path: "/Volumes/Test", free: 50),
                summary(date: newer, path: "/other", free: 999),
            ],
            latestCheckpointSummary: checkpoint,
            changes: changes,
            livingViewStatus: "2 folders changed · updating shortly",
            scanStatus: nil
        ), maximumTrendPoints: 2, maximumGrowers: 2, maximumChangingItems: 2)

        #expect(result.gauge?.usedBytes == 60)
        #expect(result.trend.map(\.availableBytes) == [50, 40])
        #expect(result.growers.map(\.path) == ["/a", "/z"])
        #expect(result.changingNow.map(\.path) == ["/a", "/b"])
        #expect(result.livingViewStatus == "2 folders changed · updating shortly")
    }

    @Test("Icon precedence keeps low-space warning latched over scanning")
    func iconState() {
        #expect(MenuBarIconState.forAppState(isScanning: false, isLowSpace: false) == .idle)
        #expect(MenuBarIconState.forAppState(isScanning: true, isLowSpace: false) == .scanning)
        #expect(MenuBarIconState.forAppState(isScanning: false, isLowSpace: true) == .lowSpace)
        #expect(MenuBarIconState.forAppState(isScanning: true, isLowSpace: true) == .lowSpace)
    }

    @Test("Residency resolves last-window close without AppKit")
    func residency() {
        #expect(ResidencyPolicy.policyAfterLastWindowClosed(residencyEnabled: true)
                == .remainRunningAsAccessory)
        #expect(ResidencyPolicy.policyAfterLastWindowClosed(residencyEnabled: false)
                == .terminate)
    }

    @Test("Default threshold is ten percent capped at twenty-five GiB")
    func thresholdArithmetic() {
        let config = LowSpacePolicy.Configuration()
        #expect(config.thresholdBytes(totalBytes: 100 * gib) == 10 * gib)
        #expect(config.thresholdBytes(totalBytes: 1_000 * gib) == 25 * gib)

        let smallNow = Date(timeIntervalSince1970: 10)
        let fired = LowSpacePolicy.decide(.init(
            availableBytes: 100_000_000,
            totalBytes: gib,
            configuration: config,
            now: smallNow
        ))
        let recovered = LowSpacePolicy.decide(.init(
            availableBytes: 200_000_000,
            totalBytes: gib,
            configuration: config,
            state: fired.state,
            now: smallNow.addingTimeInterval(60)
        ))
        #expect(recovered.state.isArmed, "the fixed margin is capped for small volumes")
    }

    @Test("Low-space crossing fires once and requires the recovery margin")
    func hysteresis() {
        let now = Date(timeIntervalSince1970: 100_000)
        let config = LowSpacePolicy.Configuration(
            thresholdFraction: 0.10,
            thresholdCapBytes: 25 * gib,
            rearmMarginBytes: 5 * gib
        )
        let first = LowSpacePolicy.decide(.init(
            availableBytes: 10 * gib,
            totalBytes: 100 * gib,
            configuration: config,
            now: now
        ))
        #expect(first.action == .fire)
        #expect(first.isLowSpace)
        #expect(!first.state.isArmed)

        let hovering = LowSpacePolicy.decide(.init(
            availableBytes: 11 * gib,
            totalBytes: 100 * gib,
            configuration: config,
            state: first.state,
            now: now.addingTimeInterval(60)
        ))
        #expect(hovering.action == .hold)
        #expect(!hovering.state.isArmed)
        #expect(hovering.isLowSpace, "warning remains latched inside the hysteresis band")

        let recovered = LowSpacePolicy.decide(.init(
            availableBytes: 15 * gib,
            totalBytes: 100 * gib,
            configuration: config,
            state: hovering.state,
            now: now.addingTimeInterval(120)
        ))
        #expect(recovered.state.isArmed)
        #expect(!recovered.isLowSpace)
    }

    @Test("Daily cap consumes a second crossing inside twenty-four hours")
    func dailyCap() {
        let now = Date(timeIntervalSince1970: 200_000)
        let prior = LowSpacePolicy.State(
            isArmed: true,
            lastFiredAt: now.addingTimeInterval(-3_600)
        )
        let decision = LowSpacePolicy.decide(.init(
            availableBytes: 1,
            totalBytes: 100,
            configuration: .init(
                thresholdFraction: 0.10,
                thresholdCapBytes: 10,
                rearmMarginBytes: 5,
                rearmMarginFraction: 0.05,
                minimumFireInterval: 86_400
            ),
            state: prior,
            now: now
        ))
        #expect(decision.action == .hold)
        #expect(!decision.state.isArmed)
    }

    @Test("Largest-files query is bounded, uses display size, and reports cache age")
    func largestFilesQuery() {
        let tree = FileTree()
        tree.setRootPath("/cache")
        var root = FileNode(); root.isDirectory = true
        _ = tree.addNode(root, name: "root")
        _ = tree.addChildren([
            (FileNode(fileSize: 9, allocatedSize: 20), "large.bin"),
            (FileNode(fileSize: 15, allocatedSize: 0), "middle.bin"),
            (FileNode(fileSize: 5, allocatedSize: 5), "small.bin"),
        ], parentIndex: 0)
        tree.propagateSizes()
        let savedAt = Date(timeIntervalSince1970: 123)

        let result = CachedTreeQuery.largestFiles(in: tree, cacheSavedAt: savedAt, count: 2)
        #expect(result.cacheSavedAt == savedAt)
        #expect(result.files.map(\.path) == ["/cache/large.bin", "/cache/middle.bin"])
        #expect(result.files.map(\.sizeBytes) == [20, 15])
    }

    @Test("Menu bar defaults and every notification knob round-trip in the injected store")
    @MainActor
    func appStatePreferencesPersist() {
        let suite = "dirwiz.test.menu-bar-presence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = AppState(defaults: defaults)
        #expect(state.showsMenuBarItem)
        #expect(state.keepsRunningInMenuBar)
        #expect(!state.showsFreeSpaceInMenuBar)
        #expect(!state.lowSpaceNotificationsEnabled)
        #expect(!state.growthNotificationsEnabled)
        #expect(state.lowSpaceThresholdPercent == 10)

        state.showsFreeSpaceInMenuBar = true
        state.lowSpaceNotificationsEnabled = true
        state.lowSpaceThresholdPercent = 7
        state.growthNotificationsEnabled = true
        state.growthNotificationThresholdGiB = 12
        state.rememberRecentVolume(path: "/Volumes/Archive")

        let relaunched = AppState(defaults: defaults)
        #expect(relaunched.showsMenuBarItem)
        #expect(relaunched.keepsRunningInMenuBar)
        #expect(relaunched.showsFreeSpaceInMenuBar)
        #expect(relaunched.lowSpaceNotificationsEnabled)
        #expect(relaunched.lowSpaceThresholdPercent == 7)
        #expect(relaunched.growthNotificationsEnabled)
        #expect(relaunched.growthNotificationThresholdGiB == 12)
        #expect(relaunched.recentVolumePaths == ["/Volumes/Archive"])

        // Hiding the only ambient surface must also disable residency, so closing the
        // window cannot strand an invisible process.
        relaunched.showsMenuBarItem = false
        #expect(!relaunched.keepsRunningInMenuBar)
        relaunched.keepsRunningInMenuBar = true
        #expect(relaunched.showsMenuBarItem)
    }

    @Test("Sidebar and menu panel consume one living-view status composer")
    @MainActor
    func livingStatusVocabulary() {
        let suite = "dirwiz.test.menu-bar-status.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.fsChanges = [change("/tmp/new", count: 3)]
        state.liveRefreshDecision = .waitingForQuiescence
        #expect(state.livingViewStatus(now: 500) == "1 folders changed · updating shortly")
        #expect(state.menuBarSnapshot.livingViewStatus == state.livingViewStatus())

        state.liveRefreshPaused = true
        #expect(state.livingViewStatus(now: 500) == "Paused · 1 folders pending")

        // Construction pins the product vocabulary and keeps these views reachable from
        // the test target instead of only from the executable target.
        _ = MenuBarPanel(appState: state, openDirWiz: {}, quit: {})
        _ = DirWizMenuBarLabel(state: .idle, freeSpaceText: nil)
        _ = SettingsView(appState: state)
    }

    @Test("Per-volume low-space state persists and notification fires only on crossing")
    @MainActor
    func appStateLowSpacePersistence() {
        let suite = "dirwiz.test.menu-bar-low-space.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.lowSpaceNotificationsEnabled = true
        var events: [MenuBarNotificationEvent] = []
        state.postMenuBarNotification = { events.append($0) }
        let now = Date(timeIntervalSince1970: 500_000)
        let lowGauge = MenuBarVolumeGauge(availableBytes: 5 * gib, totalBytes: 100 * gib)

        state.evaluateMenuBarVolumeGauge(lowGauge, volumePath: "/Volumes/Test", now: now)
        state.evaluateMenuBarVolumeGauge(
            lowGauge,
            volumePath: "/Volumes/Test",
            now: now.addingTimeInterval(60)
        )
        #expect(events.count == 1)
        #expect(state.isLowSpace)

        let persisted = defaults.data(forKey: AppState.lowSpacePolicyStatesKey)
        #expect(persisted != nil)
        let decoded = persisted.flatMap {
            try? JSONDecoder().decode([String: LowSpacePolicy.State].self, from: $0)
        }
        #expect(decoded?["/Volumes/Test"]?.isArmed == false)
        #expect(AppState.loadLowSpacePolicyStates(defaults)["/Volumes/Test"]?.isArmed == false)
        let relaunched = AppState(defaults: defaults)
        #expect(relaunched.lowSpacePolicyStates["/Volumes/Test"]?.isArmed == false)
    }

    @Test("Idle, scanning, and low-space panel states render offscreen")
    @MainActor
    func panelStatesRender() throws {
        for mode in [MenuBarIconState.idle, .scanning, .lowSpace] {
            let suite = "dirwiz.test.menu-bar-render.\(mode.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            let state = AppState(defaults: defaults)
            state.selectVolume(URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true))
            state.menuBarVolumeGauge = .init(
                availableBytes: mode == .lowSpace ? 5 * gib : 70 * gib,
                totalBytes: 100 * gib
            )
            state.isLowSpace = mode == .lowSpace
            state.storageTrendHistory = [
                summary(date: Date(timeIntervalSince1970: 100), path: "/Volumes/Archive", free: 80),
                summary(date: Date(timeIntervalSince1970: 200), path: "/Volumes/Archive", free: 70),
            ]
            state.fsChanges = [change("/Volumes/Archive/Projects", count: 12, created: true)]
            state.temporalDiff.availableCheckpoints = [SnapshotCheckpoint(
                createdAt: Date(), rootPath: "/Volumes/Archive", totalBytes: 1,
                dirCount: 1, filename: "preview.dwcp", storedBytes: 1,
                summary: CheckpointChangeSummary(
                    totalDelta: 3 * Int64(gib),
                    topGrown: [.init(path: "/Volumes/Archive/Movies", deltaBytes: 3 * Int64(gib))],
                    topShrunk: [], deletedCount: 0, deletedBytes: 0, addedCount: 1
                )
            )]
            if mode == .scanning {
                state.scanProgress.isScanning = true
                state.scanProgress.currentPath = "Scanning Projects…"
            }

            let view = MenuBarPanel(
                appState: state,
                openDirWiz: {},
                quit: {},
                refreshStatsOnAppear: false
            )
            .frame(width: 360, height: 590, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 590)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 10_000)

            if ProcessInfo.processInfo.environment["DIRWIZ_CAPTURE_MENU_BAR_RENDERS"] == "1" {
                let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/menu-bar-renders", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("\(mode.rawValue).png"), options: .atomic)
            }
        }
    }

    private func summary(date: Date, path: String, free: UInt64) -> ScanSummary {
        ScanSummary(
            date: date, rootPath: path, totalUsed: free < 1_000 ? 1_000 - free : 0,
            totalFree: free, totalCapacity: 1_000,
            fileCount: 1, directoryCount: 1, topDirectories: []
        )
    }

    private func change(
        _ path: String,
        count: Int,
        created: Bool = false,
        deleted: Bool = false
    ) -> DirectoryChangeSummary {
        DirectoryChangeSummary(
            id: path, path: path, changeCount: count, lastChangeDate: .distantPast,
            hasCreations: created, hasDeletions: deleted, hasModifications: false
        )
    }
}
