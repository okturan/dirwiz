import SwiftUI
import DirWizCore

/// Right sidebar showing the active map key and top extensions by size.
///
/// Cushion uses extension colours, so its file rows are also the map key. Folders follows
/// SpaceMonger's depth-colour model; it shows that key explicitly, then keeps the file rows
/// as a useful size breakdown and drill-down surface without pretending their swatches map
/// to the cards. Rows share `ExtensionLegendRow` with the Extensions tab.
public struct ExtensionLegend: View {
    let palette: ExtensionPalette
    let totalSize: UInt64
    let renderStyle: TreemapRenderStyle
    let foldersColorScheme: FoldersColorScheme
    /// Invoked with the tapped row; "Other" is handled by the shared seam.
    let onSelect: ((ExtensionRowModel) -> Void)?
    let onSeeAll: (() -> Void)?

    public init(
        palette: ExtensionPalette,
        totalSize: UInt64,
        renderStyle: TreemapRenderStyle = .cushion,
        foldersColorScheme: FoldersColorScheme = .spaceMonger,
        onSelect: ((ExtensionRowModel) -> Void)? = nil,
        onSeeAll: (() -> Void)? = nil
    ) {
        self.palette = palette
        self.totalSize = totalSize
        self.renderStyle = renderStyle
        self.foldersColorScheme = foldersColorScheme
        self.onSelect = onSelect
        self.onSeeAll = onSeeAll
    }

    private var models: [ExtensionRowModel] {
        palette.entries.map { entry in
            ExtensionRowModel(
                id: entry.id,
                rawName: entry.extensionName,
                color: CardGeometry.paletteColor(
                    entry.color,
                    for: renderStyle,
                    foldersScheme: foldersColorScheme
                ),
                totalSize: entry.totalSize,
                fileCount: entry.fileCount
            )
        }
    }

    private var folderDepthKey: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Folder Depth")
                .font(.headline)

            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { depth in
                    let color = CardGeometry.containerFill(
                        depth: depth,
                        scheme: foldersColorScheme
                    )
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(
                            red: Double(color.x),
                            green: Double(color.y),
                            blue: Double(color.z)
                        ))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 10)

            HStack {
                Text("outer")
                Spacer()
                Text("inner")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

            Text(foldersColorScheme.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if renderStyle == .cards {
                folderDepthKey
                Divider()
            }

            Text("File Types")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, renderStyle == .cards ? 2 : 8)

            if renderStyle == .cards {
                Text("Size breakdown; map colors show depth")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 7)
            }

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
