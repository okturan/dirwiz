import SwiftUI
import DirWizCore

/// Displays scanning progress with live statistics and cancel button.
public struct ScanProgressView: View {
    let scanProgress: ScanProgress
    var onCancel: (() -> Void)?

    public init(scanProgress: ScanProgress, onCancel: (() -> Void)? = nil) {
        self.scanProgress = scanProgress
        self.onCancel = onCancel
    }

    public var body: some View {
        if scanProgress.isScanning {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Scanning...")
                        .font(.headline)
                    Spacer()
                    if let onCancel {
                        Button("Cancel", role: .destructive) {
                            onCancel()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }

                // Determinate progress bar if we have an estimate, indeterminate otherwise.
                if let fraction = scanProgress.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .animation(.linear(duration: 0.25), value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                // Stats grid.
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Label("Files", systemImage: "doc")
                            .foregroundStyle(.secondary)
                        Text(SizeFormatter.shared.formatCount(scanProgress.filesScanned))
                            .font(.system(.body, design: .monospaced))
                            .contentTransition(.numericText())
                    }

                    GridRow {
                        Label("Directories", systemImage: "folder")
                            .foregroundStyle(.secondary)
                        Text(SizeFormatter.shared.formatCount(scanProgress.directoriesScanned))
                            .font(.system(.body, design: .monospaced))
                            .contentTransition(.numericText())
                    }

                    GridRow {
                        Label("Size", systemImage: "internaldrive")
                            .foregroundStyle(.secondary)
                        Text(SizeFormatter.shared.format(scanProgress.totalSize))
                            .font(.system(.body, design: .monospaced))
                            .contentTransition(.numericText())
                    }

                    GridRow {
                        Label("Elapsed", systemImage: "clock")
                            .foregroundStyle(.secondary)
                        Text(formatElapsed(scanProgress.elapsedTime))
                            .font(.system(.body, design: .monospaced))
                            .contentTransition(.numericText())
                    }

                    GridRow {
                        Label("Rate", systemImage: "speedometer")
                            .foregroundStyle(.secondary)
                        Text(formatRate(scanProgress.filesPerSecond))
                            .font(.system(.body, design: .monospaced))
                            .contentTransition(.numericText())
                    }
                }
                .font(.callout)
                .animation(.linear(duration: 0.25), value: scanProgress.filesScanned)

                // Current path being scanned.
                if !scanProgress.currentPath.isEmpty {
                    Text(scanProgress.currentPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Formatting

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return String(format: "%d:%02d", mins, secs)
        }
        return String(format: "%.1fs", seconds)
    }

    private func formatRate(_ filesPerSecond: Double) -> String {
        if filesPerSecond >= 1 {
            return String(format: "%.0f files/s", filesPerSecond)
        } else {
            return "..."
        }
    }
}
