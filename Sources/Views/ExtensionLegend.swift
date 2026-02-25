import SwiftUI

/// Right sidebar showing file type categories aggregated from extension stats, sorted by total size.
public struct ExtensionLegend: View {
    let extensionStats: [ExtensionStat]
    let totalSize: UInt64

    @Binding var selectedCategory: FileCategory?

    public init(
        extensionStats: [ExtensionStat],
        totalSize: UInt64,
        selectedCategory: Binding<FileCategory?>
    ) {
        self.extensionStats = extensionStats
        self.totalSize = totalSize
        self._selectedCategory = selectedCategory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("File Categories")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if aggregatedCategories.isEmpty {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "chart.pie",
                    description: Text("Scan a volume to see category breakdown.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(aggregatedCategories) { entry in
                            CategoryRow(
                                entry: entry,
                                totalSize: totalSize,
                                isSelected: selectedCategory == entry.category
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedCategory == entry.category {
                                    selectedCategory = nil
                                } else {
                                    selectedCategory = entry.category
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 220)
    }

    // MARK: - Aggregation

    private var aggregatedCategories: [CategoryEntry] {
        var sizeByCategory: [FileCategory: UInt64] = [:]
        var countByCategory: [FileCategory: Int] = [:]

        for stat in extensionStats {
            sizeByCategory[stat.category, default: 0] += stat.totalSize
            countByCategory[stat.category, default: 0] += stat.fileCount
        }

        return sizeByCategory
            .map { category, size in
                CategoryEntry(
                    category: category,
                    totalSize: size,
                    fileCount: countByCategory[category] ?? 0
                )
            }
            .sorted { $0.totalSize > $1.totalSize }
    }
}

// MARK: - CategoryEntry

private struct CategoryEntry: Identifiable {
    let category: FileCategory
    let totalSize: UInt64
    let fileCount: Int

    var id: String { category.rawValue }
}

// MARK: - CategoryRow

private struct CategoryRow: View {
    let entry: CategoryEntry
    let totalSize: UInt64
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Color swatch.
                Circle()
                    .fill(entry.category.color)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.category.rawValue)
                        .font(.system(size: 12, weight: .medium))

                    Text(entry.category.fileTypeDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

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
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? entry.category.color.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? entry.category.color.opacity(0.4) : Color.clear, lineWidth: 1)
        )
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
                        .fill(entry.category.color.opacity(0.7))
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
}
