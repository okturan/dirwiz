import SwiftUI

/// Remembers which Insights sections the user collapsed, across launches.
///
/// Stores the COLLAPSED ids rather than the expanded ones, so a section added in a future
/// release defaults to expanded without needing a migration: an id nobody has collapsed is
/// simply absent from the set. Storing expanded ids would make every new section arrive
/// collapsed and invisible.
@MainActor
public final class SectionCollapseStore {
    /// The app's store. Tests must construct their own with an isolated `UserDefaults`
    /// rather than touching this one - writing to `.standard` from a test leaks
    /// preferences into the user's real app.
    public static let shared = SectionCollapseStore()

    private let key: String
    private let defaults: UserDefaults
    private var collapsed: Set<String>

    public init(key: String = "DirWizCollapsedInsightSections", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        self.collapsed = Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    public func setCollapsed(_ isCollapsed: Bool, for id: String) {
        if isCollapsed { collapsed.insert(id) } else { collapsed.remove(id) }
        // Sorted so the stored value is stable and diffable rather than set-order noise.
        defaults.set(collapsed.sorted(), forKey: key)
    }

    public func toggle(_ id: String) {
        setCollapsed(!isCollapsed(id), for: id)
    }

    /// Test seam - also used if a future release needs to reset the layout.
    public func removeAll() {
        collapsed.removeAll()
        defaults.removeObject(forKey: key)
    }
}

/// One Insights card: a tappable header with a disclosure chevron, and content that
/// collapses. Card chrome lives here so every section reads the same way, rather than each
/// section styling its own header.
public struct CollapsibleSection<Content: View>: View {
    let id: String
    let title: String
    let icon: String
    /// Optional trailing control in the header (e.g. an Analyze button) - placed so it
    /// stays reachable while the section is collapsed.
    let accessory: AnyView?
    @ViewBuilder let content: () -> Content

    @State private var isCollapsed: Bool
    private let store: SectionCollapseStore

    public init(
        id: String,
        title: String,
        icon: String,
        store: SectionCollapseStore? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.accessory = accessory
        self.content = content
        let resolved = store ?? SectionCollapseStore.shared
        self.store = resolved
        _isCollapsed = State(initialValue: resolved.isCollapsed(id))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                if let accessory {
                    accessory
                }
            }

            if !isCollapsed {
                content()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isCollapsed.toggle()
        }
        store.setCollapsed(isCollapsed, for: id)
    }
}
