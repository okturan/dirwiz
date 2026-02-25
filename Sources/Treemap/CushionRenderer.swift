import Foundation
import MetalKit
import SwiftUI

// MARK: - GPU Data Structures

/// Per-instance data matching the Metal shader struct layout.
struct CushionInstance {
    var rect: SIMD4<Float>   // x, y, width, height in pixels
    var coefs: SIMD4<Float>  // parabolic cushion coefficients [ax2, bx, ay2, by]
    var color: SIMD4<Float>  // base RGBA
}

/// Uniform buffer matching the Metal shader struct layout.
struct CushionUniforms {
    var viewportSize: SIMD2<Float>
    var ambient: Float
    var padding1: Float
    var lightDir: SIMD3<Float>
    var hoveredIndex: Int32
}

// MARK: - Cushion Coefficient Calculation

/// Cushion shading constants.
private enum CushionConstants {
    static let H: Float = 0.40   // initial ridge height
    static let F: Float = 0.90   // depth falloff factor
}

/// Accumulate parabolic ridge cushion coefficients from ancestor rectangles.
/// Each nesting level adds a parabolic ridge in both x and y directions.
private func computeCushionCoefficients(for rect: TreemapRect) -> SIMD4<Float> {
    var coefs = SIMD4<Float>(0, 0, 0, 0)

    // Process each ancestor level.
    for (level, ancestor) in rect.ancestors.enumerated() {
        let h = CushionConstants.H * powf(CushionConstants.F, Float(level))
        addRidge(&coefs, rect: rect, ancestorX: ancestor.x, ancestorY: ancestor.y,
                 ancestorW: ancestor.w, ancestorH: ancestor.h, h: h)
    }

    return coefs
}

/// Add a parabolic ridge for one nesting level.
/// The ridge creates a bump across the ancestor rectangle, normalized to the leaf's [0..1] space.
private func addRidge(_ coefs: inout SIMD4<Float>, rect: TreemapRect,
                      ancestorX: Float, ancestorY: Float,
                      ancestorW: Float, ancestorH: Float, h: Float) {
    guard rect.width > 0, rect.height > 0 else { return }

    // Map ancestor bounds into the leaf rect's [0..1] parametric space.
    let x1 = (ancestorX - rect.x) / rect.width
    let x2 = (ancestorX + ancestorW - rect.x) / rect.width
    let y1 = (ancestorY - rect.y) / rect.height
    let y2 = (ancestorY + ancestorH - rect.y) / rect.height

    let dx = x2 - x1
    let dy = y2 - y1

    guard dx > 0, dy > 0 else { return }

    // Horizontal ridge: parabola in x direction.
    let invDx2 = 1.0 / (dx * dx)
    coefs.x += -4.0 * h * invDx2
    coefs.y += 4.0 * h * (x1 + x2) * invDx2

    // Vertical ridge: parabola in y direction.
    let invDy2 = 1.0 / (dy * dy)
    coefs.z += -4.0 * h * invDy2
    coefs.w += 4.0 * h * (y1 + y2) * invDy2
}

// MARK: - Spatial Grid for Hit Testing

/// A flat 2D grid that maps viewport regions to overlapping TreemapRect indices.
/// Enables O(1) cell lookup + small linear scan instead of O(n) over all rects.
private struct SpatialGrid {
    private let cols: Int
    private let rows: Int
    private let cellWidth: Float
    private let cellHeight: Float
    /// Flat array of rect indices per cell. cells[row * cols + col] = [indices].
    private var cells: [[Int]]

    init(viewportWidth: Float, viewportHeight: Float, rects: [TreemapRect], gridSize: Int = 64) {
        guard viewportWidth > 0, viewportHeight > 0, !rects.isEmpty else {
            self.cols = 0
            self.rows = 0
            self.cellWidth = 1
            self.cellHeight = 1
            self.cells = []
            return
        }

        self.cols = gridSize
        self.rows = gridSize
        self.cellWidth = viewportWidth / Float(gridSize)
        self.cellHeight = viewportHeight / Float(gridSize)
        self.cells = Array(repeating: [], count: gridSize * gridSize)

        for i in 0..<rects.count {
            let r = rects[i]
            guard r.width > 0, r.height > 0 else { continue }
            // Compute cell range this rect overlaps.
            let minCol = max(0, Int(r.x / cellWidth))
            let maxCol = min(gridSize - 1, Int((r.x + r.width - Float.ulpOfOne) / cellWidth))
            let minRow = max(0, Int(r.y / cellHeight))
            let maxRow = min(gridSize - 1, Int((r.y + r.height - Float.ulpOfOne) / cellHeight))

            guard minCol <= maxCol, minRow <= maxRow else { continue }

            for row in minRow...maxRow {
                let rowOffset = row * gridSize
                for col in minCol...maxCol {
                    self.cells[rowOffset + col].append(i)
                }
            }
        }
    }

