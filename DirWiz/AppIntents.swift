import AppIntents
import DirWizCore
import DirWizUI
import Foundation

@MainActor
final class DirWizRuntime {
    static let shared = DirWizRuntime()
    weak var appState: AppState?
    private init() {}

    var defaultPath: String? {
        appState?.selectedVolume?.path ?? appState?.lastScannedVolumePath
    }
}

struct GetFreeSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Free Space"
    static let description = IntentDescription("Get current free space for a volume without starting a scan.")
    static let openAppWhenRun = false

    @Parameter(title: "Volume Path", description: "Leave empty to use DirWiz's current volume.")
    var volumePath: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let path = resolvedPath(volumePath),
              let gauge = VolumeByteStatsReader.read(path: path) else {
            throw DirWizIntentError.noVolume
        }
        let value = SizeFormatter.shared.format(gauge.availableBytes)
        return .result(
            value: value,
            dialog: "\(value) is free on \(displayName(path))."
        )
    }
}

struct LargestFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Largest Files"
    static let description = IntentDescription("Return the largest files from DirWiz's saved tree, without scanning.")
    static let openAppWhenRun = false

    @Parameter(title: "Count", default: 10, controlStyle: .stepper)
    var count: Int

    @Parameter(title: "Volume Path", description: "Leave empty to use DirWiz's current volume.")
    var volumePath: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        guard let path = resolvedPath(volumePath) else { throw DirWizIntentError.noVolume }
        guard case .success(let payload) = TreeCache.loadResult(for: path) else {
            throw DirWizIntentError.noCache(path)
        }
        let result = CachedTreeQuery.largestFiles(
            in: payload.tree,
            cacheSavedAt: payload.savedAt,
            count: count
        )
        let files = result.files.map {
            IntentFile(fileURL: URL(fileURLWithPath: $0.path), filename: URL(fileURLWithPath: $0.path).lastPathComponent)
        }
        let age = cacheAge(result.cacheSavedAt)
        return .result(
            value: files,
            dialog: "Returned \(files.count) files from the DirWiz cache saved \(age)."
        )
    }
}

struct ScanVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan Volume"
    static let description = IntentDescription("Start DirWiz's existing scan flow for a volume or folder.")
    static let openAppWhenRun = true

    @Parameter(title: "Volume or Folder Path", description: "Leave empty to use DirWiz's current volume.")
    var volumePath: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let path = resolvedPath(volumePath), let state = DirWizRuntime.shared.appState else {
            throw DirWizIntentError.noVolume
        }
        state.startScan(path: path)
        return .result(dialog: "DirWiz started scanning \(displayName(path)).")
    }
}

struct TakeCheckpointIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Checkpoint"
    static let description = IntentDescription("Record a checkpoint from DirWiz's current cached tree.")
    static let openAppWhenRun = false

    @Parameter(title: "Name", description: "An optional name pins this checkpoint.")
    var name: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let state = DirWizRuntime.shared.appState, state.fileTree != nil else {
            throw DirWizIntentError.noDisplayedTree
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.takeSnapshot(name: trimmed?.isEmpty == false ? trimmed : nil)
        return .result(dialog: "DirWiz is taking a checkpoint.")
    }
}

struct DirWizShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetFreeSpaceIntent(),
            phrases: ["Get free space with \(.applicationName)"],
            shortTitle: "Get Free Space",
            systemImageName: "internaldrive"
        )
        AppShortcut(
            intent: LargestFilesIntent(),
            phrases: ["Show largest files in \(.applicationName)"],
            shortTitle: "Largest Files",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: ScanVolumeIntent(),
            phrases: ["Scan a volume with \(.applicationName)"],
            shortTitle: "Scan Volume",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: TakeCheckpointIntent(),
            phrases: ["Take a checkpoint in \(.applicationName)"],
            shortTitle: "Take Checkpoint",
            systemImageName: "camera"
        )
    }
}

private enum DirWizIntentError: LocalizedError {
    case noVolume
    case noCache(String)
    case noDisplayedTree

    var errorDescription: String? {
        switch self {
        case .noVolume: "Open DirWiz and choose a volume first."
        case .noCache(let path): "DirWiz has no saved scan for \(path). Scan it first."
        case .noDisplayedTree: "Open DirWiz and complete a scan before taking a checkpoint."
        }
    }
}

@MainActor
private func resolvedPath(_ input: String?) -> String? {
    let trimmed = input?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : DirWizRuntime.shared.defaultPath
}

private func displayName(_ path: String) -> String {
    path == "/" ? "Macintosh HD" : URL(fileURLWithPath: path).lastPathComponent
}

private func cacheAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    if seconds < 3_600 { return "\(Int(seconds / 60)) minutes ago" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600)) hours ago" }
    return "\(Int(seconds / 86_400)) days ago"
}
