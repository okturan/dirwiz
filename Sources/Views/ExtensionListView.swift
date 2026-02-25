import SwiftUI

/// Sortable table of file extensions showing total size, count, and category.
public struct ExtensionListView: View {
    let fileTypeStats: [FileTypeStat]
    let totalSize: UInt64

    @State private var sortOrder: SortOrder = .size
    @State private var sortAscending: Bool = false
    @State private var searchText: String = ""

    public init(fileTypeStats: [FileTypeStat], totalSize: UInt64) {
        self.fileTypeStats = fileTypeStats
        self.totalSize = totalSize
    }

    public var body: some View {
        if fileTypeStats.isEmpty {
            ContentUnavailableView(
                "No Data",
                systemImage: "doc.text",
                description: Text("Scan a volume to see file types.")
            )
        } else {
            VStack(spacing: 0) {
                // Search bar.
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter extensions...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()

                // Header.
                headerRow

                Divider()

                // List.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedAndFiltered) { stat in
                            extensionRow(stat)
                            Divider().padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sort

    private enum SortOrder: String {
        case name, size, count, category
    }

    private var sortedAndFiltered: [FileTypeStat] {
        var result = fileTypeStats

        // Filter.
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.extensionName.lowercased().contains(query) ||
                $0.category.rawValue.lowercased().contains(query)
            }
        }

        // Sort.
        result.sort { a, b in
            let cmp: Bool
            switch sortOrder {
            case .name:
                cmp = a.extensionName.localizedCaseInsensitiveCompare(b.extensionName) == .orderedAscending
            case .size:
                cmp = a.totalSize > b.totalSize
            case .count:
                cmp = a.fileCount > b.fileCount
            case .category:
                cmp = a.category.rawValue < b.category.rawValue
            }
            return sortAscending ? !cmp : cmp
        }

        return result
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortButton("Extension", key: .name, width: 100, alignment: .leading)
            sortButton("Category", key: .category, width: 90, alignment: .leading)
            sortButton("Size", key: .size, width: 80, alignment: .trailing)
            sortButton("% Total", key: .size, width: 65, alignment: .trailing)
            sortButton("Files", key: .count, width: 65, alignment: .trailing)
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func sortButton(_ title: String, key: SortOrder, width: CGFloat, alignment: Alignment) -> some View {
        Button(action: {
            if sortOrder == key {
                sortAscending.toggle()
            } else {
                sortOrder = key
                sortAscending = false
            }
        }) {
            HStack(spacing: 3) {
                Text(title)
                if sortOrder == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .frame(width: width, alignment: alignment)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row

    private func extensionRow(_ stat: FileTypeStat) -> some View {
        HStack(spacing: 0) {
            // Extension name with color dot.
            HStack(spacing: 6) {
                Circle()
                    .fill(stat.category.color)
                    .frame(width: 8, height: 8)
                Text(".\(stat.extensionName)")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
            }
            .frame(width: 100, alignment: .leading)

            // Category.
            Text(stat.category.rawValue)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)

            // Size.
            Text(SizeFormatter.shared.format(stat.totalSize))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 80, alignment: .trailing)

            // Percentage with bar.
            HStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.12))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(stat.category.color.opacity(0.7))
                            .frame(width: max(0, geo.size.width * stat.percentage))
                    }
                }
                .frame(width: 30, height: 8)

                Text(String(format: "%.1f%%", stat.percentage * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 65, alignment: .trailing)

            // Count.
            Text(SizeFormatter.shared.formatCount(stat.fileCount))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 65, alignment: .trailing)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
