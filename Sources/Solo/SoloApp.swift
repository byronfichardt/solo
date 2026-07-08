import SwiftUI
import AppKit

/// Resolve the starting directory: argv[1] if it's a directory, otherwise the
/// folder Solo was last left in, otherwise home.
@MainActor
func resolveStartDirectory() -> URL {
    let fm = FileManager.default
    func existingDir(_ url: URL) -> URL? {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            ? url.standardizedFileURL : nil
    }
    // An explicit path argument wins; if it's invalid, fall to home (a predictable
    // default) rather than silently reopening the last folder and masking the typo.
    let args = CommandLine.arguments
    if args.count > 1 {
        return existingDir(URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath))
            ?? fm.homeDirectoryForCurrentUser
    }
    // No argument: reopen wherever Solo was last left.
    if let last = DirectoryModel.lastDirectory, let dir = existingDir(last) {
        return dir
    }
    return fm.homeDirectoryForCurrentUser
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var model: DirectoryModel!
    private weak var showHiddenMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let dirModel = DirectoryModel(start: resolveStartDirectory())
        model = dirModel
        setupMenu()

        let root = ContentView(model: dirModel)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Solo"
        window.minSize = NSSize(width: 520, height: 360)
        window.contentView = NSHostingView(rootView: root)
        window.setFrameAutosaveName("SoloMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Re-clicking the dock icon with no window re-opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Solo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Note: no ⌘H Hide item — Solo uses ⌘H for "go to home folder".
        appMenu.addItem(withTitle: "Quit Solo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // View menu
        // ⌘. is the macOS system "Cancel" shortcut, so SwiftUI's .onKeyPress never
        // receives it. Binding it as a menu key-equivalent dispatches via
        // performKeyEquivalent: instead, which fires reliably.
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let hiddenItem = NSMenuItem(title: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: ".")
        hiddenItem.target = self
        hiddenItem.state = model.showHidden ? .on : .off
        viewMenu.addItem(hiddenItem)
        showHiddenMenuItem = hiddenItem
        viewMenuItem.submenu = viewMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleHiddenFiles(_ sender: NSMenuItem) {
        model.toggleHidden()
        sender.state = model.showHidden ? .on : .off
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
