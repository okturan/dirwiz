import SwiftUI

/// Tab view for finding and managing duplicate files.
public struct DuplicateFilesView: View {
    @Bindable var appState: AppState

    @State private var minimumSizeFilter: UInt64 = 1_048_576 // 1 MB default
    @State private var showTrashConfirmation: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if appState.isDuplicateScanRunning {
                duplicateScanProgress
            } else if filteredGroups.isEmpty {
                emptyState
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
            .disabled(appState.fileTree == nil || appState.isDuplicateScanRunning)

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

            if !appState.duplicateCheckedPaths.isEmpty {
                Button(action: { showTrashConfirmation = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Move to Trash (\(appState.duplicateCheckedPaths.count))")
                    }
                }
                .foregroundStyle(.red)
                .alert("Move to Trash?", isPresented: $showTrashConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Move to Trash", role: .destructive) {
                        moveCheckedToTrash()
                    }
                } message: {
                    Text("Move \(appState.duplicateCheckedPaths.count) selected files to the Trash? This cannot be undone easily.")
                }
            }

            if !appState.duplicateGroups.isEmpty {
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
            if appState.duplicateProgress.total > 0 {
                Text("\(SizeFormatter.shared.formatCount(appState.duplicateProgress.processed)) / \(SizeFormatter.shared.formatCount(appState.duplicateProgress.total)) candidates")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProgressView(
                    value: Double(appState.duplicateProgress.processed),
                    total: Double(max(appState.duplicateProgress.total, 1))
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
            if appState.duplicateGroups.isEmpty {
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
                        isExpanded: appState.duplicateExpandedGroups.contains(group.id),
                        checkedPaths: $appState.duplicateCheckedPaths,
                        onToggleExpand: {
                            if appState.duplicateExpandedGroups.contains(group.id) {
                                appState.duplicateExpandedGroups.remove(group.id)
                            } else {
                                appState.duplicateExpandedGroups.insert(group.id)
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
        appState.duplicateGroups.filter { $0.fileSize >= minimumSizeFilter }
    }

    private var totalWastedSpace: UInt64 {
        filteredGroups.reduce(0) { $0 + $1.wastedSpace }
    }

    // MARK: - Actions

    private func startDuplicateScan() {
        guard let tree = appState.fileTree else { return }
        appState.isDuplicateScanRunning = true
        appState.duplicateCheckedPaths.removeAll()
        appState.duplicateExpandedGroups.removeAll()
        appState.duplicateProgress = (0, 0)

        Task {
            let finder = DuplicateFinder()
            let groups = await finder.findDuplicates(in: tree) { processed, total in
                Task { @MainActor in
                    appState.duplicateProgress = (processed, total)
                }
            }
            await MainActor.run {
                appState.duplicateGroups = groups
                appState.isDuplicateScanRunning = false
            }
        }
    }

    private func moveCheckedToTrash() {
        for path in appState.duplicateCheckedPaths {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        // Remove trashed paths from the duplicate groups.
        let trashed = appState.duplicateCheckedPaths
        appState.duplicateGroups = appState.duplicateGroups.compactMap { group in
            let remaining = group.paths.filter { !trashed.contains($0) }
            guard remaining.count >= 2 else { return nil }
            return DuplicateGroup(
                fileSize: group.fileSize,
                hash: group.hash,
                paths: remaining
            )
        }
        appState.duplicateCheckedPaths.removeAll()
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
            Button(action: onToggleExpand) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .frame(width: 12)

                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text("\(group.count) copies")
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.06))
            )

            // Expanded paths.
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
                                            if checkedInGroup < group.count - 1 {
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
}
