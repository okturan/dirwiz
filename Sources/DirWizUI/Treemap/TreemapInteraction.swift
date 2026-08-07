import SwiftUI
import DirWizCore

extension TreemapRect {
    /// Anonymous density aggregates represent a group, so using their representative child's
    /// filename would assert a false spatial identity even when the rectangle is label-sized.
    var qualifiesForLeafLabel: Bool {
        width * height > TreemapRect.minimumLeafLabelArea && !isBackground && !isAggregate
    }

    /// Shared with `TreemapLabelBudget`, so the budget is derived from the same threshold
    /// that admits a leaf label rather than a second, drifting copy of it.
    static let minimumLeafLabelArea: Float = 60 * 20
}

/// SwiftUI view that wraps the Metal treemap with interaction overlays.
/// Provides breadcrumb navigation, hover tooltips, and context menus.
/// Show a confirmation alert before trashing large items; call action() immediately for small ones.
/// Used by both InteractiveTreemapView and TreeTableView context menus.
@MainActor
func confirmTrash(name: String, size: UInt64, then action: @escaping () -> Void) {
    if size > 100_000_000 {
        let alert = NSAlert()
        alert.messageText = "Move \"\(name)\" to Trash?"
        alert.informativeText = "This item is \(SizeFormatter.shared.format(size)). It will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { action() }
            }
        } else {
            // No key window - fall back to app-modal alert.
            if alert.runModal() == .alertFirstButtonReturn { action() }
        }
    } else {
        action()
    }
}

public struct InteractiveTreemapView: View {
    @Bindable var appState: AppState

    @State private var hoveredNodeIndex: UInt32?
    @State private var hoverPoint: CGPoint?
    @State private var labelRects: [TreemapRect] = []
    @State private var layoutRectByNode: [UInt32: TreemapRect] = [:]
    /// Drawn-rect count from the last layout, used to explain a card→cushion fallback.
    @State private var drawnRectCount: Int = 0
    /// Coalesces deferred label applies without writing `@State` from the Metal draw path.
    @State private var layoutPublishToken = LayoutPublishToken()
    @State private var isAppearancePopoverShown = false

    /// Bumped from Metal/`onLayoutUpdate` without touching SwiftUI state storage.
    private final class LayoutPublishToken {
        var generation: UInt64 = 0
    }

