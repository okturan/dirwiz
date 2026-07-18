import MetalKit
import DirWizCore
import SwiftUI

// MARK: - NSViewRepresentable

/// SwiftUI wrapper that embeds an MTKView for Metal-based cushion treemap rendering.
public struct CushionTreemapView: NSViewRepresentable {
    public var fileTree: FileTree?
    public var treeRevision: Int
    public var isScanning: Bool
    public var rootIndex: UInt32
    public var selectedNodeIndex: UInt32?
    public var extensionPalette: ExtensionPalette
    public var recencyFactors: [Float]
    public var recencyGeneration: UInt64
    public var isRecencyOverlayEnabled: Bool
    public var temporalDiffKinds: [UInt8]
    public var temporalDiffStrengths: [Float]
    public var isTemporalDiffEnabled: Bool
    public var temporalDiffGeneration: UInt64
    public var onClick: ((UInt32) -> Void)?
    public var onDoubleClick: ((UInt32) -> Void)?
    public var onBack: (() -> Void)?
    public var onForward: (() -> Void)?
    public var onHover: ((UInt32?, NSPoint?) -> Void)?
    public var onLayoutUpdate: (([TreemapRect]) -> Void)?

    public init(
        fileTree: FileTree?,
        treeRevision: Int = 0,
        isScanning: Bool = false,
        rootIndex: UInt32,
        selectedNodeIndex: UInt32? = nil,
        extensionPalette: ExtensionPalette = ExtensionPalette(),
        recencyFactors: [Float] = [],
        recencyGeneration: UInt64 = 0,
        isRecencyOverlayEnabled: Bool = false,
        temporalDiffKinds: [UInt8] = [],
        temporalDiffStrengths: [Float] = [],
        isTemporalDiffEnabled: Bool = false,
        temporalDiffGeneration: UInt64 = 0,
        onClick: ((UInt32) -> Void)? = nil,
        onDoubleClick: ((UInt32) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onForward: (() -> Void)? = nil,
        onHover: ((UInt32?, NSPoint?) -> Void)? = nil,
        onLayoutUpdate: (([TreemapRect]) -> Void)? = nil
    ) {
        self.fileTree = fileTree
        self.treeRevision = treeRevision
        self.isScanning = isScanning
        self.rootIndex = rootIndex
        self.selectedNodeIndex = selectedNodeIndex
        self.extensionPalette = extensionPalette
        self.recencyFactors = recencyFactors
        self.recencyGeneration = recencyGeneration
        self.isRecencyOverlayEnabled = isRecencyOverlayEnabled
        self.temporalDiffKinds = temporalDiffKinds
        self.temporalDiffStrengths = temporalDiffStrengths
        self.isTemporalDiffEnabled = isTemporalDiffEnabled
        self.temporalDiffGeneration = temporalDiffGeneration
        self.onClick = onClick
        self.onDoubleClick = onDoubleClick
        self.onBack = onBack
        self.onForward = onForward
        self.onHover = onHover
        self.onLayoutUpdate = onLayoutUpdate
    }

    public func makeNSView(context: Context) -> MTKView {
        let mtkView = TreemapMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        if let coordinator = CushionTreemapCoordinator(mtkView: mtkView) {
            coordinator.mtkView = mtkView
            context.coordinator.metalCoordinator = coordinator
            mtkView.delegate = coordinator
            mtkView.interactionDelegate = context.coordinator
        }

        return mtkView
    }

    public func updateNSView(_ mtkView: MTKView, context: Context) {
        guard let coordinator = context.coordinator.metalCoordinator else { return }

        let treeChanged = coordinator.currentFileTree !== fileTree
        let revisionChanged = coordinator.currentTreeRevision != treeRevision
        let rootChanged = coordinator.currentRootIndex != rootIndex
        let selectionChanged = coordinator.selectedNodeIndex != selectedNodeIndex
        let paletteChanged = coordinator.extensionPalette.generation != extensionPalette.generation
        let recencyChanged = coordinator.recencyGeneration != recencyGeneration ||
                             coordinator.isRecencyOverlayEnabled != isRecencyOverlayEnabled
        let temporalChanged = coordinator.temporalDiffGeneration != temporalDiffGeneration ||
                              coordinator.isTemporalDiffEnabled != isTemporalDiffEnabled

        coordinator.currentFileTree = fileTree
        coordinator.currentTreeRevision = treeRevision
        coordinator.isScanning = isScanning
        coordinator.currentRootIndex = rootIndex
        coordinator.selectedNodeIndex = selectedNodeIndex
        if paletteChanged {
            coordinator.extensionPalette = extensionPalette
            coordinator.instanceBufferDirty = true
        }
        if recencyChanged {
            coordinator.recencyFactors = recencyFactors
            coordinator.recencyGeneration = recencyGeneration
            coordinator.isRecencyOverlayEnabled = isRecencyOverlayEnabled
            coordinator.instanceBufferDirty = true
        }
        if temporalChanged {
            coordinator.temporalDiffKinds = temporalDiffKinds
            coordinator.temporalDiffStrengths = temporalDiffStrengths
            coordinator.isTemporalDiffEnabled = isTemporalDiffEnabled
            coordinator.temporalDiffGeneration = temporalDiffGeneration
            coordinator.instanceBufferDirty = true
        }
        coordinator.onClick = onClick
        coordinator.onDoubleClick = onDoubleClick
        coordinator.onBack = onBack
        coordinator.onForward = onForward
        coordinator.onHover = onHover
        coordinator.onLayoutUpdate = onLayoutUpdate

        if treeChanged || rootChanged {
            coordinator.invalidateLayout()
        } else if revisionChanged {
            // Plan 044: while a scan is in progress, a periodic revision bump can be
            // adaptively skipped (previous scan-time layout was expensive and the tree
            // has barely grown since). Never skipped once scanning ends, so the
            // completion layout (the forced revision bump) always runs.
            if !coordinator.shouldSkipScanTimeRelayout() {
                coordinator.invalidateLayout()
            }
        }

        if treeChanged || rootChanged || revisionChanged || selectionChanged || paletteChanged || recencyChanged || temporalChanged {
            mtkView.needsDisplay = true
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    public final class Coordinator: NSObject {
        var metalCoordinator: CushionTreemapCoordinator?
    }
}

// MARK: - Interaction Protocol

/// Protocol for forwarding mouse events from the MTKView to the coordinator.
@MainActor
protocol TreemapInteractionDelegate: AnyObject {
    func treemapMouseDown(at point: NSPoint, clickCount: Int)
    func treemapMouseMoved(at point: NSPoint)
    func treemapMouseExited()
    func treemapRightMouseDown(at point: NSPoint)
    func treemapOtherMouseDown(buttonNumber: Int)
}

extension CushionTreemapView.Coordinator: TreemapInteractionDelegate {
    func treemapMouseDown(at point: NSPoint, clickCount: Int) {
        guard let coordinator = metalCoordinator,
              let nodeIndex = coordinator.hitTest(point: point) else {
            return
        }

        if clickCount >= 2 {
            coordinator.onDoubleClick?(nodeIndex)
        } else {
            coordinator.onClick?(nodeIndex)
        }
    }

    func treemapMouseMoved(at point: NSPoint) {
        guard let coordinator = metalCoordinator else { return }
        let nodeIndex = coordinator.hitTest(point: point)
        let hoverChanged = coordinator.hoveredNodeIndex != nodeIndex
        coordinator.hoveredNodeIndex = nodeIndex
        coordinator.onHover?(nodeIndex, nodeIndex != nil ? point : nil)
        if hoverChanged {
            coordinator.mtkView?.needsDisplay = true
        }
    }

    func treemapMouseExited() {
        let hoverChanged = metalCoordinator?.hoveredNodeIndex != nil
        metalCoordinator?.hoveredNodeIndex = nil
        metalCoordinator?.onHover?(nil, nil)
        if hoverChanged {
            metalCoordinator?.mtkView?.needsDisplay = true
        }
    }

    func treemapRightMouseDown(at point: NSPoint) {
        // Right-click is handled at the SwiftUI level via context menu.
        // Forward as a regular click to select the node.
        guard let coordinator = metalCoordinator,
              let nodeIndex = coordinator.hitTest(point: point) else {
            return
        }
        coordinator.onClick?(nodeIndex)
    }

    func treemapOtherMouseDown(buttonNumber: Int) {
        guard let coordinator = metalCoordinator else { return }
        if buttonNumber == 3 {
            coordinator.onBack?()
        } else if buttonNumber == 4 {
            coordinator.onForward?()
        }
    }
}

// MARK: - Custom MTKView Subclass for Mouse Events

/// MTKView subclass that captures mouse events and forwards them to the interaction delegate.
final class TreemapMTKView: MTKView {
    weak var interactionDelegate: TreemapInteractionDelegate?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove existing tracking areas.
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        // Add a tracking area covering the entire view.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    /// Convert event location to the view's logical coordinate system (top-left origin).
    private func logicalPoint(for event: NSEvent) -> NSPoint {
        let locationInView = convert(event.locationInWindow, from: nil)
        // Flip Y: NSView uses bottom-left origin, but our treemap uses top-left.
        return NSPoint(x: locationInView.x, y: bounds.height - locationInView.y)
    }

    override func mouseDown(with event: NSEvent) {
        let point = logicalPoint(for: event)
        interactionDelegate?.treemapMouseDown(at: point, clickCount: event.clickCount)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = logicalPoint(for: event)
        interactionDelegate?.treemapMouseMoved(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        interactionDelegate?.treemapMouseExited()
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = logicalPoint(for: event)
        interactionDelegate?.treemapRightMouseDown(at: point)
        super.rightMouseDown(with: event) // Allow context menu to appear.
    }

    override func otherMouseDown(with event: NSEvent) {
        // Mouse buttons 3 (back) and 4 (forward).
        interactionDelegate?.treemapOtherMouseDown(buttonNumber: event.buttonNumber)
    }
}
