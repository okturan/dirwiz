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

    public func cancelActiveScan() {
        activeScanner?.cancel()
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
