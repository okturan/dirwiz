import SwiftUI

/// A single row in the tree table showing file/folder details.
struct TreeRow: View {
    let item: TreeNodeItem
    let parentSize: UInt64
    let isSelected: Bool
    let extensionPalette: ExtensionPalette

    var body: some View {
        HStack(spacing: 0) {
            nameColumn
                .frame(minWidth: 200, alignment: .leading)
            percentageColumn
                .frame(minWidth: 100, alignment: .leading)
            Text(SizeFormatter.shared.format(item.node.fileSize))
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 80, alignment: .trailing)
            Text(SizeFormatter.shared.format(item.node.allocatedSize))
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 80, alignment: .trailing)
            itemsColumn
                .frame(minWidth: 60, alignment: .trailing)
            Text(formattedDate)
                .font(.system(size: 11))
                .frame(minWidth: 100, alignment: .trailing)
        }
    }

    // MARK: - Column Views

    private var nameColumn: some View {
        HStack(spacing: 5) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(item.isDirectory ? .blue : .secondary)

            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var percentageColumn: some View {
        let pct = parentSize > 0 ? Double(item.node.fileSize) / Double(parentSize) : 0

        return HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(categoryColor)
                        .frame(width: max(0, geo.size.width * pct))
                }
            }
            .frame(width: 60, height: 10)

            Text(String(format: "%.1f%%", pct * 100))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var itemsColumn: some View {
        Group {
            if item.isDirectory {
                Text(SizeFormatter.shared.formatCount(Int(item.node.childCount)))
                    .font(.system(size: 11, design: .monospaced))
            } else {
                Text("-")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private var categoryColor: Color {
        if item.isDirectory {
            return .blue.opacity(0.6)
        }
        return extensionPalette.swiftUIColor(forHash: item.node.extensionHash)
    }

    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private var formattedDate: String {
        guard item.node.modifiedDate > 0 else { return "-" }
        let date = Date(timeIntervalSince1970: TimeInterval(item.node.modifiedDate))
        return Self.sharedDateFormatter.string(from: date)
    }

}
