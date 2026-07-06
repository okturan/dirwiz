import Foundation
import DirWizCore

/// DirWiz CLI — command-line disk analysis using DirWizCore.
///
/// Usage:
///   dirwiz-cli scan <path> [--json] [--min-size <bytes>] [--max-depth <n>]
///   dirwiz-cli duplicates <path> [--min-size <bytes>] [--json]
///   dirwiz-cli info <path>
///   dirwiz-cli snapshot <path> [--json]
///   dirwiz-cli diff <path> [--json]
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
        case "snapshot":
            await handleSnapshot(args: remainingArgs)
        case "diff":
            await handleDiff(args: remainingArgs)
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
        let parsed = CLIArguments(args)
        guard let path = parsed.path else {
            errPrint("Error: scan requires a path argument")
            exit(1)
        }

        let outputJSON = parsed.has("--json")
        let minSize = parsed.uint64("--min-size") ?? 0
        let maxDepth = parsed.int("--max-depth")
        let quiet = parsed.has("--quiet") || parsed.has("-q")

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
        let parsed = CLIArguments(args)
        guard let path = parsed.path else {
            errPrint("Error: duplicates requires a path argument")
            exit(1)
        }

        let outputJSON = parsed.has("--json")
        let minSize = parsed.uint64("--min-size") ?? 1_048_576
        let quiet = parsed.has("--quiet") || parsed.has("-q")

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()

        if !quiet { errPrint("Scanning \(path)...") }
        await scanner.scan(path: path, progress: progress, tree: tree)
        if !quiet { errPrint("Scanning for duplicates...") }

        let finder = DuplicateFinder(minimumFileSize: minSize)
        let groups = await finder.findDuplicates(in: tree)
        let filtered = groups

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
                    print("  \(sanitizeForTerminal(path))")
                }
                print()
            }
            print("Total wasted: \(SizeFormatter.shared.format(totalWasted))")
        }
    }

    // MARK: - Info Command

    static func handleInfo(args: [String]) async {
        let parsed = CLIArguments(args)
        guard let path = parsed.path else {
            errPrint("Error: info requires a path argument")
            exit(1)
        }

        let quiet = parsed.has("--quiet") || parsed.has("-q")

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

    // MARK: - Snapshot Command

    static func handleSnapshot(args: [String]) async {
        let parsed = CLIArguments(args)
        guard let path = parsed.path else {
            errPrint("Error: snapshot requires a path argument")
            exit(1)
        }

        let outputJSON = parsed.has("--json")
        let quiet = parsed.has("--quiet") || parsed.has("-q")

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()

        if !quiet { errPrint("Scanning \(path)...") }
        await scanner.scan(path: path, progress: progress, tree: tree)

        let snap = await TemporalDiffService.buildSnapshot(tree: tree)
        do {
            try snap.save()
        } catch {
            errPrint("Error saving snapshot: \(error.localizedDescription)")
            exit(1)
        }

        let savedURL = TemporalSnapshot.snapshotURL(for: snap.meta.rootPath)

        if outputJSON {
            let jsonObject: [String: Any] = [
                "rootPath": snap.meta.rootPath,
                "dirCount": snap.meta.dirCount,
                "totalBytes": snap.meta.totalBytes,
                "createdAt": ISO8601DateFormatter().string(from: snap.meta.createdAt),
                "snapshotFile": savedURL.path,
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
                if let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } catch {
                errPrint("Error encoding JSON: \(error.localizedDescription)")
                exit(1)
            }
        } else {
            print("Root:      \(sanitizeForTerminal(snap.meta.rootPath))")
            print("Dirs:      \(SizeFormatter.shared.formatCount(snap.meta.dirCount))")
            print("Size:      \(SizeFormatter.shared.format(snap.meta.totalBytes))")
            print("Saved to:  \(sanitizeForTerminal(savedURL.path))")
        }
    }

    // MARK: - Diff Command

    static func handleDiff(args: [String]) async {
        let parsed = CLIArguments(args)
        guard let path = parsed.path else {
            errPrint("Error: diff requires a path argument")
            exit(1)
        }

        let outputJSON = parsed.has("--json")
        let quiet = parsed.has("--quiet") || parsed.has("-q")

        let snap: TemporalSnapshot
        do {
            guard let loaded = try TemporalSnapshot.load(for: path) else {
                errPrint("No snapshot found for \(sanitizeForTerminal(path)). Run 'dirwiz-cli snapshot \(sanitizeForTerminal(path))' first.")
                exit(1)
            }
            snap = loaded
        } catch {
            errPrint("Error loading snapshot: \(error.localizedDescription)")
            exit(1)
        }

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()

        if !quiet { errPrint("Scanning \(path)...") }
        await scanner.scan(path: path, progress: progress, tree: tree)

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snap)
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()
        let summary = TemporalDiffSummary.summarize(
            result: result, nodes: nodes, stringPool: stringPool, rootPath: rootPath
        )

        let currentTotal = nodes.first?.fileSize ?? 0
        let snapshotTotal = snap.meta.totalBytes
        let grew = currentTotal >= snapshotTotal
        let delta = grew ? currentTotal - snapshotTotal : snapshotTotal - currentTotal

        if outputJSON {
            printDiffJSON(summary: summary, snapshot: snap, currentTotal: currentTotal, grew: grew, delta: delta)
        } else {
            printDiffReport(summary: summary, snapshot: snap, currentTotal: currentTotal, grew: grew, delta: delta)
        }
    }

    private static func printDiffReport(
        summary: TemporalDiffSummary,
        snapshot: TemporalSnapshot,
        currentTotal: UInt64,
        grew: Bool,
        delta: UInt64
    ) {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let relative = RelativeDateTimeFormatter().localizedString(for: snapshot.meta.createdAt, relativeTo: Date())

        print("Root:      \(sanitizeForTerminal(snapshot.meta.rootPath))")
        print("Snapshot:  \(df.string(from: snapshot.meta.createdAt)) (\(relative))")
        print("Size now:  \(SizeFormatter.shared.format(currentTotal)) (\(grew ? "+" : "-")\(SizeFormatter.shared.format(delta)) since snapshot)")
        print()
        print("Changes:   \(summary.newCount) new, \(summary.grownCount) grown, \(summary.shrunkCount) shrunk, \(summary.lostDescendantsCount) lost descendants")

        guard !summary.topChanged.isEmpty else {
            print()
            print("No significant changes detected.")
            return
        }

        print()
        print("Top changed directories:")
        for entry in summary.topChanged {
            let label = kindLabel(entry.kind).padding(toLength: 10, withPad: " ", startingAt: 0)
            let size = SizeFormatter.shared.format(entry.currentSize).leftPad(12)
            print("  \(label) \(size)  \(sanitizeForTerminal(entry.path))")
        }
    }

    private static func printDiffJSON(
        summary: TemporalDiffSummary,
        snapshot: TemporalSnapshot,
        currentTotal: UInt64,
        grew: Bool,
        delta: UInt64
    ) {
        let jsonObject: [String: Any] = [
            "rootPath": snapshot.meta.rootPath,
            "snapshotCreatedAt": ISO8601DateFormatter().string(from: snapshot.meta.createdAt),
            "currentTotalBytes": currentTotal,
            "snapshotTotalBytes": snapshot.meta.totalBytes,
            "totalBytesGrew": grew,
            "totalBytesDelta": delta,
            "counts": [
                "new": summary.newCount,
                "grown": summary.grownCount,
                "shrunk": summary.shrunkCount,
                "lostDescendants": summary.lostDescendantsCount,
            ],
            "topChanged": summary.topChanged.map { entry -> [String: Any] in
                [
                    "path": entry.path,
                    "kind": kindLabel(entry.kind),
                    "currentSize": entry.currentSize,
                ]
            },
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } catch {
            errPrint("Error encoding JSON: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func kindLabel(_ kind: TemporalDiffKind) -> String {
        switch kind {
        case .none: return "none"
        case .new: return "new"
        case .grown: return "grown"
        case .shrunk: return "shrunk"
        case .deletedDescendants: return "lost-desc"
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
                let name = sanitizeForTerminal(tree.name(at: UInt32(ci)))
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
          dirwiz-cli snapshot <path> [--json] [-q]
          dirwiz-cli diff <path> [--json] [-q]
          dirwiz-cli benchmark <path> [--iterations <n>] [--json] [-q]

        Commands:
          scan         Scan a directory tree and output results
          duplicates   Find duplicate files
          info         Show space categories, file age, size distribution, and volume info
          snapshot     Save a baseline snapshot of a directory tree for later comparison
          diff         Compare current directory state against a saved snapshot
          benchmark    Repeatedly time scan, duplicates, hardlinks, and insights passes

        Options:
          --json       Output structured JSON to stdout
          --min-size   Minimum file size in bytes (default: 0 for scan, 1MB for duplicates)
          --max-depth  Maximum directory depth for JSON export
          --iterations Number of benchmark iterations (default: 3)
          -q, --quiet  Suppress progress messages on stderr
          -h, --help   Show this help

        Notes:
          snapshot/diff key the saved snapshot by the exact path string you pass —
          use the same spelling (e.g. always without a trailing slash) for both
          commands, or diff will report "no snapshot found" even though one exists.
        """)
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
