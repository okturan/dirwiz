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

    private func depthKey(for scheme: FoldersColorScheme) -> some View {
        DepthKeyView(scheme: scheme)
    }
}

/// Outer-to-inner depth swatches for a palette - the same eight colours the sidebar key
/// and every Folders card use (`CardGeometry.containerFill`). Shared between the
/// Settings window and the toolbar appearance popover.
struct DepthKeyView: View {
    let scheme: FoldersColorScheme

    var body: some View {
        HStack(spacing: 3) {
            Text("outer")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
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
                .fixedSize()
        }
        .accessibilityLabel("Depth colors, outer to inner")
    }
}

/// Compact in-context Folders appearance controls, opened from the treemap toolbar's
/// paintpalette button. Settings (⌘,) is the canonical home, but nobody opens Settings
/// first - this popover mutates the same persisted state, so the map repaints live
/// behind it while options are tried, and it links to the full window.
public struct FoldersAppearancePopover: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Palette", selection: $appState.foldersColorScheme) {
                ForEach(FoldersColorScheme.allCases) { scheme in
                    Text(scheme.displayName).tag(scheme)
                }
            }
            DepthKeyView(scheme: appState.foldersColorScheme)
            Picker("Surface", selection: $appState.foldersSurfaceStyle) {
                ForEach(FoldersSurfaceStyle.allCases) { surface in
                    Text(surface.displayName).tag(surface)
                }
            }
            Divider()
            SettingsLink {
                Label("All settings…", systemImage: "gearshape")
            }
            .controlSize(.small)
        }
        .pickerStyle(.menu)
        .padding(12)
        .frame(width: 310)
    }
}
