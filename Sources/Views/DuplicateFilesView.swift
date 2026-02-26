import SwiftUI

/// Tab view for finding and managing duplicate files.
public struct DuplicateFilesView: View {
    @Bindable var appState: AppState

    @State private var minimumSizeFilter: UInt64 = 1_048_576 // 1 MB default
    @State private var showTrashConfirmation: Bool = false
    @State private var trashErrorPaths: [String] = []

    public init(appState: AppState) {
        self.appState = appState
    }

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
            .disabled(appState.fileTree == nil || appState.duplicate.isDuplicateScanRunning)

            Divider()
                .frame(height: 20)

            HStack(spacing: 4) {
                Text("Min size:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("", selection: $minimumSizeFilter) {
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
                    Text("\(trashErrorPaths.count) file(s) couldn't be moved to Trash — they may have been deleted already or require additional permissions.\n\n\(trashErrorPaths.prefix(3).joined(separator: "\n"))\(trashErrorPaths.count > 3 ? "\n…" : "")")
                }
            }

            if !appState.duplicate.duplicateGroups.isEmpty {
                Text("\(filteredGroups.count) groups")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(SizeFormatter.shared.format(totalWastedSpace))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.orange)
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
            Text("Scanning for duplicates...")
                .font(.headline)
            if appState.duplicate.duplicateProgress.total > 0 {
                Text("\(SizeFormatter.shared.formatCount(appState.duplicate.duplicateProgress.processed)) / \(SizeFormatter.shared.formatCount(appState.duplicate.duplicateProgress.total)) candidates")
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
                Text("No duplicate groups match the current minimum size filter.")
            }
        }
    }

    // MARK: - Duplicate List

    private var duplicateList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredGroups) { group in
                    DuplicateGroupRow(
                        group: group,
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
        appState.duplicate.duplicateGroups.filter { $0.fileSize >= minimumSizeFilter }
    }

    private var totalWastedSpace: UInt64 {
        filteredGroups.reduce(0) { $0 + $1.wastedSpace }
    }

    // MARK: - Actions

    private func startDuplicateScan() {
        guard let tree = appState.fileTree else { return }
        appState.duplicate.isDuplicateScanRunning = true
        appState.duplicate.duplicateCheckedPaths.removeAll()
        appState.duplicate.duplicateExpandedGroups.removeAll()
        appState.duplicate.duplicateProgress = (0, 0)

        Task {
            let finder = DuplicateFinder()
            let groups = await finder.findDuplicates(in: tree) { processed, total in
                Task { @MainActor in
                    // Ensure progress only goes up (tasks complete out of order).
                    let clamped = max(appState.duplicate.duplicateProgress.processed, processed)
                    appState.duplicate.duplicateProgress = (clamped, total)
                }
            }
            await MainActor.run {
                appState.duplicate.duplicateGroups = groups
                appState.duplicate.isDuplicateScanRunning = false
            }
        }
    }

    private func moveCheckedToTrash() {
        var trashed: Set<String> = []
        var failed: [String] = []
        for path in appState.duplicate.duplicateCheckedPaths {
            let url = URL(fileURLWithPath: path)
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                trashed.insert(path)
            } else {
                failed.append(path)
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
        // Rescan to keep tree/treemap data consistent with filesystem.
        appState.rescanVolume()
    }
}

// MARK: - DuplicateGroupRow

private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
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
