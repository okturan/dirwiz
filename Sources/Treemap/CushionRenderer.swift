import Foundation
import MetalKit

// MARK: - MTKView Coordinator

/// Metal coordinator that renders the cushion treemap using instanced drawing.
@MainActor
final class CushionTreemapCoordinator: NSObject, MTKViewDelegate, @unchecked Sendable {

    private let device: MTLDevice
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private let maxFramesInFlight = 3
    private let frameSemaphore = DispatchSemaphore(value: 3)
    private var currentBufferIndex = 0
    private var instanceBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var uniformBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var instanceBufferCapacities: [Int] = [0, 0, 0]
    weak var mtkView: MTKView?

    private var instanceCount: Int = 0

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

        let applyLayout: @MainActor @Sendable ([TreemapRect], SpatialGrid) -> Void = { [weak self] layout, grid in
            guard let self else { return }
            guard self.currentRootIndex == rootIndex else { return }
            self.cachedLayout = layout
            self.cachedSnapshot = snapshot
            self.spatialGrid = grid
            self.instanceBufferDirty = true
            self.onLayoutUpdate?(layout)
            self.mtkView?.needsDisplay = true
        }

        // Fix 2: Run layout off the main thread to avoid frame drops.
        let task = Task.detached(priority: .userInitiated) {
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
            await applyLayout(layout, grid)
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

        // Skip rebuild if nothing changed and all per-frame buffers are valid.
        if !instanceBufferDirty && (instanceCount == 0 || instanceBuffers[currentBufferIndex] != nil) {
            return
        }

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

        let resolver = TreemapColorResolver(
            palette: extensionPalette,
            recencyFactors: recencyFactors,
            isRecencyOverlayEnabled: isRecencyOverlayEnabled,
            temporalDiffKinds: temporalDiffKinds,
            temporalDiffStrengths: temporalDiffStrengths,
            isTemporalDiffEnabled: isTemporalDiffEnabled
        )

        var instances: [CushionInstance] = []
        instances.reserveCapacity(visibleCount)

        var lookup: [UInt32: Int32] = [:]
        lookup.reserveCapacity(visibleCount)

        var writeIdx: Int32 = 0
        for i in 0..<layoutCount {
            let tmRect = cachedLayout[i]

            // Sub-pixel culling: skip rects smaller than half a pixel in either dimension.
            guard tmRect.width >= 0.5, tmRect.height >= 0.5 else { continue }

            let nodeIdx = Int(tmRect.nodeIndex)
            guard nodeIdx < nodes.count else { continue }

            let baseColor = resolver.resolveColor(for: tmRect, nodes: nodes, scratchSizeByExt: &scratchSizeByExt)

            // Use cached coefficients instead of recomputing.
            let coefs = tmRect.cachedCoefs

            instances.append(CushionInstance(
                rect: SIMD4<Float>(tmRect.x, tmRect.y, tmRect.width, tmRect.height),
                coefs: coefs,
                color: baseColor
            ))
            lookup[tmRect.nodeIndex] = writeIdx
            writeIdx += 1
        }

        instanceCount = instances.count
        nodeToInstanceIndex = lookup

        guard instanceCount > 0 else {
            instanceBufferDirty = false
            return
        }

        let requiredSize = instanceCount * MemoryLayout<CushionInstance>.stride
        for bufferIndex in 0..<maxFramesInFlight {
            guard let buffer = ensureInstanceBuffer(at: bufferIndex, requiredSize: requiredSize) else {
                continue
            }
            instances.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                buffer.contents().copyMemory(from: src, byteCount: requiredSize)
            }
        }

        instanceBufferDirty = false
    }

    private func ensureInstanceBuffer(at index: Int, requiredSize: Int) -> MTLBuffer? {
        guard index >= 0, index < instanceBuffers.count else { return nil }
        if instanceBuffers[index] == nil || requiredSize > instanceBufferCapacities[index] {
            let newCapacity = max(requiredSize, max(instanceBufferCapacities[index] * 2, 1))
            instanceBuffers[index] = device.makeBuffer(
                length: newCapacity,
                options: .storageModeShared
            )
            instanceBufferCapacities[index] = newCapacity
        }
        return instanceBuffers[index]
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

        let result = frameSemaphore.wait(timeout: .now() + .milliseconds(16))
        if result == .timedOut { return }

        let viewportSize = view.drawableSize
        let backingScaleFactor = view.window?.backingScaleFactor ?? 2.0
        let logicalSize = CGSize(
            width: viewportSize.width / backingScaleFactor,
            height: viewportSize.height / backingScaleFactor
        )

        recomputeLayoutIfNeeded(viewportSize: logicalSize)
        updateInstanceBuffer()

        guard instanceCount > 0, let instanceBuffer = instanceBuffers[currentBufferIndex] else {
            // Draw a clear frame.
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                frameSemaphore.signal()
                return
            }
            let semaphore = frameSemaphore
            commandBuffer.addCompletedHandler { _ in
                semaphore.signal()
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
                commandBuffer.commit()
                currentBufferIndex = (currentBufferIndex + 1) % maxFramesInFlight
                return
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            currentBufferIndex = (currentBufferIndex + 1) % maxFramesInFlight
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

        if uniformBuffers[currentBufferIndex] == nil {
            uniformBuffers[currentBufferIndex] = device.makeBuffer(
                length: MemoryLayout<CushionUniforms>.stride,
                options: .storageModeShared
            )
        }
        guard let uniformBuffer = uniformBuffers[currentBufferIndex] else {
            frameSemaphore.signal()
            return
        }
        uniformBuffer.contents().copyMemory(
            from: &uniforms,
            byteCount: MemoryLayout<CushionUniforms>.stride
        )

        // Render.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            frameSemaphore.signal()
            return
        }
        let semaphore = frameSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            commandBuffer.commit()
            currentBufferIndex = (currentBufferIndex + 1) % maxFramesInFlight
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
        currentBufferIndex = (currentBufferIndex + 1) % maxFramesInFlight
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
