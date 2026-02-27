import SwiftUI

/// Combined insights tab: file age, size distribution, purgeable space,
/// Time Machine snapshots, iCloud status, storage trends, and FS changes.
public struct InsightsView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                analysisActions
                fileAgeSection
                sizeDistributionSection
                volumeInfoSection
                tmSnapshotSection
                iCloudSection
                fsChangesSection
                storageTrendsSection
            }
            .padding(12)
        }
    }

    // MARK: - Actions Bar

    private var analysisActions: some View {
        HStack(spacing: 8) {
            Button(action: { appState.startSpaceAnalysis() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar")
                    Text("Run Analysis")
                }
            }
            .disabled(!appState.canStartHeavyTask(.spaceAnalysis))

            Button(action: { appState.startICloudAnalysis() }) {
                HStack(spacing: 4) {
                    Image(systemName: "icloud")
                    Text("iCloud Status")
                }
            }
            .disabled(!appState.canStartHeavyTask(.iCloudAnalysis))

            Button(action: { appState.queryAPFSInfo() }) {
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                    Text("Volume Info")
                }
            }
            .disabled(!appState.canStartHeavyTask(.apfsQuery))

            Button(action: { appState.toggleFSMonitoring() }) {
                HStack(spacing: 4) {
                    Image(systemName: appState.isFSMonitoringActive ? "eye.slash" : "eye")
                    Text(appState.isFSMonitoringActive ? "Stop Watching" : "Watch Changes")
                }
            }
            .disabled(appState.fileTree == nil)

            Spacer()

            if let status = appState.activeHeavyTaskStatusText {
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - File Age

    @ViewBuilder
    private var fileAgeSection: some View {
        if let result = appState.fileAgeResult, !result.buckets.isEmpty {
            sectionHeader("File Age Distribution", icon: "calendar")
            VStack(spacing: 2) {
                ForEach(result.buckets.filter { $0.fileCount > 0 }) { bucket in
                    HStack {
                        Text(bucket.label)
                            .font(.system(size: 11))
                            .frame(width: 100, alignment: .leading)

                        barView(fraction: bucket.percentage / 100.0, color: ageColor(bucket.id))

                        Text(SizeFormatter.shared.format(bucket.totalSize))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 80, alignment: .trailing)

                        Text(SizeFormatter.shared.formatCount(bucket.fileCount) + " files")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)

                        Text(String(format: "%.1f%%", bucket.percentage))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .frame(height: 20)
                }
            }
        }
    }

    private func ageColor(_ bucketId: String) -> Color {
        switch bucketId {
        case "recent_30d": return .green
        case "30_90d": return .blue
        case "90d_1y": return .yellow
        case "1_2y": return .orange
        case "2y_plus": return .red
        default: return .gray
        }
    }

    // MARK: - Size Distribution

    @ViewBuilder
    private var sizeDistributionSection: some View {
        if let result = appState.sizeDistribution, !result.buckets.isEmpty {
            sectionHeader("Size Distribution", icon: "chart.bar.xaxis")
            VStack(spacing: 2) {
                let maxCount = result.buckets.map(\.fileCount).max() ?? 1
                ForEach(result.buckets.filter { $0.fileCount > 0 }) { bucket in
                    HStack {
                        Text(bucket.label)
                            .font(.system(size: 11))
                            .frame(width: 100, alignment: .leading)

                        barView(
                            fraction: Double(bucket.fileCount) / Double(max(maxCount, 1)),
                            color: .blue
                        )

                        Text(SizeFormatter.shared.formatCount(bucket.fileCount))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)

                        Text(SizeFormatter.shared.format(bucket.totalSize))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .frame(height: 18)
                }
            }
            .padding(.bottom, 4)
            HStack(spacing: 16) {
                statPill("Median", SizeFormatter.shared.format(result.medianSize))
                statPill("Mean", SizeFormatter.shared.format(result.meanSize))
                statPill("P90", SizeFormatter.shared.format(result.percentiles.p90))
                statPill("P99", SizeFormatter.shared.format(result.percentiles.p99))
            }
        }
    }

    // MARK: - Volume Info (Purgeable Space)

    @ViewBuilder
    private var volumeInfoSection: some View {
        if let info = appState.purgeableSpace {
            sectionHeader("Volume Space", icon: "internaldrive")
            HStack(spacing: 20) {
                statPill("Total", SizeFormatter.shared.format(info.totalCapacity))
                statPill("Free", SizeFormatter.shared.format(info.availableCapacity))
                statPill("Purgeable", SizeFormatter.shared.format(info.purgeableAmount))
                statPill("True Free", SizeFormatter.shared.format(info.availableForOpportunistic))
            }
            if info.purgeableAmount > 0 {
                Text("macOS can reclaim \(SizeFormatter.shared.format(info.purgeableAmount)) under storage pressure (Time Machine snapshots, caches, iCloud cached files)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: - Time Machine Snapshots

    @ViewBuilder
    private var tmSnapshotSection: some View {
        if let info = appState.tmSnapshots, !info.snapshots.isEmpty {
            sectionHeader("Time Machine Local Snapshots (\(info.snapshots.count))", icon: "clock.arrow.2.circlepath")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(info.snapshots.prefix(8)) { snap in
                    HStack {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(Self.dateFormatter.string(from: snap.date))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                if info.snapshots.count > 8 {
                    Text("... and \(info.snapshots.count - 8) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - iCloud

    @ViewBuilder
    private var iCloudSection: some View {
        if let result = appState.iCloudResult, !result.groups.isEmpty {
            sectionHeader("iCloud Drive", icon: "icloud")
            VStack(spacing: 4) {
                HStack(spacing: 16) {
                    statPill("Local", SizeFormatter.shared.format(result.totalLocalSize))
                    statPill("Evictable", SizeFormatter.shared.format(result.evictableSize))
                    statPill("Cloud Only", SizeFormatter.shared.format(result.cloudOnlySize))
                }
                ForEach(result.groups) { group in
                    HStack {
                        iCloudStatusIcon(group.status)
                        Text(group.status.rawValue)
                            .font(.system(size: 11))
                        Spacer()
                        Text(SizeFormatter.shared.formatCount(group.fileCount) + " files")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(SizeFormatter.shared.format(group.totalSize))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }

    private func iCloudStatusIcon(_ status: iCloudStatus) -> some View {
        let (icon, color): (String, Color) = {
            switch status {
            case .downloaded: return ("arrow.down.circle.fill", .green)
            case .cloudOnly: return ("icloud", .blue)
            case .downloading: return ("arrow.down.circle.dotted", .orange)
            case .unknown: return ("questionmark.circle", .gray)
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 11))
            .foregroundStyle(color)
    }

    // MARK: - FS Changes

    @ViewBuilder
    private var fsChangesSection: some View {
        if !appState.fsChanges.isEmpty {
            sectionHeader("Filesystem Changes Since Scan (\(appState.fsChanges.count))", icon: "eye")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(appState.fsChanges.prefix(15)) { change in
                    HStack(spacing: 6) {
                        HStack(spacing: 2) {
                            if change.hasCreations {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.green)
                            }
                            if change.hasDeletions {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                            }
                            if change.hasModifications {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .frame(width: 40)

                        Text(abbreviatePath(change.path))
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Text("\(change.changeCount)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if appState.fsChanges.count > 15 {
                    Text("... and \(appState.fsChanges.count - 15) more directories")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Storage Trends

    @ViewBuilder
    private var storageTrendsSection: some View {
        if !appState.storageTrendHistory.isEmpty {
            sectionHeader("Storage Trends (\(appState.storageTrendHistory.count) scans)", icon: "chart.line.uptrend.xyaxis")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Date")
                        .frame(width: 140, alignment: .leading)
                    Text("Used")
                        .frame(width: 80, alignment: .trailing)
                    Text("Free")
                        .frame(width: 80, alignment: .trailing)
                    Text("Files")
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

                ForEach(Array(appState.storageTrendHistory.suffix(10).reversed().enumerated()), id: \.offset) { _, summary in
                    HStack {
                        Text(Self.dateFormatter.string(from: summary.date))
                            .frame(width: 140, alignment: .leading)
                        Text(SizeFormatter.shared.format(summary.totalUsed))
                            .frame(width: 80, alignment: .trailing)
                        Text(SizeFormatter.shared.format(summary.totalFree))
                            .frame(width: 80, alignment: .trailing)
                        Text(SizeFormatter.shared.formatCount(summary.fileCount))
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Shared Components

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.top, 4)
    }

    private func barView(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.1))
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.4))
                    .frame(width: max(1, geo.size.width * CGFloat(min(fraction, 1.0))))
            }
        }
        .frame(height: 12)
    }

    private func statPill(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
