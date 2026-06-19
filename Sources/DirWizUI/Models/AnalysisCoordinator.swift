import Foundation
import Observation

@MainActor
@Observable
public final class AnalysisCoordinator {
    @ObservationIgnored var duplicateTask: Task<Void, Never>?
    @ObservationIgnored var hardlinkTask: Task<Void, Never>?
    @ObservationIgnored var spaceAnalysisTask: Task<Void, Never>?
    @ObservationIgnored var iCloudAnalysisTask: Task<Void, Never>?
    @ObservationIgnored var apfsQueryTask: Task<Void, Never>?
    @ObservationIgnored var cloneCheckTask: Task<Void, Never>?
    @ObservationIgnored var bundleSizingTask: Task<Void, Never>?

    public init() {}

    public func cancelAll() {
        duplicateTask?.cancel()
        duplicateTask = nil
        hardlinkTask?.cancel()
        hardlinkTask = nil
        spaceAnalysisTask?.cancel()
        spaceAnalysisTask = nil
        iCloudAnalysisTask?.cancel()
        iCloudAnalysisTask = nil
        apfsQueryTask?.cancel()
        apfsQueryTask = nil
        cloneCheckTask?.cancel()
        cloneCheckTask = nil
        bundleSizingTask?.cancel()
        bundleSizingTask = nil
    }
}
