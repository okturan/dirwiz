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
    var extensionPalette = ExtensionPalette()
    var recencyFactors: [Float] = []
    var recencyGeneration: UInt64 = 0
    var isRecencyOverlayEnabled: Bool = false
    var temporalDiffKinds: [UInt8] = []
    var temporalDiffStrengths: [Float] = []
    var isTemporalDiffEnabled: Bool = false
    var temporalDiffGeneration: UInt64 = 0

    /// Layout throttling — minimum interval between layout recomputes.
    private var lastLayoutTime: CFAbsoluteTime = 0
    private var needsForceLayout: Bool = false

    /// Instance buffer dirty tracking — skip rebuild when nothing changed.
    var instanceBufferDirty: Bool = true
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

        let palette = extensionPalette
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
                    let childColor = palette.color(forHash: dominantHash)
                    baseColor = blend(dirColor, childColor, factor: 0.65)
                } else {
                    baseColor = dirColor
                }
            } else {
                baseColor = palette.color(forHash: node.extensionHash)
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

            // Encode recency factor in alpha for shader desaturation.
            // While factors are still loading (empty array), show everything as fully recent.
            if isRecencyOverlayEnabled {
                let nodeI = Int(tmRect.nodeIndex)
                baseColor.w = recencyFactors.isEmpty ? 1.0
                    : (nodeI < recencyFactors.count ? recencyFactors[nodeI] : 0.0)
            }
            // else: baseColor.w stays 1.0 (set by palette / directory colors above)

            // Apply temporal diff tinting by pre-blending in Swift (no shader changes needed).
            if isTemporalDiffEnabled {
                let nodeI = Int(tmRect.nodeIndex)
                if nodeI < temporalDiffKinds.count {
                    let kind = TemporalDiffKind(rawValue: temporalDiffKinds[nodeI]) ?? .none
                    if kind != .none {
                        let strength = nodeI < temporalDiffStrengths.count
                            ? temporalDiffStrengths[nodeI] : 0.5
                        let tint: SIMD3<Float>
                        switch kind {
                        case .new:                tint = SIMD3(0.20, 0.82, 0.35)
                        case .grown:              tint = SIMD3(0.20, 0.55, 0.95)
                        case .shrunk:             tint = SIMD3(0.95, 0.72, 0.20)
                        case .deletedDescendants: tint = SIMD3(0.90, 0.25, 0.25)
                        case .none:               tint = SIMD3(0, 0, 0)
                        }
                        let t = 0.25 + 0.45 * strength
                        baseColor.x += (tint.x - baseColor.x) * t
                        baseColor.y += (tint.y - baseColor.y) * t
                        baseColor.z += (tint.z - baseColor.z) * t
                    }
                }
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
        let paletteChanged = coordinator.extensionPalette.generation != extensionPalette.generation
        let recencyChanged = coordinator.recencyGeneration != recencyGeneration ||
                             coordinator.isRecencyOverlayEnabled != isRecencyOverlayEnabled
        let temporalChanged = coordinator.temporalDiffGeneration != temporalDiffGeneration ||
                              coordinator.isTemporalDiffEnabled != isTemporalDiffEnabled

        coordinator.currentFileTree = fileTree
        coordinator.currentTreeRevision = treeRevision
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

        // User navigation gets immediate layout; scan updates are throttled.
        if treeChanged || rootChanged {
            coordinator.forceLayoutInvalidation()
        } else if revisionChanged {
            coordinator.invalidateLayout()
        }

        if treeChanged || rootChanged || revisionChanged || selectionChanged || paletteChanged || recencyChanged || temporalChanged {
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

