import SwiftUI
import DirWizCore

/// "Where did my disk go?" - the space categorization card, first section of Insights.
///
/// This used to be its own tab, driven by a "Run Analysis" button that lived on the
/// Insights tab and populated a DIFFERENT tab. Users experienced that as a button doing
/// nothing. The action and its results now live together in one card.
public struct SpaceAnalysisCard: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    /// The Analyze control sits in the section header so it stays reachable even when the
    /// card is collapsed.
    public var headerAccessory: AnyView {
        AnyView(
            HStack(spacing: 8) {
                if let result = appState.spaceAnalysis, !appState.isSpaceAnalysisRunning {
                    Text(SizeFormatter.shared.format(result.categorizedSize) + " categorized")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button(action: { appState.startSpaceAnalysis() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.pie")
                        Text(appState.spaceAnalysis == nil ? "Analyze" : "Re-analyze")
                    }
                    .font(.system(size: 11))
                }
                .disabled(!appState.canStartHeavyTask(.spaceAnalysis))
            }
        )
    }

    public var body: some View {
        if appState.isSpaceAnalysisRunning {
            analysisProgress
        } else if let result = appState.spaceAnalysis, !result.categories.isEmpty {
            categoryList(result)
        } else {
            emptyState
        }
    }

    private var analysisProgress: some View {
        VStack(spacing: 8) {
            if appState.spaceAnalysisProgress.total > 0 {
                Text(
                    "\(appState.spaceAnalysisProgress.completed) / " +
                    "\(appState.spaceAnalysisProgress.total) passes complete"
                )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ProgressView(
                    value: Double(appState.spaceAnalysisProgress.completed),
                    total: Double(max(appState.spaceAnalysisProgress.total, 1))
                )
                .progressViewStyle(.linear)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Category List

    private func categoryList(_ result: SpaceAnalysisResult) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(result.categories) { category in
                categoryRow(category, totalSize: result.totalAnalyzed)
            }
        }
    }

    private func categoryRow(_ category: SpaceCategory, totalSize: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                safetyBadge(category.safetyRating)

                VStack(alignment: .leading, spacing: 1) {
                    Text(category.name)
                        .font(.system(size: 12, weight: .medium))
                    Text(category.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(SizeFormatter.shared.format(category.totalSize))
                        .font(.system(size: 12, design: .monospaced))
                    if totalSize > 0 {
                        let pct = Double(category.totalSize) / Double(totalSize) * 100.0
                        Text(String(format: "%.1f%%", pct))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Size bar
            if totalSize > 0 {
                GeometryReader { geo in
                    let fraction = CGFloat(category.totalSize) / CGFloat(totalSize)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(safetyColor(category.safetyRating).opacity(0.3))
                        .frame(width: max(2, geo.size.width * fraction), height: 4)
                }
                .frame(height: 4)
            }

            // Matched paths (collapsed by default, but show top few)
            if !category.matchedPaths.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(category.matchedPaths.prefix(3), id: \.self) { path in
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(abbreviatePath(path))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if category.matchedPaths.count > 3 {
                        Text("... and \(category.matchedPaths.count - 3) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.04))
        )
    }

    private func safetyBadge(_ rating: SafetyRating) -> some View {
        let (icon, color, text): (String, Color, String) = {
            switch rating {
            case .safe:
                return ("checkmark.circle.fill", .green, "Safe")
            case .caution:
                return ("exclamationmark.triangle.fill", .orange, "Caution")
            case .informational:
                return ("info.circle.fill", .blue, "Info")
            }
        }()

        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: 70, alignment: .leading)
    }

    private func safetyColor(_ rating: SafetyRating) -> Color {
        switch rating {
        case .safe: return .green
        case .caution: return .orange
        case .informational: return .blue
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Text("Categorize disk usage into system data, developer caches, application data and more.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}
