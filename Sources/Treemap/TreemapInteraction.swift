import SwiftUI

/// SwiftUI view that wraps the Metal treemap with interaction overlays.
/// Provides breadcrumb navigation, hover tooltips, and context menus.
/// Show a confirmation alert before trashing large items; call action() immediately for small ones.
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
            // No key window — do not proceed without confirmation.
            return
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

    private var selectedLayoutRect: CGRect? {
        guard let idx = appState.selectedNodeIndex else { return nil }
        guard let r = layoutRectByNode[idx] else { return nil }
        return CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                      width: CGFloat(r.width), height: CGFloat(r.height))
    }

    /// Whether navigation (zoom) is allowed — disabled during scanning.
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
            guard let sel = appState.selectedNodeIndex,
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
            navButton(systemName: "chevron.left", enabled: canNavigate && appState.canNavigateBack, help: "Back (Cmd+[)") {
                appState.navigateBack()
            }
            navButton(systemName: "chevron.right", enabled: canNavigate && appState.canNavigateForward, help: "Forward (Cmd+])") {
                appState.navigateForward()
            }
            navButton(systemName: "arrow.up", enabled: canNavigate && appState.canNavigateUp, help: "Up (Esc)") {
                appState.navigateUp()
            }
            navButton(systemName: "house", enabled: canNavigate && appState.treemapRootIndex != 0, help: "Home") {
                appState.navigateHome()
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            // Scrollable breadcrumb path.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(appState.treemapPath.enumerated()), id: \.offset) { pathIndex, nodeIndex in
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
                                .font(.system(size: 12, weight: pathIndex == appState.treemapPath.count - 1 ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(pathIndex == appState.treemapPath.count - 1 ? .primary : .secondary)
                        .disabled(!canNavigate)
                    }
                }
            }

            Spacer(minLength: 4)

            // Show size of current root.
            if let tree = appState.fileTree,
               let rootNode = tree.node(at: appState.treemapRootIndex) {
                Text(SizeFormatter.shared.format(rootNode.fileSize))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
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
                rootIndex: appState.treemapRootIndex,
                selectedNodeIndex: appState.selectedNodeIndex,
                extensionPalette: appState.extensionPalette,
                recencyFactors: appState.recencyFactors,
                recencyGeneration: appState.recencyGeneration,
                isRecencyOverlayEnabled: appState.isRecencyOverlayEnabled,
                temporalDiffKinds: appState.temporalDiffKinds,
                temporalDiffStrengths: appState.temporalDiffStrengths,
                isTemporalDiffEnabled: appState.isTemporalDiffEnabled,
                temporalDiffGeneration: appState.temporalDiffGeneration,
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
                        // direct child of the current treemap root — this zooms
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
                    labelRects = Array(
                        rects
                            .filter { $0.width * $0.height > 60 * 20 && !$0.isBackground }
                            .sorted { $0.width * $0.height > $1.width * $1.height }
                            .prefix(80)
                    )
                    var byNode = [UInt32: TreemapRect](minimumCapacity: rects.count)
                    for r in rects { byNode[r.nodeIndex] = r }
                    layoutRectByNode = byNode
                }
            )
            .contextMenu {
                contextMenuItems
            }

            // Text labels on large rectangles.
            textLabelOverlay
                .allowsHitTesting(false)

            // Selection border overlay — visible even when the Metal highlight is too subtle.
            selectionBorderOverlay
                .allowsHitTesting(false)

            // Hover tooltip overlay.
            if let nodeIndex = hoveredNodeIndex, let point = hoverPoint {
                tooltipView(for: nodeIndex)
                    .position(tooltipPosition(for: point, in: geo.size))
                    .allowsHitTesting(false)
                    .animation(.none, value: nodeIndex)
            }
        }
        } // GeometryReader
    }

    // MARK: - Text Labels

    private var textLabelOverlay: some View {
        let tree = appState.fileTree
        return ZStack(alignment: .topLeading) {
            ForEach(Array(labelRects.enumerated()), id: \.offset) { _, rect in
                treemapLabel(for: rect, tree: tree)
            }
        }
    }

    private func treemapLabel(for rect: TreemapRect, tree: FileTree?) -> some View {
        let name = tree?.name(at: rect.nodeIndex) ?? ""
        let node = tree?.node(at: rect.nodeIndex)
        let showSize = rect.height > 40 && node != nil
        let fontSize = min(11, max(8, CGFloat(rect.height) * 0.35))

        return VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .font(.system(size: fontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if showSize, let node = node {
                Text(SizeFormatter.shared.format(node.fileSize))
                    .font(.system(size: max(8, fontSize - 2), design: .monospaced))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
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
        let currentRoot = appState.treemapRootIndex

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
            let size = SizeFormatter.shared.format(node.fileSize)
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

                if appState.canNavigateUp {
                    Button("Navigate Up (Esc)") {
                        appState.navigateUp()
                    }
                }

                if appState.treemapRootIndex != 0 {
                    Button("Go to Root") {
                        appState.navigateHome()
                    }
                }

                if appState.canNavigateBack {
                    Button("Back (Cmd+[)") {
                        appState.navigateBack()
                    }
                }
            }

            Divider()

            Text("\(tree.name(at: nodeIndex)) — \(SizeFormatter.shared.format(node.fileSize))")
        }
    }
}
