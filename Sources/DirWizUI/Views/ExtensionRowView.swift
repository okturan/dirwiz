import SwiftUI
import DirWizCore

/// The one place a file-extension row is described.
///
/// File-type information appears on two surfaces - the always-visible sidebar legend and
/// the Extensions tab - which had drifted into different visual hierarchies and different
/// capabilities (the always-visible one being the inert one, which is backwards). Both now
/// build from this model, so a change to naming or formatting cannot land on one surface
/// and miss the other.
public struct ExtensionRowModel: Identifiable, Sendable, Equatable {
    /// Extension hash, or `ExtensionRowModel.otherID` for the synthetic "Other" bucket.
    public let id: UInt32
    public let rawName: String
    public let color: SIMD4<Float>
    public let totalSize: UInt64
    public let fileCount: Int

    /// `ExtensionPalette` reserves `UInt32.max` for the aggregated tail.
    public static let otherID: UInt32 = .max

    public init(id: UInt32, rawName: String, color: SIMD4<Float>, totalSize: UInt64, fileCount: Int) {
        self.id = id
        self.rawName = rawName
        self.color = color
        self.totalSize = totalSize
        self.fileCount = fileCount
    }

    public init(_ entry: PaletteEntry) {
        self.init(id: entry.id, rawName: entry.extensionName, color: entry.color,
                  totalSize: entry.totalSize, fileCount: entry.fileCount)
    }

    /// "Other" aggregates many extensions, so there is nothing to filter Search by.
    public var isOther: Bool { id == ExtensionRowModel.otherID }

    /// Single source of truth for how an extension is spelled in the UI.
    public var displayName: String {
        if isOther { return "Other" }
        if rawName.isEmpty { return "(no ext)" }
        return ".\(rawName)"
    }

    public var swiftUIColor: Color {
        Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z))
    }

    public func fraction(of total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return Double(totalSize) / Double(total)
    }
}

/// Compact legend row: swatch, name, size/count, percentage bar - and, unlike before,
/// tappable, because the treemap's color key is exactly where you want to say
/// "show me these files".
public struct ExtensionLegendRow: View {
    let model: ExtensionRowModel
    let totalSize: UInt64
    let onActivate: () -> Void

    @State private var isHovering = false

    public init(model: ExtensionRowModel, totalSize: UInt64, onActivate: @escaping () -> Void) {
        self.model = model
        self.totalSize = totalSize
        self.onActivate = onActivate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.swiftUIColor)
                    .frame(width: 10, height: 10)

                Text(model.displayName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(SizeFormatter.shared.format(model.totalSize))
                        .font(.system(size: 11, design: .monospaced))
                    Text(SizeFormatter.shared.formatCount(model.fileCount) + " files")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }

            percentageBar
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.secondary.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { hovering in
            isHovering = hovering
            // A pointing cursor is what makes the row discoverable as tappable at all.
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(model.isOther
              ? "Other groups many extensions - open the Extensions tab to see them"
              : "Search for \(model.displayName) files")
    }

    private var percentageBar: some View {
        let fraction = CGFloat(model.fraction(of: totalSize))
        let pctText = SizeFormatter.shared.percentage(model.totalSize, of: totalSize)

        return HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(model.swiftUIColor.opacity(0.7))
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
