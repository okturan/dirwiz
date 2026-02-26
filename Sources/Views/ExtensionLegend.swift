import SwiftUI

/// Right sidebar showing top extensions by size with WinDirStat-style palette colors.
public struct ExtensionLegend: View {
    let palette: ExtensionPalette
    let totalSize: UInt64

    public init(palette: ExtensionPalette, totalSize: UInt64) {
        self.palette = palette
        self.totalSize = totalSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("File Types")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if palette.entries.isEmpty {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "chart.pie",
                    description: Text("Scan a volume to see file type breakdown.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(palette.entries) { entry in
                            ExtensionRow(entry: entry, totalSize: totalSize)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 220)
    }
}

// MARK: - ExtensionRow

private struct ExtensionRow: View {
    let entry: PaletteEntry
    let totalSize: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Color swatch.
                Circle()
                    .fill(entry.swiftUIColor)
                    .frame(width: 10, height: 10)

                Text(displayName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(SizeFormatter.shared.format(entry.totalSize))
                        .font(.system(size: 11, design: .monospaced))

                    Text(SizeFormatter.shared.formatCount(entry.fileCount) + " files")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // Percentage bar.
            percentageBar
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var percentageBar: some View {
        let fraction = totalSize > 0 ? CGFloat(entry.totalSize) / CGFloat(totalSize) : 0
        let pctText = SizeFormatter.shared.percentage(entry.totalSize, of: totalSize)

        return HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.12))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(entry.swiftUIColor.opacity(0.7))
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 6)

            Text(pctText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var displayName: String {
        if entry.extensionName == "Other" {
            return "Other"
        }
        if entry.extensionName.isEmpty {
            return "(no ext)"
        }
        return ".\(entry.extensionName)"
    }
}
