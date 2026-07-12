import SwiftUI
import DirWizCore
import AppKit

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
                            isSelected: appState.selectedVolume == volume.url
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.selectedVolume = volume.url
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
        if let url = appState.selectedVolume,
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

    private var scanButton: some View {
        VStack(spacing: 6) {
            Button(action: onScan) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Scan Volume")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.selectedVolume == nil || appState.scanProgress.isScanning)

            if fullRescanAvailable {
                Button(action: onFullRescan) {
                    Text("Full Rescan")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(appState.scanProgress.isScanning)
                .help("Ignore the cached scan and re-enumerate the whole volume from scratch")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Only offer the escape hatch when there's actually a cache to bypass — a warm
    /// start wouldn't be attempted otherwise, so "Full Rescan" would be a no-op button.
    private var fullRescanAvailable: Bool {
        guard let url = appState.selectedVolume else { return false }
        return appState.hasCachedTree(for: url.path)
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

        appState.availableVolumes = urls.compactMap { url in
            // Filter to local volumes only.
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal == true else { return nil }
            return VolumeInfo(url: url, values: values)
        }

        // Auto-select root volume if nothing is selected.
        if appState.selectedVolume == nil {
            appState.selectedVolume = appState.availableVolumes.first?.url
        }
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
