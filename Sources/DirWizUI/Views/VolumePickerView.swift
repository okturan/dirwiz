import SwiftUI
import DirWizCore
import AppKit

enum VolumePickerPolicy {
    static func showsCombinedVolumes(volumeCount: Int) -> Bool {
        volumeCount >= 2
    }
}

/// Sidebar view listing mounted volumes with usage stats and a scan button.
public struct VolumePickerView: View {
    @Bindable var appState: AppState

    var onScan: () -> Void
    var onFullRescan: () -> Void

    public init(appState: AppState, onScan: @escaping () -> Void, onFullRescan: @escaping () -> Void) {
        self.appState = appState
        self.onScan = onScan
        self.onFullRescan = onFullRescan
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(appState.availableVolumes) { volume in
                        VolumeRow(
                            volume: volume,
                            isSelected: !appState.isCombinedVolumeSelection
                                && appState.selectedVolume == volume.url
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.selectVolume(volume.url)
                        }
                    }

                    if VolumePickerPolicy.showsCombinedVolumes(
                        volumeCount: appState.availableVolumes.count
                    ) {
                        Divider()
                            .padding(.vertical, 2)

                        CombinedVolumesRow(
                            volumeCount: appState.availableVolumes.count,
                            totalCapacity: combinedCapacity.total,
                            isSelected: appState.isCombinedVolumeSelection
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.selectCombinedVolumes()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            Divider()

            selectedVolumeStats

            scanButton
        }
        .onAppear {
            refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didMountNotification
        )) { _ in
            refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didUnmountNotification
        )) { _ in
            refreshVolumes()
        }
    }

    // MARK: - Subviews

    private var sectionHeader: some View {
        HStack {
            Text("Volumes")
                .font(.headline)
            Spacer()
            Button(action: refreshVolumes) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Refresh volume list")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var selectedVolumeStats: some View {
        if appState.isCombinedVolumeSelection,
           VolumePickerPolicy.showsCombinedVolumes(volumeCount: appState.availableVolumes.count) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Volumes") {
                    Text("\(appState.availableVolumes.count)")
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Used") {
                    Text(SizeFormatter.shared.format(combinedCapacity.used))
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Available") {
                    Text(SizeFormatter.shared.format(combinedCapacity.available))
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Total") {
                    Text(SizeFormatter.shared.format(combinedCapacity.total))
                        .font(.system(.body, design: .monospaced))
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else if let url = appState.selectedVolume,
           let volume = appState.availableVolumes.first(where: { $0.url == url }) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Used") {
                    Text(SizeFormatter.shared.format(volume.usedCapacity))
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Available") {
                    Text(SizeFormatter.shared.format(volume.availableCapacity))
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Total") {
                    Text(SizeFormatter.shared.format(volume.totalCapacity))
                        .font(.system(.body, design: .monospaced))
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    /// One state-driven control: an undisplayed selected volume can be scanned, while a volume
    /// that owns the displayed tree can only be rebuilt from scratch. Launch refresh and living
    /// view auto-apply own incremental freshness, so presenting both actions would be a false
    /// choice. Active work keeps this same control visible and explains why it is unavailable.
    private var scanButton: some View {
        let state = scanControlState
        return Button {
            state.perform(onScan: onScan, onFullRescan: onFullRescan)
        } label: {
            HStack {
                if state.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else if let systemImage = state.systemImage {
                    Image(systemName: systemImage)
                }
                Text(state.title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!state.isEnabled)
        .accessibilityLabel(Text(state.title))
        .help(state.helpText)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var scanControlState: VolumeScanControlState {
        VolumeScanControlState.resolve(
            selectedVolume: appState.selectedVolume,
            selectedMountTraversalScope: appState.selectedMountTraversalScope,
            displayedTreeRootPath: appState.fileTree?.rootPath,
            displayedTreeMountTraversalScope: appState.fileTree?.mountTraversalScope,
            isScanning: appState.scanProgress.isScanning,
            isPreparingScan: appState.isPreparingScan,
            isApplyingChanges: appState.isApplyingChanges
        )
    }

    // MARK: - Helpers

    private func refreshVolumes() {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else { return }

        let volumes: [VolumeInfo] = urls.compactMap { url in
            // Filter to local volumes only.
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal == true else { return nil }
            return VolumeInfo(url: url, values: values)
        }
        appState.reconcileAvailableVolumes(volumes)
    }

    private var combinedCapacity: (used: UInt64, available: UInt64, total: UInt64) {
        appState.availableVolumes.reduce(into: (used: 0, available: 0, total: 0)) {
            $0.used = addingClamped($0.used, $1.usedCapacity)
            $0.available = addingClamped($0.available, $1.availableCapacity)
            $0.total = addingClamped($0.total, $1.totalCapacity)
        }
    }

    private func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

// MARK: - VolumeRow

private struct VolumeRow: View {
    let volume: VolumeInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            volumeIcon
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                usageBar

                HStack {
                    Text(SizeFormatter.shared.format(volume.usedCapacity) + " used")
                    Spacer()
                    Text(SizeFormatter.shared.format(volume.totalCapacity) + " total")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }

    private var usageBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: 2)
                    .fill(usageColor)
                    .frame(width: geo.size.width * usageFraction)
            }
        }
        .frame(height: 6)
    }

    private var usageFraction: CGFloat {
        guard volume.totalCapacity > 0 else { return 0 }
        return CGFloat(volume.usedCapacity) / CGFloat(volume.totalCapacity)
    }

    private var usageColor: Color {
        if usageFraction > 0.9 {
            return .red
        } else if usageFraction > 0.75 {
            return .orange
        } else {
            return .accentColor
        }
    }

    private var volumeIcon: Image {
        let nsImage = NSWorkspace.shared.icon(forFile: volume.url.path)
        return Image(nsImage: nsImage)
    }
}

// MARK: - CombinedVolumesRow

private struct CombinedVolumesRow: View {
    let volumeCount: Int
    let totalCapacity: UInt64
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text("All Volumes")
                    .font(.system(size: 13, weight: .medium))
                Text("\(volumeCount) mounted volumes in one map")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(SizeFormatter.shared.format(totalCapacity) + " total")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.4) : Color.clear,
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All Volumes, \(volumeCount) mounted volumes in one map")
    }
}
