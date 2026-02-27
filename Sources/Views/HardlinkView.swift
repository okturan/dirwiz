import SwiftUI

/// Tab view for detecting and inspecting hardlinked file groups.
///
/// Hardlinks are multiple directory entries pointing to the same inode (file data).
/// Unlike duplicates, removing a hardlink does NOT free disk space until the *last*
/// link is removed — the data lives on as long as any directory entry references it.
/// This view is informational: it shows which files share inodes and how much space
/// is held by the extra links, but does not offer a "trash" action to avoid confusion.
public struct HardlinkView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if appState.isHardlinkScanRunning {
                scanProgress
            } else if appState.hardlinkGroups.isEmpty {
                emptyState
                    .frame(maxHeight: .infinity)
            } else {
                hardlinkList
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: startHardlinkScan) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("Scan for Hardlinks")
                }
            }
            .disabled(appState.fileTree == nil || appState.isHardlinkScanRunning)

            Spacer()

            if !appState.hardlinkGroups.isEmpty {
                Text("\(appState.hardlinkGroups.count) groups")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(SizeFormatter.shared.format(totalExtraLinkBytes))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Progress

    private var scanProgress: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Scanning for hardlinks...")
                .font(.headline)
            Text("Calling lstat on each file to detect shared inodes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Hardlinks Found", systemImage: "link")
        } description: {
            if appState.hardlinkGroups.isEmpty && !appState.isHardlinkScanRunning {
                Text("Click \"Scan for Hardlinks\" to search for files sharing the same inode.\n\nHardlinks are multiple directory entries pointing to identical file data. Removing a hardlink only unlinks one directory entry — the data is freed only when the last link is removed.")
            }
        }
    }

    // MARK: - Hardlink List

    private var hardlinkList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(appState.hardlinkGroups) { group in
                    HardlinkGroupRow(
                        group: group,
                        isExpanded: appState.hardlinkExpandedGroups.contains(group.id),
                        onToggleExpand: {
                            if appState.hardlinkExpandedGroups.contains(group.id) {
                                appState.hardlinkExpandedGroups.remove(group.id)
                            } else {
                                appState.hardlinkExpandedGroups.insert(group.id)
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

    private var totalExtraLinkBytes: UInt64 {
        appState.hardlinkGroups.reduce(0) { $0 + $1.extraLinkBytes }
    }

    // MARK: - Actions

    private func startHardlinkScan() {
        guard let tree = appState.fileTree else { return }
        appState.hardlinkTask?.cancel()
        appState.hardlinkToken &+= 1
        let token = appState.hardlinkToken
        appState.isHardlinkScanRunning = true
        appState.hardlinkExpandedGroups.removeAll()

        appState.hardlinkTask = Task {
            let finder = HardlinkFinder()
            let groups = await finder.findHardlinks(in: tree)
            await MainActor.run {
                guard appState.hardlinkToken == token else { return }
                appState.hardlinkGroups = groups
                appState.isHardlinkScanRunning = false
            }
        }
    }
}

// MARK: - HardlinkGroupRow

private struct HardlinkGroupRow: View {
    let group: HardlinkGroup
    let isExpanded: Bool
    var onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header.
            Button(action: onToggleExpand) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .frame(width: 12)

                    Image(systemName: "link")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)

                    Text("\(group.paths.count) links")
                        .font(.system(size: 12, weight: .medium))

                    Text("inode \(group.inode)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Text(SizeFormatter.shared.format(group.fileSize) + " each")
                        .font(.system(size: 11, design: .monospaced))

                    Text("Extra link bytes: " + SizeFormatter.shared.format(group.extraLinkBytes))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.blue)
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
