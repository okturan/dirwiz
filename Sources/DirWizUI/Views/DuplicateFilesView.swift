import SwiftUI
import DirWizCore

/// Tab view for finding and managing duplicate files.
public struct DuplicateFilesView: View {
    @Bindable var appState: AppState

    @State private var scanMinimumSize: UInt64 = 1_048_576 // 1 MB default
    @State private var resultMinimumSize: UInt64 = 1_048_576 // 1 MB default
    @State private var showTrashConfirmation: Bool = false
    @State private var trashErrorPaths: [String] = []

    public init(appState: AppState) {
        self.appState = appState
    }

    private static let duplicateSizeOptions: [UInt64] = [
        1_024,
        102_400,
        1_048_576,
        10_485_760,
        104_857_600,
    ]

    private static let duplicateSizeOptionLabels: [String] = [
        "1K",
        "100K",
        "1M",
        "10M",
        "100M",
    ]

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if appState.duplicate.isDuplicateScanRunning {
                duplicateScanProgress
            } else if filteredGroups.isEmpty {
                emptyState
                    .frame(maxHeight: .infinity)
            } else {
                duplicateList
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: startDuplicateScan) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                    Text("Scan for Duplicates")
                }
            }
            .disabled(!appState.canStartHeavyTask(.duplicateScan))

            Divider()
                .frame(height: 20)

            scanThresholdControl

            HStack(spacing: 4) {
                Text("Show >")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("", selection: $resultMinimumSize) {
                    Text("1 KB").tag(UInt64(1_024))
                    Text("100 KB").tag(UInt64(102_400))
                    Text("1 MB").tag(UInt64(1_048_576))
                    Text("10 MB").tag(UInt64(10_485_760))
                    Text("100 MB").tag(UInt64(104_857_600))
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            Spacer()

            if !appState.duplicate.duplicateCheckedPaths.isEmpty {
                Button(action: { showTrashConfirmation = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Move to Trash (\(appState.duplicate.duplicateCheckedPaths.count))")
                    }
                }
                .foregroundStyle(.red)
                .alert("Move to Trash?", isPresented: $showTrashConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Move to Trash", role: .destructive) {
                        moveCheckedToTrash()
                    }
                } message: {
                    Text("Move \(appState.duplicate.duplicateCheckedPaths.count) selected files to the Trash? This cannot be undone easily.")
                }
                .alert("Couldn't Move Some Files", isPresented: .init(
                    get: { !trashErrorPaths.isEmpty },
                    set: { if !$0 { trashErrorPaths = [] } }
                )) {
                    Button("OK", role: .cancel) { trashErrorPaths = [] }
                } message: {
                    Text("\(trashErrorPaths.count) file(s) couldn't be moved to Trash — they may have changed since the duplicate scan, been deleted already, or require additional permissions.\n\n\(trashErrorPaths.prefix(3).joined(separator: "\n"))\(trashErrorPaths.count > 3 ? "\n…" : "")")
                }
            }

            if !appState.duplicate.duplicateGroups.isEmpty && !appState.isCloneCheckRunning {
                Button(action: { appState.checkClonesForDuplicates() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc.fill")
                        Text("Check Clones")
                    }
                }
                .disabled(!appState.canStartHeavyTask(.cloneCheck))
                .help("Check if duplicates are APFS clones (shared blocks, no real wasted space)")
            }

            if appState.isCloneCheckRunning {
                ProgressView()
                    .controlSize(.small)
            }

            if !appState.duplicate.duplicateGroups.isEmpty {
                let groups = filteredGroups
                let clones = cloneMap
                let total = totalWastedSpace(for: groups)

                Text("\(groups.count) groups")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                let realWasted = realWastedSpace(for: groups, clones: clones)
                if realWasted < total && !appState.cloneResults.isEmpty {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(SizeFormatter.shared.format(realWasted) + " real waste")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.orange)
                        Text(SizeFormatter.shared.format(total) + " naive")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .strikethrough()
                    }
                } else {
                    Text(SizeFormatter.shared.format(total))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            if !appState.duplicate.isDuplicateScanRunning,
               resultMinimumSize < appState.duplicate.lastDuplicateScanMinimumSize {
                Text("Last scan skipped files under \(SizeFormatter.shared.format(appState.duplicate.lastDuplicateScanMinimumSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Progress

    private var duplicateScanProgress: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(appState.duplicate.duplicatePhase.message)
                .font(.headline)
            Text("Scanning files \(scanThresholdDescription(appState.duplicate.lastDuplicateScanMinimumSize))")
                .font(.callout)
                .foregroundStyle(.secondary)
            if appState.duplicate.duplicateProgress.total > 0 {
                Text(
                    "\(SizeFormatter.shared.formatCount(appState.duplicate.duplicateProgress.processed)) / " +
                    "\(SizeFormatter.shared.formatCount(appState.duplicate.duplicateProgress.total)) " +
                    appState.duplicate.duplicatePhase.unitLabel
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProgressView(
                    value: Double(appState.duplicate.duplicateProgress.processed),
                    total: Double(max(appState.duplicate.duplicateProgress.total, 1))
                )
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Duplicates Found", systemImage: "doc.on.doc")
        } description: {
            if appState.duplicate.duplicateGroups.isEmpty {
                Text("Click \"Scan for Duplicates\" to search for duplicate files.")
            } else {
                Text("No duplicate groups match the current result filter.")
            }
        }
    }

    private var scanThresholdControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Scan >")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(SizeFormatter.shared.format(scanMinimumSize))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 64, alignment: .leading)
            }

            Slider(
                value: Binding(
                    get: { Double(scanThresholdIndex(for: scanMinimumSize)) },
                    set: { newValue in
                        scanMinimumSize = Self.duplicateSizeOptions[Int(newValue.rounded())]
                    }
                ),
                in: 0...Double(Self.duplicateSizeOptions.count - 1),
                step: 1
            )
            .frame(width: 130)
            .help("Minimum file size included in the duplicate scan")

            HStack(spacing: 0) {
                ForEach(Array(Self.duplicateSizeOptionLabels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(index == scanThresholdIndex(for: scanMinimumSize) ? .primary : .tertiary)
                        .frame(maxWidth: .infinity, alignment: alignment(for: index))
                }
            }
            .frame(width: 130)
        }
    }

    private func scanThresholdIndex(for value: UInt64) -> Int {
        Self.duplicateSizeOptions.firstIndex(of: value) ?? 0
    }

    private func scanThresholdDescription(_ threshold: UInt64) -> String {
        ">= \(SizeFormatter.shared.format(threshold))"
    }

    private func alignment(for index: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == Self.duplicateSizeOptionLabels.count - 1 { return .trailing }
        return .center
    }

    // MARK: - Duplicate List

    private var duplicateList: some View {
        let groups = filteredGroups // one filter pass
        let clones = cloneMap // one dictionary build
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(groups) { group in
                    DuplicateGroupRow(
                        group: group,
                        cloneResult: clones[group.id],
                        isExpanded: appState.duplicate.duplicateExpandedGroups.contains(group.id),
                        checkedPaths: $appState.duplicate.duplicateCheckedPaths,
                        onToggleExpand: {
                            if appState.duplicate.duplicateExpandedGroups.contains(group.id) {
                                appState.duplicate.duplicateExpandedGroups.remove(group.id)
                            } else {
                                appState.duplicate.duplicateExpandedGroups.insert(group.id)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Computed

    private var filteredGroups: [DuplicateGroup] {
        appState.duplicate.duplicateGroups.filter { $0.fileSize >= resultMinimumSize }
    }

    private var cloneMap: [UUID: CloneCheckResult] {
        Dictionary(uniqueKeysWithValues: appState.cloneResults.map { ($0.group.id, $0) })
    }

    private func totalWastedSpace(for groups: [DuplicateGroup]) -> UInt64 {
        groups.reduce(0) { $0 + $1.wastedSpace }
    }

    /// Wasted space accounting for APFS clones (if clone check has been run).
    private func realWastedSpace(for groups: [DuplicateGroup], clones: [UUID: CloneCheckResult]) -> UInt64 {
        guard !appState.cloneResults.isEmpty else { return totalWastedSpace(for: groups) }
        return groups.reduce(UInt64(0)) { total, group in
            if let check = clones[group.id] {
                return total + check.realWastedSpace
            }
            return total + group.wastedSpace
        }
    }

    // MARK: - Actions

    private func startDuplicateScan() {
        guard let tree = appState.fileTree else { return }
        guard appState.canStartHeavyTask(.duplicateScan) else { return }
        appState.duplicateTask?.cancel()
        appState.duplicateToken &+= 1
        let token = appState.duplicateToken
        appState.duplicate.isDuplicateScanRunning = true
        appState.duplicate.duplicateCheckedPaths.removeAll()
        appState.duplicate.duplicateExpandedGroups.removeAll()
        appState.duplicate.duplicateProgress = (0, 0)
        appState.duplicate.duplicatePhase = .groupingBySize
        appState.duplicate.lastDuplicateScanMinimumSize = scanMinimumSize

        // Task.detached so findDuplicates runs on the cooperative pool, not the main actor.
        // Without this, Pass 1 (building the size-group dictionary over 1M+ nodes) runs on
        // the main thread and freezes the UI until it completes.
        let selectedScanMinimumSize = scanMinimumSize
        appState.duplicateTask = Task.detached(priority: .userInitiated) {
            let finder = DuplicateFinder(minimumFileSize: selectedScanMinimumSize)
            let groups = await finder.findDuplicates(in: tree) { [token] update in
                // Progress callback is @MainActor — hops to main thread automatically.
                guard appState.duplicateToken == token else { return }
                if appState.duplicate.duplicatePhase == update.phase {
                    let clamped = max(appState.duplicate.duplicateProgress.processed, update.processed)
                    appState.duplicate.duplicateProgress = (clamped, update.total)
                } else {
                    appState.duplicate.duplicatePhase = update.phase
                    appState.duplicate.duplicateProgress = (update.processed, update.total)
                }
            }
            await MainActor.run {
                guard appState.duplicateToken == token else { return }
                appState.duplicate.duplicateGroups = groups
                appState.duplicate.isDuplicateScanRunning = false
                appState.duplicateTask = nil
            }
        }
    }

    private func moveCheckedToTrash() {
        var safeToTrash: Set<String> = []
        var failed = appState.duplicate.duplicateCheckedPaths

        for group in appState.duplicate.duplicateGroups {
            let selectedInGroup = Set(group.paths.filter { appState.duplicate.duplicateCheckedPaths.contains($0) })
            guard !selectedInGroup.isEmpty else { continue }

            let safety = DuplicateContentVerifier.trashSafety(for: group, selectedPaths: selectedInGroup)
            safeToTrash.formUnion(safety.safePaths)
            failed.subtract(safety.safePaths)
        }

        Task { @MainActor in
            let batch = await appState.batchTrashPaths(safeToTrash.sorted())
            var trashed: Set<String> = []
            for result in batch.results {
                if result.success {
                    trashed.insert(result.originalPath)
                } else {
                    failed.insert(result.originalPath)
                }
            }

            if !failed.isEmpty {
                trashErrorPaths = failed.sorted()
            }
            guard !trashed.isEmpty else { return }
            // Remove only successfully trashed paths from the duplicate groups.
            appState.duplicate.duplicateGroups = appState.duplicate.duplicateGroups.compactMap { group in
                let remaining = group.paths.filter { !trashed.contains($0) }
                guard remaining.count >= 2 else { return nil }
                return DuplicateGroup(
                    fileSize: group.fileSize,
                    hash: group.hash,
                    paths: remaining
                )
            }
            appState.duplicate.duplicateCheckedPaths.subtract(trashed)
        }
    }
}

// MARK: - DuplicateGroupRow

private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let cloneResult: CloneCheckResult?
    let isExpanded: Bool
    @Binding var checkedPaths: Set<String>
    var onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header.
            HStack(spacing: 0) {
                Button(action: onToggleExpand) {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .frame(width: 12)

                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)

                        Text("\(group.paths.count) copies")
                            .font(.system(size: 12, weight: .medium))

                        Spacer()

                        Text(SizeFormatter.shared.format(group.fileSize) + " each")
                            .font(.system(size: 11, design: .monospaced))

                        Text("Wasted: " + SizeFormatter.shared.format(group.wastedSpace))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.orange)

                        if let cr = cloneResult {
                            let pct = Int((cr.sharingConfidence * 100).rounded())
                            Text(cr.areClones ? "\(pct)% shared" : "Independent")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(cr.areClones ? Color.green.opacity(0.15) : Color.clear)
                                )
                                .foregroundStyle(cr.areClones ? .green : .secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Menu {
                    Button("Keep Newest, Select Others") { selectAllExcept(keepNewest: true) }
                    Button("Keep Oldest, Select Others") { selectAllExcept(keepNewest: false) }
                    Divider()
                    Button("Deselect All in Group") { deselectGroup() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("Quick-select duplicates to remove")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.06))
            )

            // Expanded paths — with per-path modification date label.
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(group.paths.enumerated()), id: \.offset) { index, path in
                        HStack(spacing: 8) {
                            Toggle(
                                isOn: Binding(
                                    get: { checkedPaths.contains(path) },
                                    set: { isChecked in
                                        if isChecked {
                                            // Ensure at least one copy remains unchecked.
                                            let checkedInGroup = group.paths.filter { checkedPaths.contains($0) }.count
                                            if checkedInGroup < group.paths.count - 1 {
                                                checkedPaths.insert(path)
                                            }
                                        } else {
                                            checkedPaths.remove(path)
                                        }
                                    }
                                )
                            ) {
                                EmptyView()
                            }
                            .toggleStyle(.checkbox)

                            Image(systemName: "doc")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)

                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button(action: {
                                let url = URL(fileURLWithPath: path)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .help("Reveal in Finder")
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 4)

                        if index < group.paths.count - 1 {
                            Divider()
                                .padding(.leading, 28)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Quick-select helpers

    /// Check all paths in this group except the one with the newest/oldest modification date.
    private func selectAllExcept(keepNewest: Bool) {
        let dated: [(path: String, date: Date)] = group.paths.map { path in
            let url = URL(fileURLWithPath: path)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            return (path, date)
        }
        let toKeep: String
        if keepNewest {
            toKeep = dated.max(by: { $0.date < $1.date })?.path ?? group.paths[0]
        } else {
            toKeep = dated.min(by: { $0.date < $1.date })?.path ?? group.paths[0]
        }
        for path in group.paths where path != toKeep {
            checkedPaths.insert(path)
        }
    }

    private func deselectGroup() {
        for path in group.paths {
            checkedPaths.remove(path)
        }
    }
}
