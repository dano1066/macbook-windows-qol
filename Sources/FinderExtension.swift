import Cocoa
import FinderSync

@objc(WindowsQoLFinderExtension)
final class WindowsQoLFinderExtension: FIFinderSync {
    override init() {
        super.init()
        updateVolumes()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }
    @objc private func volumesChanged(_ notification: Notification) { updateVolumes() }
    private func updateVolumes() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? []
        FIFinderSyncController.default().directoryURLs = Set([URL(fileURLWithPath: "/", isDirectory: true)] + volumes)
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForItems else { return nil }
        if menuKind == .contextualMenuForItems {
            let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
            guard selected.count == 1, (try? selected[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Open Terminal Here", action: #selector(openTerminal(_:)), keyEquivalent: "")
        item.target = self
        item.tag = menuKind == .contextualMenuForItems ? 1 : 0
        item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }
    @objc func openTerminal(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        let folder = sender.tag == 1 ? controller.selectedItemURLs()?.first : controller.targetedURL()
        guard let folder = folder, folder.isFileURL else { return }
        var request = URLComponents()
        request.scheme = "windowsqol-terminal"
        request.host = "open"
        request.queryItems = [URLQueryItem(name: "folder", value: folder.path)]
        guard let requestURL = request.url else { return }
        // A string URL avoids asking the sandboxed extension to open the folder.
        // The containing app handles it and launches Terminal outside the sandbox.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.open([requestURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error { NSLog("Could not send Terminal request: %@", error.localizedDescription) }
        }
    }
}
