import Quartz

/// Hosts the QLPreviewPanel data source / controller for the application.
/// Stored on AppState so any view can call openQuickLook() / closeQuickLook().
public final class QLPreviewCoordinator: NSObject, QLPreviewPanelDataSource {

    /// The file-system path to preview. Set this before calling openQuickLook().
    public var previewPath: String?

    // MARK: - Public API

    /// Open (or refresh) the Quick Look panel for the current previewPath.
    @MainActor
    public func openQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.reloadData()
        } else {
            panel.dataSource = self
            panel.delegate = nil
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Toggle: if the panel is visible, close it; otherwise open it.
    @MainActor
    public func toggleQuickLook(for path: String?) {
        guard let path, !path.isEmpty else { return }
        previewPath = path
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            openQuickLook()
        }
    }

    // MARK: - QLPreviewPanelDataSource

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewPath != nil ? 1 : 0
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let path = previewPath else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

}
