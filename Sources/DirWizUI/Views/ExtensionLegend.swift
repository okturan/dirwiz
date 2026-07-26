import SwiftUI
import DirWizCore

/// Right sidebar showing top extensions by size with WinDirStat-style palette colors.
///
/// This is the treemap's color key, and it is always on screen — so it is also the most
/// natural place to say "show me these files". Rows share `ExtensionLegendRow` with the
/// Extensions tab and perform the same drill-down, rather than being an inert twin of it.
public struct ExtensionLegend: View {
    let palette: ExtensionPalette
    let totalSize: UInt64
    /// Invoked with the tapped row; "Other" is handled by the shared seam.
    let onSelect: ((ExtensionRowModel) -> Void)?
    let onSeeAll: (() -> Void)?

    public init(
        palette: ExtensionPalette,
        totalSize: UInt64,
        onSelect: ((ExtensionRowModel) -> Void)? = nil,
        onSeeAll: (() -> Void)? = nil
    ) {
        self.palette = palette
        self.totalSize = totalSize
        self.onSelect = onSelect
        self.onSeeAll = onSeeAll
    }

    private var models: [ExtensionRowModel] {
        palette.entries.map(ExtensionRowModel.init)
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
                        ForEach(models) { model in
                            ExtensionLegendRow(model: model, totalSize: totalSize) {
                                onSelect?(model)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }

                if onSeeAll != nil {
                    Divider()
                    Button(action: { onSeeAll?() }) {
                        HStack(spacing: 4) {
                            Text("See all file types")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 220)
    }
}
