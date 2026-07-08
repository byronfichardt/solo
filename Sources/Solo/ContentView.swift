import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

/// Drives the shared `QLPreviewPanel` (Finder's spacebar Quick Look) for the
/// current selection. We assign ourselves as the panel's data source directly
/// rather than routing through the responder chain, which is the reliable path
/// from a pure-SwiftUI app.
@MainActor
final class QuickLookController: NSObject, ObservableObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []

    /// Toggle the panel: show it for `items`, or hide it if already visible.
    func toggle(items: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !items.isEmpty else { return }
        urls = items
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Keep the open panel in sync as the cursor moves; no-op when it's hidden.
    func update(items: [URL]) {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible, !items.isEmpty else { return }
        urls = items
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

struct ContentView: View {
    @StateObject var model: DirectoryModel
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool
    @State private var showHelp = false
    @State private var dropTargetIndex: Int?
    @State private var listDropTargeted = false
    @StateObject private var quickLook = QuickLookController()

    private let pageSize = 15

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model, searchFocused: $searchFocused, focusList: { focused = true })
            Divider()
            ColumnHeader(model: model)
            Divider()
            fileList
            Divider()
            StatusBar(model: model)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { handle($0) }
        .overlay { if showHelp { HelpOverlay(show: $showHelp) } }
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.visibleItems.isEmpty {
                        VStack(spacing: 6) {
                            Text(model.filter.isEmpty ? "Empty folder" : "No matches")
                                .foregroundStyle(.secondary)
                            if model.filter.isEmpty {
                                Text("type to filter · Space to preview · ⌘/ for shortcuts")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                    }
                    ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { idx, item in
                        let isSel = model.isSelected(idx)
                        FileRow(item: item, selected: isSel && focused,
                                softSelected: isSel && !focused,
                                isCursor: idx == model.selection && focused && model.selectionCount > 1,
                                dropTargeted: item.isDir && dropTargetIndex == idx)
                            .contentShape(Rectangle())
                            // Select on the first click immediately; double-click opens.
                            // simultaneousGesture avoids the tap-disambiguation delay that
                            // makes single-click selection feel laggy.
                            // ⌘ toggles a row, ⇧ extends a range — read live modifier flags
                            // since SwiftUI's tap gesture doesn't surface them.
                            .onTapGesture {
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.command) { model.toggleMark(idx) }
                                else if mods.contains(.shift) { model.extendTo(idx) }
                                else { model.selectSingle(idx) }
                                focused = true
                            }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    model.selectSingle(idx); model.openSelected()
                                }
                            )
                            // Drag a file out (to another folder, Finder, or Claude).
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                            // Folders accept drops (move/copy the dropped files in).
                            .modifier(FolderDropModifier(
                                enabled: item.isDir,
                                isTargeted: Binding(
                                    get: { dropTargetIndex == idx },
                                    set: { dropTargetIndex = $0 ? idx : nil }),
                                onDrop: { providers in
                                    loadURLs(from: providers) { model.receiveDrop(urls: $0, into: item.url) }
                                    return true
                                }))
                            .contextMenu { rowMenu(idx: idx, item: item) }
                    }
                }
            }
            // anchor: nil scrolls the minimum needed to keep the selection visible —
            // no jarring re-centering, and a no-op when the row is already on screen.
            .onChange(of: model.selection) { _, _ in
                guard let id = model.selectedItem?.id else { return }
                proxy.scrollTo(id)
                quickLook.update(items: model.selectedItems.map(\.url))
            }
            .onChange(of: model.url) { _, _ in
                proxy.scrollTo(model.selectedItem?.id)
            }
            // Drop onto empty pane area → into the current directory.
            .onDrop(of: [.fileURL], isTargeted: $listDropTargeted) { providers in
                loadURLs(from: providers) { model.receiveDrop(urls: $0, into: model.url) }
                return true
            }
            .overlay {
                if listDropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(idx: Int, item: FileItem) -> some View {
        // How many items the action will hit: the whole selection when right-clicking
        // inside it, otherwise just this row (contextSelect collapses to it first).
        let count = (!model.markedURLs.isEmpty && model.markedURLs.contains(item.url)) ? model.selectionCount : 1
        let suffix = count > 1 ? " \(count) Items" : ""
        Button(count > 1 ? "Open\(suffix)" : (item.isDir ? "Open Folder" : "Open")) {
            model.contextSelect(idx); model.openSelected()
        }
        if model.isRecents {
            Button("Open Enclosing Folder") { model.openEnclosingFolder(item) }
        }
        Divider()
        Button("Copy\(suffix)") { model.contextSelect(idx); model.copySelectedToClipboard() }
        Button("Paste") { model.pasteIntoCurrent() }
        Button(count > 1 ? "Copy\(suffix) Paths" : "Copy Path") { model.contextSelect(idx); model.copyPathToPasteboard() }
        Divider()
        Button("Rename…") { model.contextSelect(idx); model.renameSelected() }
            .disabled(count > 1)
        Button(count > 1 ? "Move\(suffix) to Trash" : "Move to Trash") { model.contextSelect(idx); model.trashSelected() }
        Divider()
        Button("Reveal in Finder") { model.contextSelect(idx); model.revealInFinder() }
        Button("New Folder…") { model.newFolder() }
    }

    /// Asynchronously resolve file URLs from dropped item providers, then run `completion` on the main actor.
    private func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: NSURL.self) { reading, _ in
                if let nsurl = reading as? NSURL {
                    let u = nsurl as URL
                    if u.isFileURL { lock.lock(); urls.append(u); lock.unlock() }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    // MARK: Keyboard

    private func handle(_ p: KeyPress) -> KeyPress.Result {
        if showHelp {
            showHelp = false
            return .handled
        }
        if p.modifiers.contains(.command) {
            return handleCommand(p)
        }
        // Space = Quick Look (Finder convention). Takes precedence over type-to-filter;
        // use the search field (⌘F) when a literal space in the filter is needed.
        if p.characters == " ", p.modifiers.isDisjoint(with: [.command, .control, .option]) {
            quickLook.toggle(items: model.selectedItems.map(\.url))
            return .handled
        }
        let shift = p.modifiers.contains(.shift)
        switch p.key {
        case .downArrow: shift ? model.extendSelection(by: 1) : model.moveSelection(by: 1); return .handled
        case .upArrow:   shift ? model.extendSelection(by: -1) : model.moveSelection(by: -1); return .handled
        case .rightArrow, .return: model.openSelected(); return .handled
        case .leftArrow: model.goUp(); return .handled
        case .home: model.selectFirst(); return .handled
        case .end:  model.selectLast(); return .handled
        case .pageDown: shift ? model.extendSelection(by: pageSize) : model.moveSelection(by: pageSize); return .handled
        case .pageUp:   shift ? model.extendSelection(by: -pageSize) : model.moveSelection(by: -pageSize); return .handled
        case .escape:
            if model.filtering { model.clearFilter(); return .handled }
            return .ignored
        case .delete:   // backspace
            if model.filtering { model.backspaceFilter() } else { model.goUp() }
            return .handled
        case .tab:
            return .handled
        default:
            break
        }
        // Type-to-filter (Marta-style incremental search)
        let chars = p.characters
        if !chars.isEmpty,
           p.modifiers.isDisjoint(with: [.command, .control, .option]),
           chars.rangeOfCharacter(from: .controlCharacters) == nil,
           !chars.contains(where: \.isNewline) {
            model.appendToFilter(chars)
            return .handled
        }
        return .ignored
    }

    private func handleCommand(_ p: KeyPress) -> KeyPress.Result {
        let shift = p.modifiers.contains(.shift)
        switch p.key {
        case .upArrow:    model.goUp(); return .handled
        case .downArrow:  model.openSelected(); return .handled
        case .leftArrow:  model.goBack(); return .handled
        case .rightArrow: model.goForward(); return .handled
        case .delete:     model.trashSelected(); return .handled
        case .return:     model.renameSelected(); return .handled
        default: break
        }
        let option = p.modifiers.contains(.option)
        switch p.key.character {
        case "a": model.selectAll()
        case "r": model.refresh()
        case "n": model.newFolder()
        case ".": model.toggleHidden()
        case "c": option ? model.copyPathToPasteboard() : model.copySelectedToClipboard()
        case "v": model.pasteIntoCurrent()
        case "l": model.goToPathPrompt()
        case "t": model.openTerminalHere()
        case "f": shift ? model.revealInFinder() : (searchFocused = true)
        case "[": model.goBack()
        case "]": model.goForward()
        case "h": model.goHome()
        case "0": model.showRecents()
        case "s": shift ? model.toggleSortDirection() : model.cycleSort()
        case "1": model.setSort(.name)
        case "2": model.setSort(.size)
        case "3": model.setSort(.modified)
        case "4": model.setSort(.ext)
        case "/": showHelp.toggle()
        default: return .ignored
        }
        return .handled
    }
}

// MARK: - Path bar

struct PathBar: View {
    @ObservedObject var model: DirectoryModel
    @FocusState.Binding var searchFocused: Bool
    var focusList: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.showRecents(); focusList()
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(model.isRecents ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Recent files (⌘0)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.pathComponents.enumerated()), id: \.offset) { idx, comp in
                        if idx > 0 {
                            Text("›").foregroundStyle(.tertiary).font(.system(size: 11))
                        }
                        Button(comp.name) {
                            model.navigate(to: comp.url)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: idx == model.pathComponents.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == model.pathComponents.count - 1 ? Color.primary : Color.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            searchField
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 140)
                .focused($searchFocused)
                .onSubmit { model.selectFirst(); focusList() }
                .onExitCommand { model.clearFilter(); focusList() }
            if !model.filter.isEmpty {
                Button {
                    model.clearFilter(); focusList()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
        )
        .overlay(
            Capsule().strokeBorder(
                searchFocused ? Color.accentColor : Color.secondary.opacity(0.25),
                lineWidth: 1)
        )
    }
}

// MARK: - Column header

struct ColumnHeader: View {
    @ObservedObject var model: DirectoryModel

    var body: some View {
        HStack(spacing: 8) {
            headerCell("Name", .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell("Size", .size, alignment: .trailing)
                .frame(width: 80, alignment: .trailing)
            headerCell("Modified", .modified, alignment: .trailing)
                .frame(width: 130, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func headerCell(_ title: String, _ key: SortKey, alignment: Alignment) -> some View {
        Button {
            model.setSort(key)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if model.sortKey == key {
                    Text(model.sortAsc ? "▲" : "▼").font(.system(size: 7))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - File row

/// Applies a folder drop target only when `enabled` (file rows aren't drop targets).
struct FolderDropModifier: ViewModifier {
    let enabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: onDrop)
        } else {
            content
        }
    }
}

struct FileRow: View {
    let item: FileItem
    let selected: Bool
    let softSelected: Bool
    /// The keyboard cursor row while more than one item is selected — drawn with a
    /// focus ring so you can see where arrow keys will move within the selection.
    var isCursor: Bool = false
    var dropTargeted: Bool = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(nameColor)
                .italic(item.isSymlink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.sizeString)
                .monospacedDigit()
                .foregroundStyle(secondaryColor)
                .frame(width: 80, alignment: .trailing)
            Text(item.modifiedString)
                .monospacedDigit()
                .foregroundStyle(secondaryColor)
                .frame(width: 130, alignment: .trailing)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(background)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            } else if isCursor {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .padding(1)
            }
        }
        .onHover { hovering = $0 }
    }

    private var background: some View {
        Group {
            if dropTargeted {
                Color.accentColor.opacity(0.18)
            } else if selected {
                Color.accentColor
            } else if softSelected {
                Color.accentColor.opacity(0.25)
            } else if hovering {
                Color.primary.opacity(0.08)
            } else {
                Color.clear
            }
        }
    }

    private var nameColor: Color {
        if selected { return .white }
        return .primary
    }

    private var secondaryColor: Color {
        selected ? Color.white.opacity(0.85) : .secondary
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var model: DirectoryModel

    var body: some View {
        HStack {
            if model.filtering {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            Text(model.status)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("⌘/ for help")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Help overlay

struct HelpOverlay: View {
    @Binding var show: Bool

    private let rows: [(String, String)] = [
        ("↑ / ↓", "Move cursor"),
        ("⇧↑ / ⇧↓", "Extend selection"),
        ("⌘-click", "Add / remove from selection"),
        ("⇧-click", "Select range"),
        ("⌘A", "Select all"),
        ("Space", "Quick Look preview"),
        ("→ / Return", "Open file or enter folder"),
        ("← / Backspace", "Go up to parent folder"),
        ("type letters", "Incremental filter (Esc to clear)"),
        ("Home / End", "Jump to top / bottom"),
        ("PageUp / PageDown", "Page through list"),
        ("⌘← / ⌘→", "Back / Forward history"),
        ("⌘↑ / ⌘↓", "Parent folder / Open"),
        ("⌘C / ⌘V", "Copy file / Paste into folder"),
        ("⌘⌥C", "Copy path"),
        ("drag", "Move to a folder, or drag out to other apps"),
        ("⌘F", "Search (click the field too)"),
        ("⌘R", "Refresh"),
        ("⌘N", "New folder"),
        ("⌘Return", "Rename selected"),
        ("⌘Delete", "Move to Trash"),
        ("⌘.", "Toggle hidden files"),
        ("⌘L", "Go to path…"),
        ("⌘0", "Recent files (newest first)"),
        ("⌘⇧F", "Reveal in Finder"),
        ("⌘T", "Open Terminal here"),
        ("⌘H", "Home folder"),
        ("⌘S / ⌘⇧S", "Cycle sort / Flip direction"),
        ("⌘1…4", "Sort by Name / Size / Date / Type"),
        ("right-click", "Context menu of actions"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { show = false }
            VStack(alignment: .leading, spacing: 0) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.bottom, 10)
                ForEach(rows, id: \.0) { key, desc in
                    HStack(alignment: .top) {
                        Text(key)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 150, alignment: .leading)
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                Text("Press any key to close")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
            }
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 30)
        }
    }
}
