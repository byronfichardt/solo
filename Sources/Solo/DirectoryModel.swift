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
    /// The keyboard cursor / range anchor — always a valid index into `visibleItems`.
    @Published var selection: Int = 0
    /// Extra multi-selected rows, keyed by URL so the set survives re-sorting and refresh.
    /// Empty means "plain single selection" and everything falls back to the cursor.
    @Published var markedURLs: Set<URL> = []
    /// Where a shift-range selection is measured from. nil ⇒ use the cursor.
    private var anchorIndex: Int?
    @Published var showHidden = false
    @Published var sortKey: SortKey = .name
    @Published var sortAsc = true
    @Published var filter: String = "" {
        didSet {
            guard filter != oldValue else { return }
            filtering = !filter.isEmpty
            clampSelection()
            pruneMarks()
            anchorIndex = selection
            updateStatus()
        }
    }
    @Published var filtering = false
    @Published private(set) var status: String = ""
    /// True while showing the Spotlight-backed "Recents" listing instead of `url`'s contents.
    @Published private(set) var isRecents = false

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    /// Remember the selected name per directory so going back restores the cursor.
    private var lastSelectedName: [URL: String] = [:]

    /// How far back "Recents" looks, in days.
    static let recentsWindowDays = 30

    private var recentsQuery: NSMetadataQuery?
    private var recentsObserver: NSObjectProtocol?

    init(start: URL) {
        self.url = start
        // Restore the view preferences the user last left the app in.
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Defaults.sortKey), let k = SortKey(rawValue: raw) { sortKey = k }
        if d.object(forKey: Defaults.sortAsc) != nil { sortAsc = d.bool(forKey: Defaults.sortAsc) }
        showHidden = d.bool(forKey: Defaults.showHidden)
        load()
    }

    // MARK: Persistence

    private enum Defaults {
        static let sortKey = "sortKey"
        static let sortAsc = "sortAsc"
        static let showHidden = "showHidden"
        static let lastDir = "lastDir"
    }

    /// The folder Solo should reopen at next launch (nil when none saved yet).
    static var lastDirectory: URL? {
        UserDefaults.standard.string(forKey: Defaults.lastDir).map { URL(fileURLWithPath: $0) }
    }

    /// Persist the current view preferences so the next launch matches this session.
    private func savePreferences() {
        let d = UserDefaults.standard
        d.set(sortKey.rawValue, forKey: Defaults.sortKey)
        d.set(sortAsc, forKey: Defaults.sortAsc)
        d.set(showHidden, forKey: Defaults.showHidden)
        // Don't persist the synthetic Recents location — reopen at a real folder.
        if !isRecents { d.set(url.path, forKey: Defaults.lastDir) }
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

    /// Items an action applies to: the marked set if any, otherwise just the cursor item.
    var selectedItems: [FileItem] {
        if markedURLs.isEmpty { return selectedItem.map { [$0] } ?? [] }
        return visibleItems.filter { markedURLs.contains($0.url) }
    }

    /// How many rows are effectively selected (1 for a plain cursor selection).
    var selectionCount: Int {
        markedURLs.isEmpty ? (selectedItem == nil ? 0 : 1) : markedURLs.count
    }

    /// Whether the row at `idx` is part of the effective selection (for row highlighting).
    func isSelected(_ idx: Int) -> Bool {
        guard visibleItems.indices.contains(idx) else { return false }
        return markedURLs.isEmpty ? idx == selection : markedURLs.contains(visibleItems[idx].url)
    }

    var pathComponents: [(name: String, url: URL)] {
        // In Recents we show a single synthetic crumb; clicking it returns to `url`.
        if isRecents { return [("Recents", url)] }
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
        if isRecents { loadRecents(); return }
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
            pruneMarks()
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

    // MARK: Recents

    /// Enter the Spotlight-backed Recents view (recently created files in the home folder).
    func showRecents() {
        guard !isRecents else { refresh(); return }
        if let cur = selectedItem { lastSelectedName[url] = cur.name }
        backStack.append(url)          // goBack returns to the folder we left
        forwardStack.removeAll()
        isRecents = true
        filter = ""; filtering = false
        selection = 0
        loadRecents()
    }

    /// Leave Recents and show the contents of `url` again.
    private func exitRecents() {
        teardownRecentsQuery()
        isRecents = false
        load()
        restoreSelection(preferName: lastSelectedName[url])
    }

    private func loadRecents() {
        items = []
        status = "Finding recent files…"
        teardownRecentsQuery()

        // Mirror Finder's "Recents": query by LAST-USED date (the file was actually
        // opened), not creation date. This is both far more relevant (only files you
        // touched) and far faster (a much smaller indexed set than "everything
        // created"). We let Spotlight do the sorting so we never sort a huge array.
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        let cutoff = Date().addingTimeInterval(-Double(Self.recentsWindowDays) * 86_400)
        q.predicate = NSPredicate(format: "%K >= %@", NSMetadataItemLastUsedDateKey, cutoff as NSDate)
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        // Only fetch the attributes we read — keeps result objects lightweight.
        q.valueListAttributes = [NSMetadataItemLastUsedDateKey, NSMetadataItemPathKey]
        recentsObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees main-thread delivery, so this hop is safe.
            MainActor.assumeIsolated { self?.recentsGatheringFinished() }
        }
        recentsQuery = q
        q.start()
    }

    private func recentsGatheringFinished() {
        guard isRecents, let q = recentsQuery else { return }
        q.disableUpdates()
        // Results already arrive sorted by last-used date (newest first) from Spotlight.
        // Walk them in order, drop noise, build rows, and stop at the cap — so we only
        // ever construct ~250 FileItems regardless of how big the index is.
        let libraryPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library").standardizedFileURL.path + "/"

        var rows: [FileItem] = []
        rows.reserveCapacity(250)
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            if path.hasPrefix(libraryPrefix) { continue }   // ~/Library noise
            if path.contains("/.") { continue }             // hidden files & dot-dirs (.git, .Trash…)
            let fi = FileItem(url: URL(fileURLWithPath: path))
            if fi.isDir { continue }
            rows.append(fi)
            if rows.count >= 250 { break }
        }
        teardownRecentsQuery()   // one-shot gather, not live updates

        items = rows
        clampSelection()
        updateStatus()
    }

    private func teardownRecentsQuery() {
        if let o = recentsObserver { NotificationCenter.default.removeObserver(o) }
        recentsObserver = nil
        recentsQuery?.stop()
        recentsQuery = nil
    }

    /// Jump from a Recents entry to the folder that contains it, cursor on the file.
    /// Acts on the passed item so a right-click inside a multi-selection opens the
    /// folder of the row that was clicked, not whatever the cursor happens to be on.
    func openEnclosingFolder(_ item: FileItem) {
        let name = item.name
        navigate(to: item.url.deletingLastPathComponent())
        if let idx = visibleItems.firstIndex(where: { $0.name == name }) { selection = idx }
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
        teardownRecentsQuery()
        isRecents = false
        url = dest.standardizedFileURL
        filter = ""; filtering = false
        load()
        restoreSelection(preferName: remember.map { _ in nil } ?? lastSelectedName[url])
        savePreferences()
    }

    private func restoreSelection(preferName: String?) {
        // Entering a new directory always starts from a clean single selection.
        defer { collapseToCursor() }
        guard let name = preferName,
              let idx = visibleItems.firstIndex(where: { $0.name == name }) else {
            selection = 0; return
        }
        selection = idx
    }

    func openSelected() {
        // With several items marked, open every file (folders are skipped — a single
        // pane can't descend into more than one). Single selection keeps folder navigation.
        if selectionCount > 1 {
            for item in selectedItems where !item.isDir { NSWorkspace.shared.open(item.url) }
            return
        }
        guard let item = selectedItem else { return }
        if item.isDir {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func goUp() {
        if isRecents { exitRecents(); return }
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
        collapseToCursor()
        updateStatus()
    }

    func selectFirst() { selection = 0; collapseToCursor(); updateStatus() }
    func selectLast() { selection = max(0, visibleItems.count - 1); collapseToCursor(); updateStatus() }

    private func clampSelection() {
        let count = visibleItems.count
        selection = count == 0 ? 0 : min(selection, count - 1)
    }

    // MARK: Multi-selection

    /// Drop any multi-selection and anchor on the current cursor row.
    private func collapseToCursor() {
        markedURLs = []
        anchorIndex = selection
    }

    /// Prune marks to URLs that still exist in the current listing (after sort/refresh).
    private func pruneMarks() {
        guard !markedURLs.isEmpty else { return }
        markedURLs.formIntersection(visibleItems.map(\.url))
    }

    /// Plain click / arrow: select exactly this row.
    func selectSingle(_ idx: Int) {
        guard visibleItems.indices.contains(idx) else { return }
        selection = idx
        collapseToCursor()
        updateStatus()
    }

    /// ⌘-click: toggle this row's membership, keeping the rest of the selection.
    func toggleMark(_ idx: Int) {
        guard visibleItems.indices.contains(idx) else { return }
        // First ⌘-click seeds the set with the existing cursor so it isn't lost.
        if markedURLs.isEmpty, let cur = selectedItem { markedURLs = [cur.url] }
        let target = visibleItems[idx].url
        if markedURLs.contains(target) { markedURLs.remove(target) } else { markedURLs.insert(target) }
        // Collapse back to a plain selection when a single row remains, moving the
        // cursor onto whatever that row is (it may not be the one just clicked).
        if markedURLs.count == 1, let only = markedURLs.first,
           let onlyIdx = visibleItems.firstIndex(where: { $0.url == only }) {
            selection = onlyIdx
            anchorIndex = onlyIdx
            markedURLs = []
        } else {
            selection = idx
            anchorIndex = idx
        }
        updateStatus()
    }

    /// ⇧-click: select the contiguous range between the anchor and this row.
    func extendTo(_ idx: Int) {
        guard visibleItems.indices.contains(idx) else { return }
        let a = anchorIndex ?? selection
        anchorIndex = a
        let lo = min(a, idx), hi = max(a, idx)
        markedURLs = Set(visibleItems[lo...hi].map(\.url))
        selection = idx
        if markedURLs.count == 1 { markedURLs = [] }   // single-row range ⇒ plain selection
        updateStatus()
    }

    /// ⇧↑ / ⇧↓: move the cursor and grow/shrink the range from the anchor.
    func extendSelection(by delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        let a = anchorIndex ?? selection
        anchorIndex = a
        let newCursor = min(max(0, selection + delta), count - 1)
        let lo = min(a, newCursor), hi = max(a, newCursor)
        markedURLs = Set(visibleItems[lo...hi].map(\.url))
        selection = newCursor
        if markedURLs.count == 1 { markedURLs = [] }
        updateStatus()
    }

    /// ⌘A: select everything currently visible.
    func selectAll() {
        guard !visibleItems.isEmpty else { return }
        markedURLs = Set(visibleItems.map(\.url))
        anchorIndex = selection
        updateStatus()
    }

    /// When a context-menu action fires on `idx`: if that row isn't already part of a
    /// multi-selection, collapse to just it first (matches Finder).
    func contextSelect(_ idx: Int) {
        guard visibleItems.indices.contains(idx) else { return }
        if !markedURLs.isEmpty && markedURLs.contains(visibleItems[idx].url) { return }
        selectSingle(idx)
    }

    // MARK: Options

    func toggleHidden() {
        showHidden.toggle()
        let keepName = selectedItem?.name
        load()
        if let n = keepName, let idx = visibleItems.firstIndex(where: { $0.name == n }) {
            selection = idx
        }
        anchorIndex = selection   // keep ⇧-arrow anchored to where the cursor landed
        status = showHidden ? "Showing hidden files" : "Hiding hidden files"
        savePreferences()
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
        // Marks are URL-keyed so they survive the reorder; the index anchor doesn't.
        anchorIndex = selection
        savePreferences()
    }

    func refresh() {
        let keepName = selectedItem?.name
        load()
        if let n = keepName, let idx = visibleItems.firstIndex(where: { $0.name == n }) {
            selection = idx
        }
        anchorIndex = selection   // keep ⇧-arrow anchored to where the cursor landed
        status = "Refreshed"
    }

    // MARK: Filter

    // filter's didSet keeps filtering/selection/status in sync, so these stay thin.
    func appendToFilter(_ s: String) { filter += s }

    func backspaceFilter() { if !filter.isEmpty { filter.removeLast() } }

    func clearFilter() { filter = "" }

    // MARK: File operations

    func trashSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let idx = selection
        var trashed = 0
        var trashedName: String?
        var lastError: String?
        for item in targets {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                trashed += 1; trashedName = item.name
            } catch {
                lastError = error.localizedDescription
            }
        }
        markedURLs = []
        refresh()
        selection = min(idx, max(0, visibleItems.count - 1))
        anchorIndex = selection
        if trashed == 0, let e = lastError {
            status = "Trash failed: \(e)"
        } else {
            status = trashed == 1 ? "Moved “\(trashedName ?? "")” to Trash" : "Moved \(trashed) items to Trash"
        }
    }

    func renameSelected() {
        if selectionCount > 1 { status = "Select a single item to rename"; return }
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
        let targets = selectedItems.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(targets.isEmpty ? [url] : targets)
        status = "Revealed in Finder"
    }

    func openTerminalHere() {
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
        status = "Opened Terminal here"
    }

    func copyPathToPasteboard() {
        let targets = selectedItems
        let text = targets.isEmpty ? url.path : targets.map { $0.url.path }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = targets.count > 1 ? "Copied \(targets.count) paths" : "Copied path"
    }

    // MARK: Clipboard (file copy / paste)

    /// Put the selected file on the general pasteboard as a file URL so it can be
    /// pasted into Finder, Solo, or dropped into other apps.
    func copySelectedToClipboard() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(targets.map { $0.url as NSURL })
        status = targets.count == 1
            ? "Copied “\(targets[0].name)” — ⌘V to paste"
            : "Copied \(targets.count) items — ⌘V to paste"
    }

    /// Copy any file URLs on the pasteboard into the current directory.
    func pasteIntoCurrent() {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { status = "Clipboard has no files"; return }
        var copied = 0
        var lastName: String?
        for src in files {
            let dest = uniqueDestination(forName: src.lastPathComponent, in: url)
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                copied += 1; lastName = dest.lastPathComponent
            } catch {
                status = "Paste failed: \(error.localizedDescription)"
            }
        }
        guard copied > 0 else { return }
        refresh()
        if let n = lastName, let idx = visibleItems.firstIndex(where: { $0.name == n }) { selection = idx }
        status = copied == 1 ? "Pasted “\(lastName ?? "")”" : "Pasted \(copied) items"
    }

    // MARK: Drag & drop

    /// Receive files dropped onto a destination directory (a folder row, or the
    /// current directory). Move within the same volume, copy across volumes.
    @discardableResult
    func receiveDrop(urls: [URL], into dest: URL) -> Bool {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return false }
        let fm = FileManager.default
        let destStd = dest.standardizedFileURL
        var changed = 0
        var lastName: String?
        for src in files {
            let srcStd = src.standardizedFileURL
            // No-op: dropping into the folder it already lives in.
            if srcStd.deletingLastPathComponent() == destStd { continue }
            // Guard: can't move a folder into itself or a descendant.
            if destStd.path == srcStd.path || destStd.path.hasPrefix(srcStd.path + "/") { continue }
            let target = uniqueDestination(forName: src.lastPathComponent, in: dest)
            do {
                if sameVolume(srcStd, destStd) {
                    try fm.moveItem(at: src, to: target)
                } else {
                    try fm.copyItem(at: src, to: target)
                }
                changed += 1; lastName = target.lastPathComponent
            } catch {
                status = "Drop failed: \(error.localizedDescription)"
            }
        }
        guard changed > 0 else { return false }
        refresh()
        if destStd == url.standardizedFileURL, let n = lastName,
           let idx = visibleItems.firstIndex(where: { $0.name == n }) { selection = idx }
        status = "Moved \(changed) item\(changed == 1 ? "" : "s")"
        return true
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        if let va = va as? NSObject, let vb = vb as? NSObject { return va.isEqual(vb) }
        return false
    }

    /// A non-colliding destination URL in `dir` for an item named `name`,
    /// appending " copy" / " copy N" as needed.
    private func uniqueDestination(forName name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        func compose(_ stem: String) -> URL {
            let u = dir.appendingPathComponent(stem)
            return ext.isEmpty ? u : u.appendingPathExtension(ext)
        }
        var candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        candidate = compose("\(base) copy")
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = compose("\(base) copy \(i)"); i += 1
        }
        return candidate
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
        } else if isRecents {
            s = "Recents · \(total) file\(total == 1 ? "" : "s") · last \(Self.recentsWindowDays) days"
        } else {
            let dirs = items.filter(\.isDir).count
            s = "\(total) items · \(dirs) folders · \(total - dirs) files"
        }
        if selectionCount > 1 {
            s += "    ·    \(selectionCount) selected"
        } else if let sel = selectedItem {
            s += "    ·    \(sel.name)"
        }
        status = s
    }
}