    /// Find the deepest (last in layout order) rect containing the given point.
    func hitTest(point: (x: Float, y: Float), rects: [TreemapRect]) -> UInt32? {
        guard cols > 0, rows > 0 else { return nil }

        let col = Int(point.x / cellWidth)
        let row = Int(point.y / cellHeight)
        guard col >= 0, col < cols, row >= 0, row < rows else { return nil }

        let indices = cells[row * cols + col]
        // Search in reverse so deeper/smaller rects (laid out later) are found first.
        for i in stride(from: indices.count - 1, through: 0, by: -1) {
            let idx = indices[i]
            let r = rects[idx]
            if point.x >= r.x && point.x < r.x + r.width &&
               point.y >= r.y && point.y < r.y + r.height {
                return r.nodeIndex
            }
        }
        return nil
    }
}

// MARK: - MTKView Coordinator

/// Metal coordinator that renders the cushion treemap using instanced drawing.
final class CushionTreemapCoordinator: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var instanceBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    weak var mtkView: MTKView?

    private var instanceCount: Int = 0
    private var instanceBufferCapacity: Int = 0

    /// Cached layout from the most recent computation.
    var cachedLayout: [TreemapRect] = []

    /// Cached node snapshot used for the current layout + instance buffer.
    private var cachedSnapshot: [FileNode] = []

    /// Spatial grid rebuilt after each layout for fast hit testing.
    private var spatialGrid: SpatialGrid?

    /// Current data inputs, tracked for change detection.
    var currentFileTree: FileTree?
    var currentRootIndex: UInt32 = 0
    var currentTreeRevision: Int = 0
    var currentViewportSize: CGSize = .zero
    var selectedNodeIndex: UInt32?
    var hoveredNodeIndex: UInt32?

    /// Layout throttling — minimum interval between layout recomputes.
    private var lastLayoutTime: CFAbsoluteTime = 0
    private var needsForceLayout: Bool = false

    /// Instance buffer dirty tracking — skip rebuild when nothing changed.
    private var instanceBufferDirty: Bool = true
    private var lastSelectedNodeIndex: UInt32? = nil
    private var lastHoveredNodeIndex: UInt32? = nil

    /// Callbacks for interaction.
    var onClick: ((UInt32) -> Void)?
    var onDoubleClick: ((UInt32) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onHover: ((UInt32?, NSPoint?) -> Void)?
    var onLayoutUpdate: (([TreemapRect]) -> Void)?

    init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self.device = device
        mtkView.device = device
        super.init()

        self.commandQueue = device.makeCommandQueue()
        setupPipeline(mtkView: mtkView)
    }

    // MARK: - Pipeline Setup

    private func setupPipeline(mtkView: MTKView) {
        // Compile shaders from embedded source at runtime.
        // SPM doesn't compile .metal files into .metallib, so we embed the source.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: CushionShaderSource.source, options: nil)
        } catch {
            print("CushionRenderer: Failed to compile Metal shaders: \(error)")
            return
        }

        guard let vertexFunc = library.makeFunction(name: "cushionVertexShader"),
              let fragFunc = library.makeFunction(name: "cushionFragmentShader") else {
            print("CushionRenderer: Failed to find shader functions.")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragFunc
        descriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        // Enable alpha blending.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("CushionRenderer: Failed to create pipeline state: \(error)")
        }
    }

    // MARK: - Layout Computation

    /// Recompute layout if inputs have changed. Uses a node snapshot to avoid lock contention.
    func recomputeLayoutIfNeeded(viewportSize: CGSize) {
        guard let tree = currentFileTree, !tree.isEmpty else {
            cachedLayout = []
            cachedSnapshot = []
            spatialGrid = nil
            return
        }

        let sizeChanged = viewportSize != currentViewportSize
        if !sizeChanged && !cachedLayout.isEmpty && !needsForceLayout {
            return // No change needed.
        }

        // Throttle layout recomputes to avoid blocking the main thread during scanning.
        // Allow immediate layout for: first display, forced navigation, or after enough time.
        if !cachedLayout.isEmpty && !needsForceLayout {
            let now = CFAbsoluteTimeGetCurrent()
            if (now - lastLayoutTime) < 1.0 {
                return // Too soon since last layout.
            }
        }

        needsForceLayout = false
        lastLayoutTime = CFAbsoluteTimeGetCurrent()
        currentViewportSize = viewportSize

        // Snapshot nodes ONCE — single lock acquisition, then layout runs lock-free.
        let snapshot = tree.nodesSnapshot()
        cachedSnapshot = snapshot

        let bounds = CGRect(origin: .zero, size: viewportSize)
        cachedLayout = SquarifyLayout.layout(
            nodes: snapshot,
            rootIndex: currentRootIndex,
            bounds: bounds,
            maxDepth: 20,
            minPixelSize: 1.0
        )

        // Cache cushion coefficients for each rect (avoids recomputing every instance buffer rebuild).
        for i in 0..<cachedLayout.count {
            cachedLayout[i].cachedCoefs = computeCushionCoefficients(for: cachedLayout[i])
        }

        // Build spatial grid for O(1) hit testing.
        spatialGrid = SpatialGrid(
            viewportWidth: Float(viewportSize.width),
            viewportHeight: Float(viewportSize.height),
            rects: cachedLayout
        )

        instanceBufferDirty = true
        onLayoutUpdate?(cachedLayout)
    }

    /// Force a layout recompute immediately (e.g., user navigation).
    func forceLayoutInvalidation() {
        currentViewportSize = .zero
        needsForceLayout = true
    }

    /// Soft layout invalidation (e.g., scan revision change). Subject to throttling.
    func invalidateLayout() {
        currentViewportSize = .zero // Force recompute on next draw, subject to throttle.
    }

    // MARK: - Instance Buffer

    private func updateInstanceBuffer() {
        guard !cachedLayout.isEmpty, !cachedSnapshot.isEmpty else {
            instanceCount = 0
            return
        }

        // Skip rebuild if nothing changed.
        let selectionChanged = selectedNodeIndex != lastSelectedNodeIndex
        let hoverChanged = hoveredNodeIndex != lastHoveredNodeIndex
        if !instanceBufferDirty && !selectionChanged && !hoverChanged {
            return
        }
        instanceBufferDirty = false
        lastSelectedNodeIndex = selectedNodeIndex
        lastHoveredNodeIndex = hoveredNodeIndex

        let colorMap = ExtensionColorMap.shared
        let nodes = cachedSnapshot
        let layoutCount = cachedLayout.count

        // First pass: count visible instances (sub-pixel culling).
        var visibleCount = 0
        for i in 0..<layoutCount {
            let r = cachedLayout[i]
            if r.width >= 0.5 && r.height >= 0.5 {
                visibleCount += 1
            }
        }

        // Resize buffer if needed.
        let requiredSize = visibleCount * MemoryLayout<CushionInstance>.stride
        if instanceBuffer == nil || requiredSize > instanceBufferCapacity {
            let newCapacity = max(requiredSize, instanceBufferCapacity * 2)
            instanceBuffer = device.makeBuffer(length: newCapacity, options: .storageModeShared)
            instanceBufferCapacity = newCapacity
        }

        guard let buffer = instanceBuffer else { return }
        let ptr = buffer.contents().bindMemory(to: CushionInstance.self, capacity: visibleCount)

        var writeIdx = 0
        for i in 0..<layoutCount {
            let tmRect = cachedLayout[i]

            // Sub-pixel culling: skip rects smaller than half a pixel in either dimension.
            guard tmRect.width >= 0.5, tmRect.height >= 0.5 else { continue }

            let nodeIdx = Int(tmRect.nodeIndex)
            guard nodeIdx < nodes.count else { continue }
            let node = nodes[nodeIdx]

            // Get base color from extension hash.
            var baseColor: SIMD4<Float>
            if node.isDirectory {
                let dirRGB = directoryBaseColor(depth: tmRect.depth)
                let dirColor = SIMD4<Float>(dirRGB.x, dirRGB.y, dirRGB.z, 1.0)
                if let dominantHash = dominantDirectFileExtensionHash(in: tmRect.nodeIndex, nodes: nodes) {
                    let childColor = colorMap.color(forHash: dominantHash)
                    baseColor = blend(dirColor, childColor, factor: 0.65)
                } else {
                    baseColor = dirColor
                }
            } else {
                baseColor = colorMap.color(forHash: node.extensionHash)
            }

            // Highlight selected node.
            if tmRect.nodeIndex == selectedNodeIndex {
                baseColor = SIMD4<Float>(
                    min(baseColor.x + 0.25, 1.0),
                    min(baseColor.y + 0.25, 1.0),
                    min(baseColor.z + 0.25, 1.0),
                    1.0
                )
            }

            // Use cached coefficients instead of recomputing.
            let coefs = tmRect.cachedCoefs

            ptr[writeIdx] = CushionInstance(
                rect: SIMD4<Float>(tmRect.x, tmRect.y, tmRect.width, tmRect.height),
                coefs: coefs,
                color: baseColor
            )
            writeIdx += 1
        }
        instanceCount = writeIdx
    }

    /// Depth-based directory base color using subtle hue shifts.
    private func directoryBaseColor(depth: Int) -> SIMD3<Float> {
        let h: Float  // hue in degrees
        let s: Float  // saturation
        let b: Float  // brightness
        if depth <= 1 {
            h = 210; s = 0.12; b = 0.55  // blue-gray
        } else if depth <= 3 {
            h = 180; s = 0.12; b = 0.50  // teal
        } else {
            h = 260; s = 0.10; b = 0.50  // purple-gray
        }
        return hsbToRGB(h: h, s: s, b: b)
    }

    /// Convert HSB (hue 0-360, saturation 0-1, brightness 0-1) to RGB.
    private func hsbToRGB(h: Float, s: Float, b: Float) -> SIMD3<Float> {
        let c = b * s
        let x = c * (1 - abs(fmodf(h / 60, 2) - 1))
        let m = b - c
        let r1, g1, b1: Float
        switch h {
        case ..<60:    r1 = c; g1 = x; b1 = 0
        case ..<120:   r1 = x; g1 = c; b1 = 0
        case ..<180:   r1 = 0; g1 = c; b1 = x
        case ..<240:   r1 = 0; g1 = x; b1 = c
        case ..<300:   r1 = x; g1 = 0; b1 = c
        default:       r1 = c; g1 = 0; b1 = x
        }
        return SIMD3<Float>(r1 + m, g1 + m, b1 + m)
    }

    /// Dominant extension among direct file children (by bytes). Uses snapshot array directly.
    private func dominantDirectFileExtensionHash(in directoryIndex: UInt32, nodes: [FileNode]) -> UInt16? {
        let i = Int(directoryIndex)
        guard i < nodes.count else { return nil }
        let node = nodes[i]
        guard node.firstChildIndex != FileNode.invalid else { return nil }
        let start = Int(node.firstChildIndex)
        let end = min(start + Int(node.childCount), nodes.count)
        guard start < end else { return nil }

        var sizeByExt: [UInt16: UInt64] = [:]
        for childIndex in start..<end {
            let child = nodes[childIndex]
            guard !child.isDirectory else { continue }
            sizeByExt[child.extensionHash, default: 0] += child.fileSize
        }

        return sizeByExt.max(by: { $0.value < $1.value })?.key
    }

    private func blend(_ a: SIMD4<Float>, _ b: SIMD4<Float>, factor t: Float) -> SIMD4<Float> {
        let clamped = max(0, min(1, t))
        return a + (b - a) * clamped
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Will recompute layout on next draw.
    }

    func draw(in view: MTKView) {
        guard let pipelineState = pipelineState,
              let commandQueue = commandQueue,
              let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor else {
            return
        }

        let viewportSize = view.drawableSize
        let backingScaleFactor = view.window?.backingScaleFactor ?? 2.0
        let logicalSize = CGSize(
            width: viewportSize.width / backingScaleFactor,
            height: viewportSize.height / backingScaleFactor
        )

        recomputeLayoutIfNeeded(viewportSize: logicalSize)
        updateInstanceBuffer()

        guard instanceCount > 0, let instanceBuffer = instanceBuffer else {
            // Draw a clear frame.
            let commandBuffer = commandQueue.makeCommandBuffer()!
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)!
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // Set up uniforms.
        // Map hoveredNodeIndex to a visible instance index for the shader.
        // With culling, instance indices differ from layout indices, so we walk
        // the layout and count only visible rects to find the match.
        var hoveredInstance: Int32 = -1
        if let hovered = hoveredNodeIndex {
            var visibleIdx: Int32 = 0
            for i in 0..<cachedLayout.count {
                let r = cachedLayout[i]
                guard r.width >= 0.5, r.height >= 0.5 else { continue }
                if r.nodeIndex == hovered {
                    hoveredInstance = visibleIdx
                    break
                }
                visibleIdx += 1
            }
        }

        var uniforms = CushionUniforms(
            viewportSize: SIMD2<Float>(Float(logicalSize.width), Float(logicalSize.height)),
            ambient: 0.25,
            padding1: 0,
            lightDir: normalize(SIMD3<Float>(0.5, 0.5, 1.0)),
            hoveredIndex: hoveredInstance
        )

        if uniformBuffer == nil {
            uniformBuffer = device.makeBuffer(
                length: MemoryLayout<CushionUniforms>.stride,
                options: .storageModeShared
            )
        }
        uniformBuffer!.contents().copyMemory(
            from: &uniforms,
            byteCount: MemoryLayout<CushionUniforms>.stride
        )

        // Render.
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)!

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)

        // Draw triangle strip quads, instanced.
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Hit Testing

    /// Find which TreemapRect contains the given point (in logical coordinates).
    /// Uses the spatial grid for O(1) cell lookup instead of O(n) linear scan.
    /// Returns the node index, or nil if no rect contains the point.
    func hitTest(point: NSPoint) -> UInt32? {
        let px = Float(point.x)
        let py = Float(point.y)

        // Use spatial grid if available for fast lookup.
        if let grid = spatialGrid {
            return grid.hitTest(point: (x: px, y: py), rects: cachedLayout)
        }

        // Fallback: linear scan in reverse order (deeper rects first).
        for i in stride(from: cachedLayout.count - 1, through: 0, by: -1) {
            let r = cachedLayout[i]
            if px >= r.x && px < r.x + r.width &&
               py >= r.y && py < r.y + r.height {
                return r.nodeIndex
            }
        }
        return nil
    }
}

