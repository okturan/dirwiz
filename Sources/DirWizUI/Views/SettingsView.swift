import SwiftUI
import DirWizCore

/// The app Settings window (⌘,). The Folders palette and surface used to be numbered
/// toolbar review menus ("Colors 7", "Surface 1") so native feedback could reference
/// options unambiguously; as product UI they live here under their real names. The
/// numbers remain internal identifiers only (raw values, and review labels in tests) -
/// the visual comparison itself stays open until a final choice is made on real trees.
public struct SettingsView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        Form {
            Section("Treemap") {
                Picker("Style", selection: $appState.treemapRenderStyle) {
                    ForEach(TreemapRenderStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Text("Cushions shade one tile per file and color by file type. Folders draws labelled boxes and colors by folder depth.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Folders appearance") {
                Picker("Color palette", selection: $appState.foldersColorScheme) {
                    ForEach(FoldersColorScheme.allCases) { scheme in
                        Text(scheme.displayName).tag(scheme)
                    }
                }
                depthKey(for: appState.foldersColorScheme)
                Text(appState.foldersColorScheme.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Surface", selection: $appState.foldersSurfaceStyle) {
                    ForEach(FoldersSurfaceStyle.allCases) { surface in
                        Text(surface.displayName).tag(surface)
                    }
                }
                Text(appState.foldersSurfaceStyle.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 430)
    }

    /// Outer-to-inner depth swatches for the selected palette - the same eight colours
    /// the sidebar key and every Folders card use (`CardGeometry.containerFill`).
    private func depthKey(for scheme: FoldersColorScheme) -> some View {
        HStack(spacing: 3) {
            Text("outer")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(0..<8, id: \.self) { depth in
                let fill = CardGeometry.containerFill(depth: depth, scheme: scheme)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(
                        red: Double(fill.x),
                        green: Double(fill.y),
                        blue: Double(fill.z)
                    ))
                    .frame(width: 22, height: 14)
            }
            Text("inner")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityLabel("Depth colors, outer to inner")
    }
}
