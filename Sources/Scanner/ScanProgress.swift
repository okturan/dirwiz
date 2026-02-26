import Foundation
import Observation
import Synchronization

/// Observable scan state published by the file scanner.
/// Hot counters are updated from scanner background threads without triggering
/// @Observable notifications. Call `publishCounters()` on the main thread
/// at throttled intervals to sync to observable properties.
@Observable
public final class ScanProgress: @unchecked Sendable {
    // MARK: - Observable properties (read by SwiftUI, written only on main thread)

    public var isScanning: Bool = false
    public var filesScanned: Int = 0
    public var directoriesScanned: Int = 0
    public var totalSize: UInt64 = 0
    public var currentPath: String = ""
    public var elapsedTime: TimeInterval = 0
    public var scanComplete: Bool = false
    public var isCancelled: Bool = false
    public var error: String?
    public var estimatedTotalItems: Int = 0
    public var scannedAllocatedBytes: UInt64 = 0

    // MARK: - Hot counters (written from scanner threads, NOT observable)

    private struct HotCounters: Sendable {
        var files: Int = 0
        var dirs: Int = 0
        var totalSize: UInt64 = 0
        var allocatedBytes: UInt64 = 0
        var path: String = ""
        var publishCount: Int = 0
    }

    @ObservationIgnored private let hot = Mutex(HotCounters())

    /// Bumped every ~10 publishCounters() calls (≈2.5s) and once at scan end.
    /// Used as the treemap layout revision signal to avoid re-layout on every
    /// progress update (which would cancel in-flight layout tasks continuously).
    public private(set) var treeLayoutRevision: Int = 0

    public init() {}

    public var filesPerSecond: Double {
        guard elapsedTime > 0 else { return 0 }
        return Double(filesScanned) / elapsedTime
    }

    public var totalItems: Int {
        filesScanned + directoriesScanned
    }

    /// Progress fraction 0.0–1.0, or nil if estimate is unavailable.
    /// Capped at 0.99 during scanning to avoid showing completion before finalization.
    /// Shows 1.0 only after scan completes.
    public var fractionCompleted: Double? {
        guard estimatedTotalItems > 0 else { return nil }
        let raw = Double(totalItems) / Double(estimatedTotalItems)
        return isScanning ? min(0.99, raw) : min(1.0, raw)
    }

    @MainActor public func reset() {
        hot.withLock { counters in
            counters.files = 0
            counters.dirs = 0
            counters.totalSize = 0
            counters.allocatedBytes = 0
            counters.path = ""
            counters.publishCount = 0
        }

        isScanning = false
        filesScanned = 0
        directoriesScanned = 0
        totalSize = 0
        currentPath = ""
        elapsedTime = 0
        scanComplete = false
        isCancelled = false
        error = nil
        estimatedTotalItems = 0
        scannedAllocatedBytes = 0
        treeLayoutRevision = 0
    }

    /// Called from scanner background threads. Does NOT trigger @Observable.
    public func incrementFiles(count: Int = 1, size: UInt64 = 0, allocatedSize: UInt64 = 0) {
        hot.withLock { counters in
            counters.files += count
            counters.totalSize += size
            counters.allocatedBytes += allocatedSize
        }
    }

    /// Called from scanner background threads. Does NOT trigger @Observable.
    public func incrementDirectories(count: Int = 1) {
        hot.withLock { counters in
            counters.dirs += count
        }
    }

    /// Called from scanner background threads. Does NOT trigger @Observable.
    public func updateCurrentPath(_ path: String) {
        hot.withLock { counters in
            counters.path = path
        }
    }

    /// Sync hot counters to observable properties.
    /// Must be called on the main thread at throttled intervals.
    /// Pass `forceLayoutRevision: true` at scan completion to guarantee a final layout.
    @MainActor public func publishCounters(forceLayoutRevision: Bool = false) {
        let snapshot = hot.withLock { counters -> HotCounters in
            counters.publishCount += 1
            return counters
        }

        filesScanned = snapshot.files
        directoriesScanned = snapshot.dirs
        totalSize = snapshot.totalSize
        scannedAllocatedBytes = snapshot.allocatedBytes
        currentPath = snapshot.path

        // Bump layout revision every 10 publishes (≈2.5s) or when forced at scan end.
        if snapshot.publishCount % 10 == 0 || forceLayoutRevision {
            treeLayoutRevision &+= 1
        }
    }
}
