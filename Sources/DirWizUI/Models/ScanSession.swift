import DirWizCore
import Foundation
import Observation

@MainActor
@Observable
public final class ScanSession {
    @ObservationIgnored public var activeScanner: FileScanner?
    public var token: UInt64 = 0
    public var startTime: CFAbsoluteTime = 0
    public var duration: TimeInterval = 0

    public init() {}

    /// Cancels whatever scanner is currently registered and immediately drops the
    /// reference. Clearing it here (rather than leaving it for `markFinished()`) makes
    /// `activeScanner == nil` a reliable "no real scanner registered yet for the current
    /// flow" signal the instant a click lands — including during another flow's
    /// replay-wait, before it has registered a scanner of its own (`AppState.isPreparingScan`
    /// relies on exactly this).
    public func cancelActiveScan() {
        activeScanner?.cancel()
        activeScanner = nil
    }

    public func resetTiming() {
        startTime = 0
        duration = 0
    }

    public func markStarted(scanner: FileScanner) {
        activeScanner = scanner
        startTime = CFAbsoluteTimeGetCurrent()
        duration = 0
    }

    public func markFinished() {
        duration = CFAbsoluteTimeGetCurrent() - startTime
        activeScanner = nil
    }

    public func invalidate() {
        token &+= 1
    }
}
