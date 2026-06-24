import Foundation
import SwiftUI
import AppKit

enum SortKey: String, CaseIterable {
    case name = "Name"
    case size = "Size"
    case modified = "Date"
    case ext = "Type"
}

@MainActor
final class DirectoryModel: ObservableObject {
    @Published private(set) var url: URL
    @Published private(set) var items: [FileItem] = []
    @Published var selection: Int = 0
    @Published var showHidden = false
    @Published var sortKey: SortKey = .name
    @Published var sortAsc = true
    @Published var filter: String = ""
    @Published var filtering = false
    @Published private(set) var status: String = ""

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    /// Remember the selected name per directory so going back restores the cursor.
    private var lastSelectedName: [URL: String] = [:]

    init(start: URL) {
        self.url = start
        load()
    }

    // MARK: Derived

    var visibleItems: [FileItem] {
        guard !filter.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var selectedItem: FileItem? {
        let v = visibleItems
        guard v.indices.contains(selection) else { return nil }
        return v[selection]
    }

    var pathComponents: [(name: String, url: URL)] {
        var result: [(String, URL)] = []
        var u = url.standardizedFileURL
        // Cap iterations as a safety net — deletingLastPathComponent() on "/"
        // returns "/.." (not "/"), so we must break explicitly at root.
        for _ in 0..<128 {
            let path = u.path
            let name = path == "/" ? "/" : u.lastPathComponent
            result.append((name, u))
            if path == "/" { break }
            let parent = u.deletingLastPathComponent().standardizedFileURL
            if parent.path == path { break }
            u = parent
        }
        return result.reversed()
    }

    // MARK: Loading

    func load() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .isSymbolicLinkKey, .isPackageKey,
            .localizedNameKey, .isHiddenKey
        ]
        var opts: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { opts.insert(.skipsHiddenFiles) }
        do {
            let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: opts)
            items = contents.map(FileItem.init).sorted(by: comparator)
            clampSelection()
            updateStatus()
        } catch {
            items = []
            clampSelection()
            status = "Cannot open folder: \(error.localizedDescription)"
        }
    }

    private var comparator: (FileItem, FileItem) -> Bool {
        let asc = sortAsc
        let key = sortKey
        return { a, b in
            // Directories always float to the top.
            if a.isDir != b.isDir { return a.isDir }
            let result: Bool
            switch key {
            case .name:
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                result = a.size < b.size
            case .modified:
                result = a.modified < b.modified
            case .ext:
                let cmp = a.ext.localizedStandardCompare(b.ext)
                result = cmp == .orderedSame
                    ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                    : cmp == .orderedAscending
            }
            return asc ? result : !result
        }
    }

    // MARK: Navigation

    func navigate(to dest: URL, recordBack: Bool = true, remember: URL? = nil) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue else {
            status = "Not a directory"; return
        }
        if let cur = selectedItem { lastSelectedName[url] = cur.name }
        if recordBack {
            backStack.append(url)
            forwardStack.removeAll()
        }
        url = dest.standardizedFileURL
        filter = ""; filtering = false
        load()
        restoreSelection(preferName: remember.map { _ in nil } ?? lastSelectedName[url])
    }

    private func restoreSelection(preferName: String?) {
        guard let name = preferName,
              let idx = visibleItems.firstIndex(where: { $0.name == name }) else {
            selection = 0; return
        }
        selection = idx
    }

    func openSelected() {
        guard let item = selectedItem else { return }
        if item.isDir {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func goUp() {
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return }
        let cameFrom = url.lastPathComponent
        navigate(to: parent)
        // Land the cursor on the folder we just came out of.
        if let idx = visibleItems.firstIndex(where: { $0.name == cameFrom }) {
            selection = idx
        }
    }

    func goBack() {
        guard let dest = backStack.popLast() else { status = "No back history"; return }
        forwardStack.append(url)
        navigate(to: dest, recordBack: false)
    }

    func goForward() {
        guard let dest = forwardStack.popLast() else { status = "No forward history"; return }
        backStack.append(url)
        navigate(to: dest, recordBack: false)
    }

    func goHome() { navigate(to: FileManager.default.homeDirectoryForCurrentUser) }

    // MARK: Cursor movement

    func moveSelection(by delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { selection = 0; return }
        selection = min(max(0, selection + delta), count - 1)
        updateStatus()
    }

    func selectFirst() { selection = 0; updateStatus() }
    func selectLast() { selection = max(0, visibleItems.count - 1); updateStatus() }

    private func clampSelection() {
        let count = visibleItems.count
        selection = count == 0 ? 0 : min(selection, count - 1)
    }

    // MARK: Options

    func toggleHidden() {
        showHidden.toggle()
        let keepName = selectedItem?.name
        load()
        if let n = keepName, let idx = visibleItems.firstIndex(where: { $0.name == n }) {
            selection = idx
        }
        status = showHidden ? "Showing hidden files" : "Hiding hidden files"
    }

    func cycleSort() {
        let all = SortKey.allCases
        if let i = all.firstIndex(of: sortKey) {
            sortKey = all[(i + 1) % all.count]
        }
        reapplySort()
        status = "Sorted by \(sortKey.rawValue) \(sortAsc ? "↑" : "↓")"
    }

    func setSort(_ key: SortKey) {
        if sortKey == key { sortAsc.toggle() } else { sortKey = key; sortAsc = true }
        reapplySort()
    }

    func toggleSortDirection() {
        sortAsc.toggle()
        reapplySort()
        status = "Sorted by \(sortKey.rawValue) \(sortAsc ? "↑" : "↓")"
    }

    private func reapplySort() {
        let keepName = selectedItem?.name
        items.sort(by: comparator)
        if let n = keepName, let idx = visibleItems.firstIndex(where: { $0.name == n }) {
            selection = idx
        }
    }

    func refresh() {
        let keepName = selectedItem?.name
        load()
        if let n = keepName, let idx = visibleItems.firstIndex(where: { $0.name == n }) {
            selection = idx
        }
        status = "Refreshed"
    }

    // MARK: Filter

    func appendToFilter(_ s: String) {
        filtering = true
        filter += s
        clampSelection()
        updateStatus()
    }

    func backspaceFilter() {
        if !filter.isEmpty { filter.removeLast() }
        if filter.isEmpty { filtering = false }
        clampSelection()
        updateStatus()
    }

    func clearFilter() {
        filter = ""; filtering = false
        clampSelection()
        updateStatus()
    }

    // MARK: File operations

    func trashSelected() {
        guard let item = selectedItem else { return }
        let idx = selection
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            refresh()
            selection = min(idx, max(0, visibleItems.count - 1))
            status = "Moved “\(item.name)” to Trash"
        } catch {
            status = "Trash failed: \(error.localizedDescription)"
        }
    }

    func renameSelected() {
        guard let item = selectedItem else { return }
        guard let newName = Prompt.text(title: "Rename", message: "New name:", defaultValue: item.name),
              !newName.isEmpty, newName != item.name else { return }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            refresh()
            if let idx = visibleItems.firstIndex(where: { $0.name == newName }) { selection = idx }
            status = "Renamed to “\(newName)”"
        } catch {
            status = "Rename failed: \(error.localizedDescription)"
        }
    }

    func newFolder() {
        guard let name = Prompt.text(title: "New Folder", message: "Folder name:", defaultValue: "untitled folder"),
              !name.isEmpty else { return }
        let dest = url.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            refresh()
            if let idx = visibleItems.firstIndex(where: { $0.name == name }) { selection = idx }
            status = "Created folder “\(name)”"
        } catch {
            status = "Create failed: \(error.localizedDescription)"
        }
    }

    func revealInFinder() {
        let target = selectedItem?.url ?? url
        NSWorkspace.shared.activateFileViewerSelecting([target])
        status = "Revealed in Finder"
    }

    func openTerminalHere() {
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
        status = "Opened Terminal here"
    }

    func copyPathToPasteboard() {
        let target = selectedItem?.url.path ?? url.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target, forType: .string)
        status = "Copied path"
    }

    func goToPathPrompt() {
        guard let path = Prompt.text(title: "Go to Folder", message: "Path:", defaultValue: url.path) else { return }
        let expanded = (path as NSString).expandingTildeInPath
        navigate(to: URL(fileURLWithPath: expanded))
    }

    // MARK: Status

    private func updateStatus() {
        let total = items.count
        let shown = visibleItems.count
        var s = ""
        if !filter.isEmpty {
            s = "Filter “\(filter)” — \(shown)/\(total)"
        } else {
            let dirs = items.filter(\.isDir).count
            s = "\(total) items · \(dirs) folders · \(total - dirs) files"
        }
        if let sel = selectedItem {
            s += "    ·    \(sel.name)"
        }
        status = s
    }
}
