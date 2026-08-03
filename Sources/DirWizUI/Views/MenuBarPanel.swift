import AppKit
import SwiftUI
import DirWizCore

/// The ambient surface over the existing living view. Its only implicit work is the
/// single `refreshMenuBarVolumeStats()` call in `onAppear`.
public struct MenuBarPanel: View {
    @Bindable private var appState: AppState
    private let openDirWiz: () -> Void
    private let quit: () -> Void
    private let refreshStatsOnAppear: Bool

    public init(
        appState: AppState,
        openDirWiz: @escaping () -> Void,
        quit: @escaping () -> Void,
        refreshStatsOnAppear: Bool = true
    ) {
        self.appState = appState
        self.openDirWiz = openDirWiz
        self.quit = quit
        self.refreshStatsOnAppear = refreshStatsOnAppear
    }

    public var body: some View {
        let snapshot = appState.menuBarSnapshot
        VStack(alignment: .leading, spacing: 12) {
            header(snapshot)
            Divider()
            trend(snapshot)
            section(
                title: "Since last checkpoint",
                emptyText: "No growth recorded yet",
                items: snapshot.growers
            ) { item in
                metricRow(
                    icon: "arrow.up.right",
                    tint: .orange,
                    path: item.path,
                    value: "+" + SizeFormatter.shared.format(item.deltaBytes)
                )
            }
            changingNow(snapshot)
            status(snapshot)
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            // One statfs. No scan, enumeration, checkpoint read, or analyzer starts here.
            if refreshStatsOnAppear { appState.refreshMenuBarVolumeStats() }
        }
        .accessibilityIdentifier("DirWizMenuBarPanel")
    }

    private func header(_ snapshot: MenuBarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.secondary)
                Text(snapshot.volumeName)
                    .font(.headline)
                Spacer()
                if let gauge = snapshot.gauge {
                    Text(SizeFormatter.shared.format(gauge.availableBytes) + " free")
                        .font(.caption)
                        .foregroundStyle(appState.isLowSpace ? .orange : .secondary)
                }
            }
            if let gauge = snapshot.gauge {
                ProgressView(value: gauge.usedFraction)
                    .tint(appState.isLowSpace ? .orange : .accentColor)
                HStack {
                    Text(SizeFormatter.shared.format(gauge.usedBytes) + " used")
                    Spacer()
                    Text(SizeFormatter.shared.format(gauge.totalBytes) + " total")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text(snapshot.volumePath.isEmpty ? "Open DirWiz and select a volume" : "Space unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func trend(_ snapshot: MenuBarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Free space")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if snapshot.trend.count >= 2 {
                FreeSpaceSparkline(points: snapshot.trend)
                    .frame(height: 38)
                    .accessibilityLabel("Free-space trend")
            } else {
                Text("The trend appears after another scan")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func section<Item: Identifiable, Row: View>(
        title: String,
        emptyText: String,
        items: [Item],
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items) { row($0) }
            }
        }
    }

    private func changingNow(_ snapshot: MenuBarSnapshot) -> some View {
        section(
            title: "Changing now",
            emptyText: appState.isFSMonitoringActive ? "Quiet" : "Waiting for a completed scan",
            items: snapshot.changingNow
        ) { item in
            metricRow(
                icon: changeIcon(item),
                tint: .green,
                path: item.path,
                value: "\(item.changeCount)"
            )
        }
    }

    private func metricRow(icon: String, tint: Color, path: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 13)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func changeIcon(_ item: MenuBarChangingItem) -> String {
        if item.hasCreations && item.hasDeletions { return "arrow.left.arrow.right" }
        if item.hasCreations { return "plus.circle.fill" }
        if item.hasDeletions { return "minus.circle.fill" }
        return "pencil.circle.fill"
    }

    private func status(_ snapshot: MenuBarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scanStatus = snapshot.scanStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(scanStatus)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.liveRefreshPaused ? Color.secondary : Color.green)
                    .frame(width: 7, height: 7)
                Text(snapshot.livingViewStatus)
                    .lineLimit(1)
                Spacer()
                Text("Live")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Open DirWiz", action: openDirWiz)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button(appState.scanProgress.isScanning ? "Scanning…" : "Scan Now") {
                    appState.startFullRescan()
                }
                .disabled(appState.selectedVolume == nil || appState.scanProgress.isScanning)
                Button("Take Checkpoint") { appState.takeSnapshot() }
                    .disabled(appState.fileTree == nil || appState.temporalDiff.isSnapshotBuilding)
            }
            HStack {
                Button(appState.liveRefreshPaused ? "Resume Watching" : "Pause Watching") {
                    appState.toggleLiveRefreshPaused()
                }
                .disabled(appState.fileTree == nil)
                Spacer()
                Button("Quit DirWiz", role: .destructive, action: quit)
            }
        }
        .controlSize(.small)
    }
}

public struct DirWizMenuBarLabel: View {
    public let state: MenuBarIconState
    public let freeSpaceText: String?

    public init(state: MenuBarIconState, freeSpaceText: String?) {
        self.state = state
        self.freeSpaceText = freeSpaceText
    }

    public var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                templateImage
                    // Sized to sit with the system items: siblings like Wi-Fi carry
                    // internal padding, so a solid glyph filling a 19pt box read
                    // oversized next to them (verified against a real menu bar capture).
                    .frame(width: 16, height: 13)
                if state == .scanning {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 7, weight: .bold))
                        .padding(1)
                        .background(.bar, in: Circle())
                        .offset(x: 3, y: 2)
                } else if state == .lowSpace {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .offset(x: 3, y: 2)
                }
            }
            if let freeSpaceText {
                Text(freeSpaceText)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var templateImage: some View {
        if let url = Bundle.main.url(
            forResource: "DirWizMenuBarTemplate",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) {
            // The status item draws the NSImage at its INTRINSIC size, not the SwiftUI
            // frame - the SVG's 44×36pt viewBox rendered a glyph visibly larger than
            // its menu bar siblings until `size` was set here (verified against real
            // menu bar captures; the .frame alone changed nothing).
            let _ = {
                image.isTemplate = true
                image.size = NSSize(width: 16, height: 13)
            }()
            Image(nsImage: image)
                .renderingMode(.template)
        } else {
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.monochrome)
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: "DirWiz"
        case .scanning: "DirWiz, scanning"
        case .lowSpace: "DirWiz, low disk space"
        }
    }
}

private struct FreeSpaceSparkline: View {
    let points: [MenuBarTrendPoint]

    var body: some View {
        GeometryReader { proxy in
            let values = points.map(\.availableBytes)
            let minimum = values.min() ?? 0
            let maximum = values.max() ?? minimum
            let span = max(maximum - minimum, 1)
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = points.count == 1 ? 0 : proxy.size.width * CGFloat(index) / CGFloat(points.count - 1)
                    let normalized = Double(point.availableBytes - minimum) / Double(span)
                    let y = proxy.size.height * (1 - CGFloat(normalized))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
