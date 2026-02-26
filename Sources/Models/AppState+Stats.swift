import Foundation

extension AppState {

    // MARK: - Statistics Computation

    /// Build extension statistics from the file tree.
    public func computeExtensionStats() {
        guard let tree = fileTree else { return }
        var sizeByHash: [UInt16: UInt64] = [:]
        var countByHash: [UInt16: Int] = [:]
        var sizeByExt: [String: UInt64] = [:]
        var countByExt: [String: Int] = [:]
        let colorMap = ExtensionColorMap.shared

        let snapshot = tree.nodesSnapshot()
        let totalSize = snapshot.first?.fileSize ?? 0

        for i in 0..<snapshot.count {
            let node = snapshot[i]
            guard !node.isDirectory else { continue }

            sizeByHash[node.extensionHash, default: 0] += node.fileSize
            countByHash[node.extensionHash, default: 0] += 1

            // Extract extension name for per-type stats.
            let name = tree.name(at: UInt32(i))
            let ext = Self.extractExtension(from: name)
            sizeByExt[ext, default: 0] += node.fileSize
            countByExt[ext, default: 0] += 1
        }

        // Per-hash stats (for categories legend).
        extensionStats = sizeByHash.map { hash, size in
            ExtensionStat(
                extensionHash: hash,
                category: colorMap.category(forHash: hash),
                totalSize: size,
                fileCount: countByHash[hash] ?? 0,
                percentage: totalSize > 0 ? Double(size) / Double(totalSize) : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }

        // Per-extension-name stats (for file types list).
        // Key by extensionHash (same value the scanner stores on each node) so that
        // palette lookups in the treemap and the Extensions list use the same hash.
        var sizeByExtHash: [UInt16: (name: String, size: UInt64, count: Int)] = [:]
        for (ext, size) in sizeByExt {
            let hash = extensionHash(".\(ext)")  // matches scanner: hash(part after last dot)
            if var e = sizeByExtHash[hash] {
                e.size += size
                e.count += countByExt[ext] ?? 0
                sizeByExtHash[hash] = e
            } else {
                sizeByExtHash[hash] = (name: ext, size: size, count: countByExt[ext] ?? 0)
            }
        }
        fileTypeStats = sizeByExtHash.map { hash, e in
            FileTypeStat(
                extensionName: e.name,
                extensionHash: hash,
                category: colorMap.category(forHash: hash),
                totalSize: e.size,
                fileCount: e.count,
                percentage: totalSize > 0 ? Double(e.size) / Double(totalSize) : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }

        // Assign WinDirStat-style palette colors based on extension size ranking.
        extensionPalette.assign(from: fileTypeStats)
        computeReclaimScores()
        loadSnapshotIfAvailable()
    }

    /// Compute per-directory reclaim score (0-100) using size/staleness/cache/duplicate factors.
    public func computeReclaimScores() {
        guard let tree = fileTree else {
            reclaimScores = []
            return
        }
        let nodes = tree.nodesSnapshot()
        guard !nodes.isEmpty else {
            reclaimScores = []
            return
        }

        // Step 1: Bottom-up pass for cache bytes per node.
        let colorMap = ExtensionColorMap.shared
        var cacheBytesPerNode = Array(repeating: UInt64(0), count: nodes.count)
        for i in stride(from: nodes.count - 1, through: 0, by: -1) {
            let node = nodes[i]
            if !node.isDirectory, colorMap.category(forHash: node.extensionHash) == .caches {
                cacheBytesPerNode[i] = node.fileSize
            }
            let parentIndex = node.parentIndex
            if parentIndex != FileNode.invalid {
                let parentInt = Int(parentIndex)
                if parentInt < cacheBytesPerNode.count {
                    cacheBytesPerNode[parentInt] += cacheBytesPerNode[i]
                }
            }
        }

        // Step 2: Duplicate wasted bytes by directory from duplicateGroups paths.
        var dupWastedByDir: [UInt32: UInt64] = [:]
        if !duplicateGroups.isEmpty {
            var pathToIndex: [String: UInt32] = [:]
            pathToIndex.reserveCapacity(nodes.count)
            for i in 0..<nodes.count {
                pathToIndex[tree.path(at: UInt32(i))] = UInt32(i)
            }

            for group in duplicateGroups where group.paths.count > 1 {
                for path in group.paths.dropFirst() {
                    guard let fileIndex = pathToIndex[path] else { continue }
                    var current = fileIndex
                    var hops = 0
                    while current != FileNode.invalid, hops < nodes.count {
                        let currentInt = Int(current)
                        guard currentInt < nodes.count else { break }
                        let currentNode = nodes[currentInt]
                        if currentNode.isDirectory {
                            dupWastedByDir[current, default: 0] += group.fileSize
                        }
                        current = currentNode.parentIndex
                        hops += 1
                    }
                }
            }
        }

        // Step 3: Max child size per parent (sibling normalization).
        var maxChildSizeByParent: [UInt32: UInt64] = [:]
        maxChildSizeByParent.reserveCapacity(nodes.count / 2)
        for i in 0..<nodes.count {
            let parentIndex = nodes[i].parentIndex
            if parentIndex == FileNode.invalid { continue }
            let childSize = nodes[i].fileSize
            if childSize > (maxChildSizeByParent[parentIndex] ?? 0) {
                maxChildSizeByParent[parentIndex] = childSize
            }
        }

        // Step 4: Direct-file modified timestamps per directory.
        var childTimestamps: [UInt32: [UInt32]] = [:]
        childTimestamps.reserveCapacity(nodes.count / 2)
        for i in 0..<nodes.count {
            let node = nodes[i]
            guard !node.isDirectory else { continue }
            let parentIndex = node.parentIndex
            if parentIndex == FileNode.invalid { continue }
            childTimestamps[parentIndex, default: []].append(node.modifiedDate)
        }

        // Step 5: Final score per directory.
        let nowSeconds = UInt32(Date().timeIntervalSince1970)
        var scores = Array(repeating: UInt8(0), count: nodes.count)

        for i in 0..<nodes.count {
            let node = nodes[i]
            guard node.isDirectory else { continue }

            let sizeFactor: Double
            if i == 0 {
                sizeFactor = 1.0
            } else if node.parentIndex == FileNode.invalid {
                sizeFactor = 0
            } else {
                let maxSiblingSize = maxChildSizeByParent[node.parentIndex] ?? 0
                if maxSiblingSize == 0 {
                    sizeFactor = 0
                } else {
                    let numerator = Foundation.log(Double(1 + node.fileSize))
                    let denominator = Foundation.log(Double(1 + maxSiblingSize))
                    let raw = denominator > 0 ? numerator / denominator : 0
                    sizeFactor = min(max(raw, 0), 1)
                }
            }

            let stalenessFactor: Double
            if var timestamps = childTimestamps[UInt32(i)], !timestamps.isEmpty {
                timestamps.sort()
                let medianTimestamp = timestamps[timestamps.count / 2]
                if medianTimestamp == 0 {
                    stalenessFactor = 0
                } else {
                    let ageSeconds = nowSeconds > medianTimestamp ? nowSeconds - medianTimestamp : 0
                    let ageDays = Double(ageSeconds) / 86_400.0
                    stalenessFactor = min(ageDays, 730.0) / 730.0
                }
            } else {
                stalenessFactor = 0
            }

            let totalBytes = node.fileSize
            let cacheFactor: Double = totalBytes > 0
                ? Double(cacheBytesPerNode[i]) / Double(totalBytes)
                : 0

            let dupWasted = dupWastedByDir[UInt32(i)] ?? 0
            let dupFactor: Double = totalBytes > 0
                ? min(Double(dupWasted) / Double(totalBytes), 1.0)
                : 0

            let weighted = (0.35 * sizeFactor) +
                (0.25 * stalenessFactor) +
                (0.25 * cacheFactor) +
                (0.15 * dupFactor)
            let score = Int((weighted * 100.0).rounded())
            scores[i] = UInt8(clamping: min(max(score, 0), 100))
        }

        reclaimScores = scores
    }

    private static func extractExtension(from name: String) -> String {
        guard let dotIndex = name.lastIndex(of: ".") else { return "(no ext)" }
        let ext = String(name[name.index(after: dotIndex)...]).lowercased()
        return ext.isEmpty ? "(no ext)" : ext
    }
}
