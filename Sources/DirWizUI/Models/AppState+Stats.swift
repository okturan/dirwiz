import Foundation
import DirWizCore

extension AppState {

    private struct ExtensionAccumulator {
        var totalSize: UInt64 = 0
        var fileCount: Int = 0
    }

    // MARK: - Statistics Computation

    /// Build extension statistics from the file tree.
    public func computeExtensionStats() {
        guard let tree = fileTree else { return }
        var statsByExt: [String: ExtensionAccumulator] = [:]
        let colorMap = ExtensionColorMap.shared

        let snapshot = tree.nodesSnapshot()
        let stringPool = tree.stringPoolSnapshot()
        let totalSize = snapshot.first?.displaySize ?? 0
        statsByExt.reserveCapacity(min(snapshot.count, 512))

        for i in 0..<snapshot.count {
            let node = snapshot[i]
            guard !node.isDirectory else { continue }

            let ext = Self.extractExtension(from: node, stringPool: stringPool)
            var stats = statsByExt[ext, default: ExtensionAccumulator()]
            stats.totalSize += node.displaySize
            stats.fileCount += 1
            statsByExt[ext] = stats
        }

        // Per-extension-name stats keyed by string (collision-safe).
        fileTypeStats = statsByExt.map { ext, stats in
            let hash = ext.isEmpty ? UInt32(0) : extensionHash(".\(ext)")
            return FileTypeStat(
                extensionName: ext,
                extensionHash: hash,
                category: colorMap.category(forHash: hash),
                totalSize: stats.totalSize,
                fileCount: stats.fileCount,
                percentage: totalSize > 0 ? Double(stats.totalSize) / Double(totalSize) : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }

        // Assign WinDirStat-style palette colors based on extension size ranking.
        extensionPalette.assign(from: fileTypeStats)
        loadSnapshotIfAvailable()
    }

    private static func extractExtension(from node: FileNode, stringPool: Data) -> String {
        let start = Int(node.nameOffset)
        let nameLength = Int(node.nameLength)
        let end = start + nameLength
        guard start >= 0, nameLength > 0, end <= stringPool.count else { return "" }

        return stringPool.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return ""
            }

            let nameBase = base + start
            var dotOffset = -1
            var i = nameLength - 1
            while i >= 0 {
                if nameBase[i] == UInt8(ascii: ".") {
                    dotOffset = i
                    break
                }
                i -= 1
            }

            guard dotOffset >= 0, dotOffset < nameLength - 1 else { return "" }
            let extStart = dotOffset + 1
            let extCount = nameLength - extStart
            let extBuffer = UnsafeBufferPointer(start: nameBase + extStart, count: extCount)
            return (String(bytes: extBuffer, encoding: .utf8) ?? "").lowercased()
        }
    }
}
