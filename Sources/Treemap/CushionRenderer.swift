import Foundation
import MetalKit

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

    /// Pending async layout task (cancelled when a new layout is needed).
    private var pendingLayoutTask: Task<Void, Never>?
    private var pendingLayoutSize: CGSize = .zero

    /// Instance buffer dirty tracking — skip rebuild when nothing changed.
    var instanceBufferDirty: Bool = true

    /// Maps nodeIndex -> visible instance index for O(1) hover lookup.
    private var nodeToInstanceIndex: [UInt32: Int32] = [:]

    /// Scratch dictionary reused by dominantDirectFileExtensionHash to avoid per-call allocation.
    private var scratchSizeByExt: [UInt32: UInt64] = [:]

    /// Tracks the last submitted command buffer so we can ensure GPU completion
    /// before overwriting shared buffers. For this on-demand renderer (isPaused=true),
    /// waitUntilCompleted() returns near-instantly since GPU finishes in <1ms
    /// and draws are spaced by at least one display refresh (~16ms).
    private var lastCommandBuffer: MTLCommandBuffer?

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

        verifyCushionLayouts()
        self.commandQueue = device.makeCommandQueue()
        setupPipeline(mtkView: mtkView)
    }

    // MARK: - Pipeline Setup

    /// Cached compiled Metal library — avoids re-parsing the shader source
    /// if the coordinator is recreated (e.g., SwiftUI view identity change).
    /// Keyed by device registryID to handle multi-GPU setups correctly.
    /// Thread-safe: only accessed from main thread (init is called from makeNSView).
    private static var cachedLibraries: [UInt64: MTLLibrary] = [:]

    private func setupPipeline(mtkView: MTKView) {
        // Compile shaders from embedded source at runtime.
        // SPM doesn't compile .metal files into .metallib, so we embed the source.
        let library: MTLLibrary
        if let cached = Self.cachedLibraries[device.registryID] {
            library = cached
        } else {
            do {
                library = try device.makeLibrary(source: CushionShaderSource.source, options: nil)
                Self.cachedLibraries[device.registryID] = library
            } catch {
                print("CushionRenderer: Failed to compile Metal shaders: \(error)")
                return
            }
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

    /// Recompute layout if inputs have changed.
    /// Immediately scale-previews existing rects (Fix 3), then launches layout off the main
    /// thread (Fix 2). The background task replaces cachedLayout when it finishes.
    func recomputeLayoutIfNeeded(viewportSize: CGSize) {
        guard let tree = currentFileTree, !tree.isEmpty else {
            pendingLayoutTask?.cancel()
            pendingLayoutTask = nil
            cachedLayout = []
            cachedSnapshot = []
            spatialGrid = nil
            return
        }

        let sizeChanged = viewportSize != currentViewportSize
        if !sizeChanged && !cachedLayout.isEmpty {
            return // Nothing changed.
        }

        // Dedup: if a task is already in flight for this exact size, skip relaunching.
        if pendingLayoutTask != nil && pendingLayoutSize == viewportSize {
            return
        }

        // freshStart: currentViewportSize == .zero means force/invalidate was called —
        // skip scale preview since the layout data or root has changed.
        let freshStart = currentViewportSize == .zero
        pendingLayoutTask?.cancel()

        // Fix 3: Immediately scale existing rects to fill the new viewport.
        // Coefs remain valid — they're computed in normalized [0,1] space per rect,
        // so uniform proportional scaling leaves them unchanged.
        if !cachedLayout.isEmpty && !freshStart && sizeChanged {
            let sx = Float(viewportSize.width / currentViewportSize.width)
            let sy = Float(viewportSize.height / currentViewportSize.height)
            for i in cachedLayout.indices {
                cachedLayout[i].x *= sx
                cachedLayout[i].y *= sy
                cachedLayout[i].width *= sx
                cachedLayout[i].height *= sy
            }
            spatialGrid = nil // Stale; rebuilt when background layout completes.
            instanceBufferDirty = true
        }

        currentViewportSize = viewportSize
        pendingLayoutSize = viewportSize

        // Snapshot nodes ONCE — single lock acquisition, then layout runs lock-free.
        let snapshot = tree.nodesSnapshot()
        let rootIndex = currentRootIndex
        let bounds = CGRect(origin: .zero, size: viewportSize)

        // Fix 2: Run layout off the main thread to avoid frame drops.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let layout = SquarifyLayout.layout(
                nodes: snapshot,
                rootIndex: rootIndex,
                bounds: bounds,
                maxDepth: 20,
                minPixelSize: 1.0
            )
            guard !Task.isCancelled else { return }
            let grid = SpatialGrid(
                viewportWidth: Float(bounds.width),
                viewportHeight: Float(bounds.height),
                rects: layout
            )
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                guard self.currentRootIndex == rootIndex else { return }
                self.cachedLayout = layout
                self.cachedSnapshot = snapshot
                self.spatialGrid = grid
                self.instanceBufferDirty = true
                self.onLayoutUpdate?(layout)
                self.mtkView?.needsDisplay = true
            }
        }
        pendingLayoutTask = task
    }

    func invalidateLayout() {
        pendingLayoutTask?.cancel()
        pendingLayoutTask = nil
        currentViewportSize = .zero
    }

    // MARK: - Instance Buffer

    private func updateInstanceBuffer() {
        guard !cachedLayout.isEmpty, !cachedSnapshot.isEmpty else {
            instanceCount = 0
            return
        }

        // Skip rebuild if nothing changed.
        // Hover and selection are handled via shader uniforms — no per-instance rebuild needed.
        if !instanceBufferDirty {
            return
        }
        instanceBufferDirty = false

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
                        case .none:               tint = .zero
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

        // Rebuild O(1) hover lookup: nodeIndex -> visible instance index.
        var lookup: [UInt32: Int32] = [:]
        lookup.reserveCapacity(writeIdx)
        var idx: Int32 = 0
        for i in 0..<layoutCount {
            let r = cachedLayout[i]
            guard r.width >= 0.5, r.height >= 0.5 else { continue }
            lookup[r.nodeIndex] = idx
            idx += 1
        }
        nodeToInstanceIndex = lookup
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
    /// Reuses scratchSizeByExt to avoid per-call dictionary allocation.
    private func dominantDirectFileExtensionHash(in directoryIndex: UInt32, nodes: [FileNode]) -> UInt32? {
        let i = Int(directoryIndex)
        guard i < nodes.count else { return nil }
        let node = nodes[i]
        guard node.firstChildIndex != FileNode.invalid else { return nil }
        let start = Int(node.firstChildIndex)
        let end = min(start + Int(node.childCount), nodes.count)
        guard start < end else { return nil }

        scratchSizeByExt.removeAll(keepingCapacity: true)
        for childIndex in start..<end {
            let child = nodes[childIndex]
            guard !child.isDirectory else { continue }
            scratchSizeByExt[child.extensionHash, default: 0] += child.fileSize
        }

        return scratchSizeByExt.max(by: { $0.value < $1.value })?.key
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

        // Ensure previous frame's GPU work is complete before overwriting shared buffers.
        // For this on-demand renderer, this returns near-instantly (GPU finishes in <1ms,
        // draws are spaced by at least one display refresh).
        lastCommandBuffer?.waitUntilCompleted()

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
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
                commandBuffer.commit()
                return
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // Set up uniforms.
        // Map hover/selection node indices to visible instance indices for shader via O(1) lookup.
        var hoveredInstance: Int32 = -1
        if let hovered = hoveredNodeIndex {
            hoveredInstance = nodeToInstanceIndex[hovered] ?? -1
        }
        var selectedInstance: Int32 = -1
        if let selected = selectedNodeIndex {
            selectedInstance = nodeToInstanceIndex[selected] ?? -1
        }

        let ld = normalize(SIMD3<Float>(0.5, 0.5, 1.0))
        var uniforms = CushionUniforms(
            viewportSize: SIMD2<Float>(Float(logicalSize.width), Float(logicalSize.height)),
            ambient: 0.25,
            padding1: 0,
            lightDir: SIMD4<Float>(ld.x, ld.y, ld.z, 0),
            hoveredIndex: hoveredInstance,
            selectedIndex: selectedInstance
        )

        if uniformBuffer == nil {
            uniformBuffer = device.makeBuffer(
                length: MemoryLayout<CushionUniforms>.stride,
                options: .storageModeShared
            )
        }
        guard let uniformBuffer else { return }
        uniformBuffer.contents().copyMemory(
            from: &uniforms,
            byteCount: MemoryLayout<CushionUniforms>.stride
        )

        // Render.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)

        // Draw triangle strip quads, instanced.
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
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