// MARK: - NSViewRepresentable

/// SwiftUI wrapper that embeds an MTKView for Metal-based cushion treemap rendering.
public struct CushionTreemapView: NSViewRepresentable {
    public var fileTree: FileTree?
    public var treeRevision: Int
    public var rootIndex: UInt32
    public var selectedNodeIndex: UInt32?
    public var onClick: ((UInt32) -> Void)?
    public var onDoubleClick: ((UInt32) -> Void)?
    public var onBack: (() -> Void)?
    public var onForward: (() -> Void)?
    public var onHover: ((UInt32?, NSPoint?) -> Void)?
    public var onLayoutUpdate: (([TreemapRect]) -> Void)?

    public init(
        fileTree: FileTree?,
        treeRevision: Int = 0,
        rootIndex: UInt32,
        selectedNodeIndex: UInt32? = nil,
        onClick: ((UInt32) -> Void)? = nil,
        onDoubleClick: ((UInt32) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onForward: (() -> Void)? = nil,
        onHover: ((UInt32?, NSPoint?) -> Void)? = nil,
        onLayoutUpdate: (([TreemapRect]) -> Void)? = nil
    ) {
        self.fileTree = fileTree
        self.treeRevision = treeRevision
        self.rootIndex = rootIndex
        self.selectedNodeIndex = selectedNodeIndex
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
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = true
        mtkView.preferredFramesPerSecond = 30

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

        coordinator.currentFileTree = fileTree
        coordinator.currentTreeRevision = treeRevision
        coordinator.currentRootIndex = rootIndex
        coordinator.selectedNodeIndex = selectedNodeIndex
        coordinator.onClick = onClick
        coordinator.onDoubleClick = onDoubleClick
        coordinator.onBack = onBack
        coordinator.onForward = onForward
        coordinator.onHover = onHover
        coordinator.onLayoutUpdate = onLayoutUpdate

        // User navigation gets immediate layout; scan updates are throttled.
        if treeChanged || rootChanged {
            coordinator.forceLayoutInvalidation()
        } else if revisionChanged {
            coordinator.invalidateLayout()
        }

        if treeChanged || rootChanged || revisionChanged || selectionChanged {
            mtkView.needsDisplay = true
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public final class Coordinator: NSObject {
        var metalCoordinator: CushionTreemapCoordinator?
    }
}

// MARK: - Interaction Protocol

/// Protocol for forwarding mouse events from the MTKView to the coordinator.
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

// MARK: - Embedded Metal Shader Source

/// Metal shader source compiled at runtime via device.makeLibrary(source:).
/// This avoids the SPM limitation where .metal files aren't compiled into .metallib.
enum CushionShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CushionInstance {
        float4 rect;
        float4 coefs;
        float4 color;
    };

    struct CushionUniforms {
        float2 viewportSize;
        float  ambient;
        float  padding1;
        float3 lightDir;
        int    hoveredIndex;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 rectPos;
        float4 coefs;
        float4 baseColor;
        float2 rectSize;
        int    instanceID;
    };

    // sRGB -> linear
    inline float3 srgbToLinear(float3 c) {
        return pow(c, float3(2.2));
    }

    // linear -> sRGB
    inline float3 linearToSrgb(float3 c) {
        return pow(c, float3(1.0 / 2.2));
    }

    vertex VertexOut cushionVertexShader(
        uint vertexID       [[vertex_id]],
        uint instanceID     [[instance_id]],
        const device CushionInstance* instances [[buffer(0)]],
        constant CushionUniforms& uniforms     [[buffer(1)]]
    ) {
        CushionInstance inst = instances[instanceID];
        float2 corner;
        corner.x = (vertexID & 1) == 0 ? 0.0 : 1.0;
        corner.y = (vertexID & 2) == 0 ? 0.0 : 1.0;
        float px = inst.rect.x + corner.x * inst.rect.z;
        float py = inst.rect.y + corner.y * inst.rect.w;
        float clipX = (px / uniforms.viewportSize.x) * 2.0 - 1.0;
        float clipY = 1.0 - (py / uniforms.viewportSize.y) * 2.0;
        VertexOut out;
        out.position = float4(clipX, clipY, 0.0, 1.0);
        out.rectPos = corner;
        out.coefs = inst.coefs;
        out.baseColor = inst.color;
        out.rectSize = float2(inst.rect.z, inst.rect.w);
        out.instanceID = int(instanceID);
        return out;
    }

    fragment float4 cushionFragmentShader(
        VertexOut in [[stage_in]],
        constant CushionUniforms& uniforms [[buffer(1)]]
    ) {
        float px = in.rectPos.x;
        float py = in.rectPos.y;

        // Gamma-correct: sRGB -> linear
        float3 baseLinear = srgbToLinear(in.baseColor.rgb);

        // Compute cushion surface normal from parabolic coefficients.
        float nx = -(2.0 * in.coefs.x * px + in.coefs.y);
        float ny = -(2.0 * in.coefs.z * py + in.coefs.w);
        float nz = 1.0;
        float3 N = normalize(float3(nx, ny, nz));

        // Lighting vectors.
        float3 lightDir = normalize(uniforms.lightDir);
        float3 viewDir = float3(0.0, 0.0, 1.0);

        // Diffuse (Lambertian).
        float diffuse = max(0.0, dot(N, lightDir));

        // Specular (Blinn-Phong).
        float3 H = normalize(lightDir + viewDir);
        float spec = pow(max(dot(N, H), 0.0), 48.0);
        float specIntensity = 0.15;

        // Combined lighting.
        float intensity = uniforms.ambient + (1.0 - uniforms.ambient) * diffuse;
        float3 litColor = baseLinear * intensity + float3(specIntensity * spec);

        // Anti-aliased borders using smoothstep.
        float edgeX = min(px * in.rectSize.x, (1.0 - px) * in.rectSize.x);
        float edgeY = min(py * in.rectSize.y, (1.0 - py) * in.rectSize.y);
        float edgeDist = min(edgeX, edgeY);
        float borderFactor = smoothstep(0.0, 1.5, edgeDist);
        litColor *= mix(0.25, 1.0, borderFactor);

        // Hover glow: brighten hovered instance and add outline.
        if (in.instanceID == uniforms.hoveredIndex) {
            // Bright outline: 2px from edge.
            if (edgeDist < 2.0) {
                float outlineAlpha = 1.0 - smoothstep(0.5, 2.0, edgeDist);
                litColor = mix(litColor, float3(1.0, 1.0, 1.0), outlineAlpha * 0.6);
            }
            litColor += float3(0.12);
        }

        // Clamp and gamma-correct: linear -> sRGB.
        float3 result = linearToSrgb(clamp(litColor, 0.0, 1.0));

        return float4(result, in.baseColor.a);
    }
    """
}