    private var selectedLayoutRect: CGRect? {
        guard let idx = appState.selectedNodeIndex else { return nil }
        guard let r = layoutRectByNode[idx] else { return nil }
        return CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                      width: CGFloat(r.width), height: CGFloat(r.height))
    }

    /// Whether navigation (zoom) is allowed - disabled during scanning.
    private var canNavigate: Bool {
        !appState.scanProgress.isScanning
    }

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            treemapContent
        }
        .onKeyPress(.escape) {
            guard canNavigate else { return .ignored }
            appState.navigateUp()
            return .handled
        }
        .onKeyPress(.return) {
            guard canNavigate, let sel = appState.selectedNodeIndex else { return .ignored }
            appState.setTreemapRoot(sel)
            return .handled
        }
        .onKeyPress(.space) {
            guard !appState.isWarmPatchCommitInProgress,
                  let sel = appState.selectedNodeIndex,
                  let tree = appState.fileTree else { return .ignored }
            let path = tree.path(at: sel)
            appState.quickLookCoordinator.toggleQuickLook(for: path)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("[")]) { press in
            guard press.modifiers.contains(.command), canNavigate else { return .ignored }
            appState.navigateBack()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("]")]) { press in
            guard press.modifiers.contains(.command), canNavigate else { return .ignored }
            appState.navigateForward()
            return .handled
        }
    }

    // MARK: - Breadcrumb Bar

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            // Navigation buttons.
            navButton(systemName: "chevron.left", enabled: canNavigate && appState.navigation.canNavigateBack, help: "Back (Cmd+[)") {
                appState.navigateBack()
            }
            navButton(systemName: "chevron.right", enabled: canNavigate && appState.navigation.canNavigateForward, help: "Forward (Cmd+])") {
                appState.navigateForward()
            }
            navButton(systemName: "arrow.up", enabled: canNavigate && appState.navigation.canNavigateUp, help: "Up (Esc)") {
                appState.navigateUp()
            }
            navButton(systemName: "house", enabled: canNavigate && appState.navigation.treemapRootIndex != 0, help: "Home") {
                appState.navigateHome()
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            // Scrollable breadcrumb path.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(appState.navigation.treemapPath.enumerated()), id: \.offset) { pathIndex, nodeIndex in
                        if pathIndex > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }

                        Button(action: {
                            guard canNavigate else { return }
                            appState.navigateTo(pathIndex: pathIndex)
                        }) {
                            Text(breadcrumbLabel(for: nodeIndex, at: pathIndex))
                                .font(.system(size: 12, weight: pathIndex == appState.navigation.treemapPath.count - 1 ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(pathIndex == appState.navigation.treemapPath.count - 1 ? .primary : .secondary)
                        .disabled(!canNavigate)
                    }
                }
            }

            Spacer(minLength: 4)

            styleToggle

            if appState.treemapRenderStyle == .cards {
                appearanceButton
            }

            // Show size of current root.
            if let tree = appState.fileTree,
               let rootNode = tree.node(at: appState.navigation.treemapRootIndex) {
                Text(SizeFormatter.shared.format(rootNode.displaySize))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// Card style is abandoned above `CardBudget.fallbackNodeThreshold`, where cards could
    /// only draw sub-pixel slivers. The renderer makes that call itself; this mirrors the
    /// same pure decision so the user is told which style they are actually looking at.
    private var styleFallbackNotice: String? {
        guard appState.treemapRenderStyle == .cards, drawnRectCount > 0 else { return nil }
        switch CardBudget.decide(nodeCount: drawnRectCount) {
        case .drawAll:
            return nil
        case .aggregate:
            return "Too dense for cards to stay legible - showing the largest \(CardBudget.maxDrawnNodes)."
        case .fallbackToCushion:
            return "Showing cushions: \(drawnRectCount.formatted()) rectangles is too dense for cards."
        }
    }

    /// Labels share the renderer's card-to-cushion safety decision. Do not infer this by
    /// parsing the human notice: that copy may change while the rendering contract does not.
    private var isFoldersStylePainted: Bool {
        guard appState.treemapRenderStyle == .cards else { return false }
        guard drawnRectCount > 0 else { return true }
        if case .fallbackToCushion = CardBudget.decide(nodeCount: drawnRectCount) {
            return false
        }
        return true
    }

    /// Cushion vs. card painting. Purely visual - it changes no geometry, so switching
    /// mid-exploration keeps the current zoom, selection and hit targets exactly as they were.
    /// Two icons with no words left people guessing what the control even was. Names are
    /// wider but self-explanatory, which a two-state view switch has room to be.
    private var styleToggle: some View {
        Picker("", selection: $appState.treemapRenderStyle) {
            Text("Cushions").tag(TreemapRenderStyle.cushion)
            Text("Folders").tag(TreemapRenderStyle.cards)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 152)
        .help("Cushions: one shaded tile per file. Folders: files grouped inside labelled folder boxes.")
    }

    /// Discovery affordance for the Folders appearance settings: they live in the
    /// Settings window, but users exploring the map should not need to find ⌘, first.
    /// The popover mutates the same persisted palette/surface, so the treemap repaints
    /// live behind it while options are tried.
    private var appearanceButton: some View {
        Button {
            isAppearancePopoverShown.toggle()
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help("Folders appearance: palette and surface")
        .accessibilityLabel("Folders appearance")
        .popover(isPresented: $isAppearancePopoverShown, arrowEdge: .bottom) {
            FoldersAppearancePopover(appState: appState)
        }
    }

    private func navButton(systemName: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .quaternary)
        .disabled(!enabled)
        .help(help)
    }

    private func breadcrumbLabel(for nodeIndex: UInt32, at pathIndex: Int) -> String {
        guard let tree = appState.fileTree, Int(nodeIndex) < tree.count else { return "..." }
        if pathIndex == 0 {
            let name = tree.name(at: nodeIndex)
            return name.isEmpty ? "/" : name
        }
        return tree.name(at: nodeIndex)
    }

    // MARK: - Treemap Content

    private var treemapContent: some View {
        GeometryReader { geo in
        ZStack(alignment: .topLeading) {
            CushionTreemapView(
                fileTree: appState.fileTree,
                treeRevision: appState.scanProgress.treeLayoutRevision,
                isScanning: appState.scanProgress.isScanning,
                rootIndex: appState.navigation.treemapRootIndex,
                selectedNodeIndex: appState.selectedNodeIndex,
                extensionPalette: appState.extensionPalette,
                recencyFactors: appState.recencyFactors,
                recencyGeneration: appState.recencyGeneration,
                isRecencyOverlayEnabled: appState.isRecencyOverlayEnabled,
                renderStyle: appState.treemapRenderStyle,
                foldersColorScheme: appState.foldersColorScheme,
                foldersSurfaceStyle: appState.foldersSurfaceStyle,
                temporalDiffKinds: appState.temporalDiff.temporalDiffKinds,
                temporalDiffStrengths: appState.temporalDiff.temporalDiffStrengths,
                isTemporalDiffEnabled: appState.temporalDiff.isTemporalDiffEnabled,
                temporalDiffGeneration: appState.temporalDiff.temporalDiffGeneration,
                onClick: { nodeIndex in
                    appState.selectedNodeIndex = nodeIndex
                },
                onDoubleClick: { nodeIndex in
                    guard canNavigate else { return }
                    guard let tree = appState.fileTree,
                          let node = tree.node(at: nodeIndex) else { return }
                    if node.isDirectory {
                        appState.setTreemapRoot(nodeIndex)
                    } else {
                        // Progressive zoom: find the nearest ancestor that is a
                        // direct child of the current treemap root - this zooms
                        // one level at a time instead of jumping to the immediate parent.
                        let target = progressiveZoomTarget(for: nodeIndex, tree: tree)
                        if let target = target {
                            appState.setTreemapRoot(target)
                        }
                    }
                },
                onBack: {
                    guard canNavigate else { return }
                    appState.navigateBack()
                },
                onForward: {
                    guard canNavigate else { return }
                    appState.navigateForward()
                },
                onHover: { nodeIndex, point in
                    hoveredNodeIndex = nodeIndex
                    hoverPoint = point
                },
                onLayoutUpdate: { rects in
                    // Never write SwiftUI `@State` re-entrantly from a Metal size-change /
                    // draw callback - that is how label overlays and the right-rail legend
                    // ghost when panes are dragged. Publish on the next main-queue turn,
                    // dropping anything overtaken by a newer layout.
                    let token = layoutPublishToken
                    token.generation &+= 1
                    let generation = token.generation
                    let viewport = geo.size
                    let style = appState.treemapRenderStyle
                    DispatchQueue.main.async {
                        guard generation == token.generation else { return }
                        // Parent directories were excluded here, so a folder owning a huge
                        // region was never named on the map - the hierarchy was real in the
                        // layout but invisible on screen. Directory rects are now labelled
                        // too, and in Folders style they get the header strip the geometry
                        // already reserves for them.
                        // Caps scale with the window. Fixed caps meant enlarging the window
                        // qualified MORE rects for labels while the budget stayed put, so the
                        // newly-roomy folders reserved their 18pt header strip and then never
                        // got text - a visibly empty bar. The label count a viewport can hold
                        // is inherently bounded by its own area, so deriving the cap from it
                        // stays cheap while never being the reason a roomy folder goes unnamed.
                        let labelBudget = TreemapLabelBudget.budgets(
                            viewportWidth: Float(viewport.width),
                            viewportHeight: Float(viewport.height)
                        )
                        let leaves = rects
                            .filter(\.qualifiesForLeafLabel)
                            .sorted { $0.width * $0.height > $1.width * $1.height }
                            .prefix(labelBudget.leaves)
                        // Folders style reserves a header strip per container for exactly this.
                        // Cushions stays a pure file view: a chip there would sit on top of a
                        // child tile, since cushion children fill their parent edge to edge.
                        // The filter MUST be the geometry's own header test, not an
                        // approximation of it: a container between 40 and 56pt tall reserves
                        // no strip, so a chip drawn there lands on top of its first child.
                        let containers = style == .cards
                            ? rects
                                .filter { $0.isBackground
                                    && CardGeometry.headerHeight(width: $0.width, height: $0.height) > 0 }
                                .sorted { $0.width * $0.height > $1.width * $1.height }
                                .prefix(labelBudget.containers)
                            : [].prefix(0)
                        // Leaves first, containers last: a ZStack draws later views on top,
                        // and the folder name is the one that must never be buried.
                        labelRects = Array(leaves) + Array(containers)
                        var byNode = [UInt32: TreemapRect](minimumCapacity: rects.count)
                        for r in rects { byNode[r.nodeIndex] = r }
                        layoutRectByNode = byNode
                        drawnRectCount = rects.count
                    }
                }
            )
            .contextMenu {
                contextMenuItems
            }

            // Text labels on large rectangles.
            // Cleared while geo.size is changing; republished when Metal settles.
            if !labelRects.isEmpty {
                textLabelOverlay
                    .allowsHitTesting(false)
                    .transaction { $0.animation = nil }
            }

            // Selection border overlay - visible even when the Metal highlight is too subtle.
            if selectedLayoutRect != nil {
                selectionBorderOverlay
                    .allowsHitTesting(false)
                    .transaction { $0.animation = nil }
            }

            // Say why the picked style isn't what's on screen, rather than degrading silently.
            if let notice = styleFallbackNotice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(8)
                    .allowsHitTesting(false)
            }

            // Hover tooltip overlay.
            if let nodeIndex = hoveredNodeIndex, let point = hoverPoint {
                tooltipView(for: nodeIndex)
                    .position(tooltipPosition(for: point, in: geo.size))
                    .allowsHitTesting(false)
                    .animation(.none, value: nodeIndex)
            }
        }
        // Labels sit in layout coordinates. While Metal stretch-previews a resize they
        // would drift; clear until the settled layout republishes display rects.
        .onChange(of: geo.size) { _, _ in
            labelRects = []
            layoutRectByNode = [:]
            hoveredNodeIndex = nil
            hoverPoint = nil
        }
        } // GeometryReader
    }

    // MARK: - Text Labels

    private var textLabelOverlay: some View {
        let tree = appState.fileTree
        return ZStack(alignment: .topLeading) {
            ForEach(labelRects, id: \.nodeIndex) { rect in
                treemapLabel(for: rect, tree: tree)
            }
        }
    }

    @ViewBuilder
    private func treemapLabel(for rect: TreemapRect, tree: FileTree?) -> some View {
        if rect.isBackground {
            containerLabel(for: rect, tree: tree)
        } else {
            leafLabel(for: rect, tree: tree)
        }
    }

    /// A folder owns the full usable width of its reserved title row. The name gets first
    /// claim on that width; size metadata appears only when it cannot squeeze the name.
    /// Color Headers supplies the row colour in Metal, while the other surfaces use one
    /// flat dark row instead of stacking an intrinsic rounded chip on the card.
    private func containerLabel(for rect: TreemapRect, tree: FileTree?) -> some View {
        let name = tree?.name(at: rect.nodeIndex) ?? ""
        let node = tree?.node(at: rect.nodeIndex)
        let showSize = node != nil && CardGeometry.shouldShowFolderSize(
            width: rect.width,
            nameCharacterCount: name.count
        )
        let directColorHeader = isFoldersStylePainted
            && appState.foldersSurfaceStyle == .colorHeaders
            && !appState.isRecencyOverlayEnabled
            && !appState.temporalDiff.isTemporalDiffEnabled
        let useDarkText = directColorHeader && CardGeometry.prefersDarkLabel(
            depth: Int(rect.depth),
            scheme: appState.foldersColorScheme
        )
        let foreground = useDarkText ? Color.black : Color.white
        let secondary = foreground.opacity(0.72)
        let shadow = useDarkText ? Color.white.opacity(0.7) : Color.black.opacity(0.72)
        let rowWidth = max(0, CGFloat(rect.width) - 4)

        return HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 8))
                .foregroundStyle(secondary)
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 3)
            if showSize, let node {
                Text(SizeFormatter.shared.format(node.displaySize))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(secondary)
                    .fixedSize()
            }
        }
        .foregroundStyle(foreground)
        .shadow(color: shadow, radius: directColorHeader ? 0.7 : 0, x: 0, y: 1)
        .padding(.horizontal, 4)
        .frame(width: rowWidth, height: 16, alignment: .leading)
        .background(
            Rectangle()
                .fill(directColorHeader ? Color.clear : Color.black.opacity(0.54))
        )
        .clipped()
        .offset(x: CGFloat(rect.x) + 2, y: CGFloat(rect.y) + 1)
    }

    private func leafLabel(for rect: TreemapRect, tree: FileTree?) -> some View {
        let name = tree?.name(at: rect.nodeIndex) ?? ""
        let node = tree?.node(at: rect.nodeIndex)
        let showSize = rect.height > 40 && node != nil
        let fontSize = min(11, max(8, CGFloat(rect.height) * 0.35))
        // The Folders shader leaves the card centre at its palette colour. Pick the
        // higher-contrast text polarity there; Cushion keeps its established white label.
        // When an overlay changes the colour after palette selection, white remains the
        // safer common foreground for the potentially darkened result.
        let canUsePaletteContrast = isFoldersStylePainted
            && !appState.isRecencyOverlayEnabled
            && !appState.temporalDiff.isTemporalDiffEnabled
        let useDarkText = canUsePaletteContrast && CardGeometry.prefersDarkLabel(
            depth: Int(rect.depth),
            scheme: appState.foldersColorScheme
        )
        let foreground = useDarkText ? Color.black : Color.white
        let shadow = useDarkText ? Color.white.opacity(0.75) : Color.black.opacity(0.8)

        return VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .font(.system(size: fontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if showSize, let node = node {
                Text(SizeFormatter.shared.format(node.displaySize))
                    .font(.system(size: max(8, fontSize - 2), design: .monospaced))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(foreground)
        .shadow(color: shadow, radius: 1, x: 0, y: 1)
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .frame(
            width: CGFloat(rect.width),
            height: CGFloat(rect.height),
            alignment: .topLeading
        )
        .clipped()
        .offset(x: CGFloat(rect.x), y: CGFloat(rect.y))
    }

    // MARK: - Selection Border

    @ViewBuilder
    private var selectionBorderOverlay: some View {
        if let rect = selectedLayoutRect, rect.width >= 2, rect.height >= 2 {
            Rectangle()
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    /// Find the directory child of the current treemap root that is an ancestor of nodeIndex.
    /// This provides "one level at a time" zooming.
    private func progressiveZoomTarget(for nodeIndex: UInt32, tree: FileTree) -> UInt32? {
        let nodes = tree.nodesSnapshot()
        let currentRoot = appState.navigation.treemapRootIndex

        guard Int(nodeIndex) < nodes.count else { return nil }

        // Walk up from the node's parent to find the child of currentRoot.
        var current = nodes[Int(nodeIndex)].parentIndex
        var child = nodeIndex
        while current != FileNode.invalid && current != currentRoot {
            child = current
            let i = Int(current)
            guard i < nodes.count else { return nil }
            current = nodes[i].parentIndex
        }

        // If we found the current root, the 'child' is the direct child to zoom into.
        if current == currentRoot {
            guard Int(child) < nodes.count else { return nil }
            if nodes[Int(child)].isDirectory { return child }
        }

        // Fallback: zoom into immediate parent.
        guard Int(nodeIndex) < nodes.count else { return nil }
        let parent = nodes[Int(nodeIndex)].parentIndex
        if parent != FileNode.invalid {
            guard Int(parent) < nodes.count else { return nil }
            if nodes[Int(parent)].isDirectory { return parent }
        }

        return nil
    }

    // MARK: - Tooltip

    @ViewBuilder
    private func tooltipView(for nodeIndex: UInt32) -> some View {
        if let tree = appState.fileTree,
           let node = tree.node(at: nodeIndex) {
            let name = tree.name(at: nodeIndex)
            let size = SizeFormatter.shared.format(node.displaySize)
            let category = ExtensionColorMap.shared.category(forHash: node.extensionHash)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if node.isDirectory {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(size)
                        .font(.system(size: 11, design: .monospaced))

                    if !canNavigate {
                        Text("Scanning...")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    } else if node.isDirectory {
                        Text("Double-click to zoom in")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(category.rawValue)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.ultraThickMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            )
        }
    }

    /// Position the tooltip near the cursor, flipping sides when near edges.
    /// Uses .position() which places the view's CENTER at the returned point.
    private func tooltipPosition(for point: CGPoint, in size: CGSize) -> CGPoint {
        // Rough tooltip dimensions for edge detection (actual size varies with content).
        let tw: CGFloat = 230
        let th: CGFloat = 60
        let margin: CGFloat = 8

        // Default: right of and above the cursor.
        var x = point.x + 16
        var y = point.y - 24

        // Flip to left side if right edge would overflow.
        if x + tw / 2 + margin > size.width {
            x = point.x - 16 - tw / 2
        }

        // Flip to below cursor if top edge would overflow.
        if y - th / 2 - margin < 0 {
            y = point.y + 16 + th / 2
        }

        // Hard clamp: keep tooltip center within drawable area.
        x = Swift.max(tw / 2 + margin, Swift.min(size.width  - tw / 2 - margin, x))
        y = Swift.max(th / 2 + margin, Swift.min(size.height - th / 2 - margin, y))

        return CGPoint(x: x, y: y)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        if let nodeIndex = hoveredNodeIndex ?? appState.selectedNodeIndex,
           let tree = appState.fileTree,
           let node = tree.node(at: nodeIndex) {
            let path = tree.path(at: nodeIndex)

            Button("Reveal in Finder") {
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }

            if node.isDirectory {
                Button("Search in This Folder") {
                    appState.scopeSearch(toPath: path, name: tree.name(at: nodeIndex))
                }
            }

            Button("Move to Trash") {
                let url = URL(fileURLWithPath: path)
                confirmTrash(name: tree.name(at: nodeIndex), size: node.fileSize) {
                    if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                        appState.rescanVolume()
                    }
                }
            }

            if canNavigate {
                Divider()

                if node.isDirectory {
                    Button("Zoom Into \"\(tree.name(at: nodeIndex))\"") {
                        appState.setTreemapRoot(nodeIndex)
                    }
                } else if node.parentIndex != FileNode.invalid {
                    Button("Zoom Into Parent Directory") {
                        if let target = progressiveZoomTarget(for: nodeIndex, tree: tree) {
                            appState.setTreemapRoot(target)
                        }
                    }
                }

                if appState.navigation.canNavigateUp {
                    Button("Navigate Up (Esc)") {
                        appState.navigateUp()
                    }
                }

                if appState.navigation.treemapRootIndex != 0 {
                    Button("Go to Root") {
                        appState.navigateHome()
                    }
                }

                if appState.navigation.canNavigateBack {
                    Button("Back (Cmd+[)") {
                        appState.navigateBack()
                    }
                }
            }

            Divider()

            Text("\(tree.name(at: nodeIndex)) - \(SizeFormatter.shared.format(node.fileSize))")
        }
    }
}
