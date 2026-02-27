import Foundation
import DirWizLib

/// DirWiz CLI — command-line disk analysis using DirWizLib.
///
/// Usage:
///   dirwiz-cli scan <path> [--json] [--min-size <bytes>] [--max-depth <n>]
///   dirwiz-cli duplicates <path> [--min-size <bytes>] [--json]
///   dirwiz-cli info <path>
///   dirwiz-cli benchmark <path> [--iterations <n>] [--json]
///   dirwiz-cli --help
@main
struct DirWizCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        guard !args.isEmpty else {
            printUsage()
            exit(1)
        }

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        let command = args[0]
        let remainingArgs = Array(args.dropFirst())

        switch command {
        case "scan":
            await handleScan(args: remainingArgs)
        case "duplicates":
            await handleDuplicates(args: remainingArgs)
        case "info":
            await handleInfo(args: remainingArgs)
        case "benchmark":
            await handleBenchmark(args: remainingArgs)
        default:
            errPrint("Unknown command: \(command)")
            printUsage()
            exit(1)
        }
    }

    // MARK: - Scan Command

    static func handleScan(args: [String]) async {
        guard let path = args.first(where: { !$0.hasPrefix("-") }) else {
            errPrint("Error: scan requires a path argument")
            exit(1)
        }

        let outputJSON = args.contains("--json")
        let minSize = parseUInt64Flag("--min-size", from: args) ?? 0
        let maxDepth = parseInt("--max-depth", from: args)
        let quiet = args.contains("--quiet") || args.contains("-q")

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()

        if !quiet {
            errPrint("Scanning \(path)...")
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        await scanner.scan(path: path, progress: progress, tree: tree)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        if !quiet {
            errPrint(String(format: "Scanned %@ items in %.1fs",
                            SizeFormatter.shared.formatCount(tree.count), elapsed))
        }

        if outputJSON {
            do {
                let exporter = JSONExporter()
                let options = JSONExportOptions(
                    maxDepth: maxDepth, minSize: minSize,
                    includeFiles: true, prettyPrint: true
                )
                let data = try await exporter.export(tree: tree, options: options)
                if let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } catch {
                errPrint("Error exporting JSON: \(error.localizedDescription)")
                exit(1)
            }
        } else {
            printTreeTable(tree: tree, minSize: minSize)
        }
    }

    // MARK: - Duplicates Command

    static func handleDuplicates(args: [String]) async {
        guard let path = args.first(where: { !$0.hasPrefix("-") }) else {
            errPrint("Error: duplicates requires a path argument")
            exit(1)
        }

        let outputJSON = args.contains("--json")
        let minSize = parseUInt64Flag("--min-size", from: args) ?? 1_048_576
        let quiet = args.contains("--quiet") || args.contains("-q")

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()

        if !quiet { errPrint("Scanning \(path)...") }
        await scanner.scan(path: path, progress: progress, tree: tree)
        if !quiet { errPrint("Scanning for duplicates...") }

        let finder = DuplicateFinder()
        let groups = await finder.findDuplicates(in: tree)
        let filtered = groups.filter { $0.fileSize >= minSize }

        if !quiet {
            errPrint("\(filtered.count) duplicate groups found (min size: \(SizeFormatter.shared.format(minSize)))")
        }

        if outputJSON {
            let jsonGroups = filtered.map { group -> [String: Any] in
                [
                    "fileSize": group.fileSize,
                    "copies": group.paths.count,
                    "wastedSpace": group.wastedSpace,
                    "paths": group.paths,
                ]
            }
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: jsonGroups,
                    options: [.prettyPrinted, .sortedKeys]
                )
                if let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } catch {
                errPrint("Error: \(error.localizedDescription)")
                exit(1)
            }
        } else {
            var totalWasted: UInt64 = 0
            for group in filtered {
                totalWasted += group.wastedSpace
                print("\(SizeFormatter.shared.format(group.fileSize)) x\(group.paths.count) (wasted: \(SizeFormatter.shared.format(group.wastedSpace)))")
                for path in group.paths {
                    print("  \(path)")
                }
                print()
            }
            print("Total wasted: \(SizeFormatter.shared.format(totalWasted))")
        }
    }

    // MARK: - Info Command

    static func handleInfo(args: [String]) async {
        guard let path = args.first(where: { !$0.hasPrefix("-") }) else {
            errPrint("Error: info requires a path argument")
            exit(1)
        }

        let quiet = args.contains("--quiet") || args.contains("-q")

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()

        if !quiet { errPrint("Scanning \(path)...") }
        await scanner.scan(path: path, progress: progress, tree: tree)

        // Space analysis
        let spaceAnalyzer = SpaceAnalyzer()
        let spaceResult = await spaceAnalyzer.analyze(tree: tree)

        print("=== Space Categories ===")
        for cat in spaceResult.categories {
            let safety = cat.safetyRating == .safe ? "[SAFE]"
                : cat.safetyRating == .caution ? "[CAUTION]"
                : "[INFO]"
            print("  \(safety.padding(toLength: 12, withPad: " ", startingAt: 0)) \(cat.name.padding(toLength: 35, withPad: " ", startingAt: 0)) \(SizeFormatter.shared.format(cat.totalSize))")
        }
        print()

        // File age analysis
        let ageAnalyzer = FileAgeAnalyzer()
        let ageResult = await ageAnalyzer.analyze(tree: tree)

        print("=== File Age Distribution ===")
        for bucket in ageResult.buckets where bucket.fileCount > 0 {
            let pct = String(format: "%.1f%%", bucket.percentage)
            print("  \(bucket.label.padding(toLength: 15, withPad: " ", startingAt: 0)) \(String(bucket.fileCount).leftPad(8)) files  \(SizeFormatter.shared.format(bucket.totalSize)) (\(pct))")
        }
        print()

        // Size distribution
        let sizeAnalyzer = SizeDistributionAnalyzer()
        let sizeResult = await sizeAnalyzer.analyze(tree: tree)

        print("=== Size Distribution ===")
        for bucket in sizeResult.buckets where bucket.fileCount > 0 {
            print("  \(bucket.label.padding(toLength: 15, withPad: " ", startingAt: 0)) \(String(bucket.fileCount).leftPad(8)) files  \(SizeFormatter.shared.format(bucket.totalSize))")
        }
        print()
        print("  Median: \(SizeFormatter.shared.format(sizeResult.medianSize))  Mean: \(SizeFormatter.shared.format(sizeResult.meanSize))")
        print("  P90: \(SizeFormatter.shared.format(sizeResult.percentiles.p90))  P99: \(SizeFormatter.shared.format(sizeResult.percentiles.p99))")
        print()

        // Purgeable space
        let apfs = APFSIntelligence()
        if let purgeable = await apfs.queryPurgeableSpace(volumePath: path) {
            print("=== Volume Space ===")
            print("  Total:     \(SizeFormatter.shared.format(purgeable.totalCapacity))")
            print("  Free:      \(SizeFormatter.shared.format(purgeable.availableCapacity))")
            print("  Purgeable: \(SizeFormatter.shared.format(purgeable.purgeableAmount))")
            print("  True Free: \(SizeFormatter.shared.format(purgeable.availableForOpportunistic))")
            print()
        }

        // Time Machine snapshots
        if let tmInfo = await apfs.listTMSnapshots(volumePath: path) {
            if !tmInfo.snapshots.isEmpty {
                print("=== Time Machine Local Snapshots ===")
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .short
                for snap in tmInfo.snapshots.prefix(10) {
                    print("  \(df.string(from: snap.date))")
                }
                if tmInfo.snapshots.count > 10 {
                    print("  ... and \(tmInfo.snapshots.count - 10) more")
                }
                print()
            }
        }
    }

    // MARK: - Helpers

    static func printTreeTable(tree: FileTree, minSize: UInt64) {
        let nodes = tree.nodesSnapshot()
        guard !nodes.isEmpty else { return }

        let root = nodes[0]
        let rootPath = tree.path(at: 0)
        let rootSize = SizeFormatter.shared.format(root.displaySize)
        print("\(rootPath.padding(toLength: 60, withPad: " ", startingAt: 0)) \(rootSize.leftPad(12)) \(String(tree.count).leftPad(8))")
        print(String(repeating: "-", count: 82))

        // Print top-level children sorted by size
        if root.firstChildIndex != FileNode.invalid {
            let start = Int(root.firstChildIndex)
            let end = min(start + Int(root.childCount), nodes.count)
            var children: [(index: Int, size: UInt64)] = []
            for ci in start..<end {
                let size = nodes[ci].displaySize
                if size >= minSize {
                    children.append((ci, size))
                }
            }
            children.sort { $0.size > $1.size }

            for (ci, _) in children.prefix(50) {
                let node = nodes[ci]
                let name = tree.name(at: UInt32(ci))
                let typeChar = node.isDirectory ? "/" : ""
                let sizeStr = SizeFormatter.shared.format(node.displaySize)
                let countStr = node.isDirectory ? SizeFormatter.shared.formatCount(Int(node.childCount)) : ""
                print("  \((name + typeChar).padding(toLength: 58, withPad: " ", startingAt: 0)) \(sizeStr.leftPad(12)) \(countStr.leftPad(8))")
            }
        }
    }

    static func printUsage() {
        errPrint("""
        DirWiz CLI — Disk space analyzer

        Usage:
          dirwiz-cli scan <path> [--json] [--min-size <bytes>] [--max-depth <n>] [-q]
          dirwiz-cli duplicates <path> [--min-size <bytes>] [--json] [-q]
          dirwiz-cli info <path> [-q]
          dirwiz-cli benchmark <path> [--iterations <n>] [--json] [-q]

        Commands:
          scan         Scan a directory tree and output results
          duplicates   Find duplicate files
          info         Show space categories, file age, size distribution, and volume info
          benchmark    Repeatedly time scan, duplicates, hardlinks, and insights passes

        Options:
          --json       Output structured JSON to stdout
          --min-size   Minimum file size in bytes (default: 0 for scan, 1MB for duplicates)
          --max-depth  Maximum directory depth for JSON export
          --iterations Number of benchmark iterations (default: 3)
          -q, --quiet  Suppress progress messages on stderr
          -h, --help   Show this help
        """)
    }

    static func parseUInt64Flag(_ flag: String, from args: [String]) -> UInt64? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return UInt64(args[idx + 1])
    }

    static func parseInt(_ flag: String, from args: [String]) -> Int? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return Int(args[idx + 1])
    }

    static func errPrint(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        if count >= width { return self }
        return String(repeating: " ", count: width - count) + self
    }
}
