import SwiftUI
import AppKit

/// One column's geometry contract for a resizable table.
struct ColumnSpec {
    let id: String            // stable, storage-safe ("size", "modified", …)
    let defaultWidth: CGFloat // ignored for flexible columns
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let isFlexible: Bool      // exactly one per table: fills remaining space
}

/// Observable per-table column widths with `UserDefaults` persistence.
///
/// Widths are stored as a single JSON dictionary (`[id: Double]`) under `storageKey`.
/// Unknown ids, corrupt data, and non-finite/non-positive values are ignored on load —
/// callers always get a valid, clamped width back, never a crash or NaN.
@MainActor
@Observable
final class ColumnWidthsStore {
    private let specs: [String: ColumnSpec]
    private let storageKey: String
    private let defaults: UserDefaults
    private var overrides: [String: CGFloat] = [:]

    /// Bumped on every `setWidth`/`reset`/`resetAll` — cheap invalidation hook for
    /// views that don't otherwise read a per-column width directly.
    private(set) var revision: Int = 0

    init(specs: [ColumnSpec], storageKey: String, defaults: UserDefaults = .standard) {
        self.specs = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
        self.storageKey = storageKey
        self.defaults = defaults
        load()
    }

    /// Current width for `id`, clamped to its spec. Spec default if never overridden;
    /// a safe fallback (100) if `id` isn't a known column.
    func width(for id: String) -> CGFloat {
        guard let spec = specs[id] else { return 100 }
        guard let stored = overrides[id] else { return spec.defaultWidth }
        return clamp(stored, spec: spec)
    }

    /// Clamps to `[minWidth, maxWidth]` and persists. No-op for unknown or flexible
    /// columns (the flexible column's width is derived from layout, not stored).
    func setWidth(_ width: CGFloat, for id: String) {
        guard let spec = specs[id], !spec.isFlexible else { return }
        overrides[id] = clamp(width, spec: spec)
        persist()
        revision += 1
    }

    /// Restores `id` to its spec default and persists the removal.
    func reset(_ id: String) {
        guard specs[id] != nil else { return }
        overrides.removeValue(forKey: id)
        persist()
        revision += 1
    }

    /// Restores every column to its spec default and persists the removal.
    func resetAll() {
        overrides.removeAll()
        persist()
        revision += 1
    }

    private func clamp(_ width: CGFloat, spec: ColumnSpec) -> CGFloat {
        guard width.isFinite else { return spec.defaultWidth }
        return min(max(width, spec.minWidth), spec.maxWidth)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        for (id, value) in raw {
            guard let spec = specs[id], value.isFinite, value > 0 else { continue }
            overrides[id] = clamp(CGFloat(value), spec: spec)
        }
    }

    private func persist() {
        let raw = overrides.reduce(into: [String: Double]()) { acc, entry in
            acc[entry.key] = Double(entry.value)
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Invisible hit strip straddling a column boundary. Shows a hairline on hover,
/// switches the cursor to a resize cursor, drags to resize, and double-click resets
/// the controlled column.
///
/// Attach as an `.overlay(alignment: .leading)` on the column to the *right* of the
/// boundary, offset by `-Self.hitWidth / 2`, so the strip is centered on the boundary
/// and painted as part of that (later-drawn) column's subtree — this keeps it on top
/// of its left neighbor for the overlapping half without perturbing either column's
/// layout width, which is what preserves header/row alignment.
struct ColumnResizeHandle: View {
    let store: ColumnWidthsStore
    let controls: String        // column id this handle resizes
    let direction: CGFloat      // +1: dragging right widens; -1: dragging right narrows

    static let hitWidth: CGFloat = 9

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat?
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Self.hitWidth)
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle()
                    .fill(Color.secondary.opacity(isHovering || isDragging ? 0.4 : 0))
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                syncCursor()
            }
            .highPriorityGesture(
                TapGesture(count: 2).onEnded {
                    store.reset(controls)
                }
            )
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = store.width(for: controls)
                            isDragging = true
                            syncCursor()
                        }
                        let start = dragStartWidth ?? store.width(for: controls)
                        store.setWidth(start + direction * value.translation.width, for: controls)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        isDragging = false
                        syncCursor()
                    }
            )
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
    }

    /// Keeps the resize cursor pushed for as long as we're hovering OR dragging, and
    /// guards against unbalanced push/pop — NSCursor's stack corrupts otherwise.
    private func syncCursor() {
        let shouldShow = isHovering || isDragging
        if shouldShow, !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !shouldShow, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

extension View {
    /// Attaches a `ColumnResizeHandle` for the boundary immediately to this view's
    /// leading edge — call on the column to the *right* of the boundary (see
    /// `ColumnResizeHandle`'s doc comment for why: it keeps the handle painted on top
    /// of its left neighbor without adding layout width to either column).
    func resizeHandle(store: ColumnWidthsStore, controls: String, direction: CGFloat) -> some View {
        overlay(alignment: .leading) {
            ColumnResizeHandle(store: store, controls: controls, direction: direction)
                .offset(x: -ColumnResizeHandle.hitWidth / 2)
        }
    }
}
