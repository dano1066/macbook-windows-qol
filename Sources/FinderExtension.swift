import Cocoa
import FinderSync

@objc(WindowsQoLFinderExtension)
final class WindowsQoLFinderExtension: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer,
              FIFinderSyncController.default().targetedURL()?.isFileURL == true else { return nil }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Open Terminal Here", action: #selector(openTerminal(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = FIFinderSyncController.default().targetedURL()
        menu.addItem(item)
        return menu
    }
    @objc func openTerminal(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error { NSLog("Could not open Terminal: %@", error.localizedDescription) }
        }
    }
}
