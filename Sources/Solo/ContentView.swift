import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject var model: DirectoryModel
    @FocusState private var focused: Bool
    @State private var showHelp = false

    private let pageSize = 15

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model)
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
                        Text(model.filter.isEmpty ? "Empty folder" : "No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { idx, item in
                        FileRow(item: item, selected: idx == model.selection && focused,
                                softSelected: idx == model.selection && !focused)
                            .contentShape(Rectangle())
                            // Select on the first click immediately; double-click opens.
                            // simultaneousGesture avoids the tap-disambiguation delay that
                            // makes single-click selection feel laggy.
                            .onTapGesture {
                                model.selection = idx; focused = true
                            }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    model.selection = idx; model.openSelected()
                                }
                            )
                    }
                }
            }
            // anchor: nil scrolls the minimum needed to keep the selection visible —
            // no jarring re-centering, and a no-op when the row is already on screen.
            .onChange(of: model.selection) { _, _ in
                guard let id = model.selectedItem?.id else { return }
                proxy.scrollTo(id)
            }
            .onChange(of: model.url) { _, _ in
                proxy.scrollTo(model.selectedItem?.id)
            }
        }
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
        switch p.key {
        case .downArrow: model.moveSelection(by: 1); return .handled
        case .upArrow:   model.moveSelection(by: -1); return .handled
        case .rightArrow, .return: model.openSelected(); return .handled
        case .leftArrow: model.goUp(); return .handled
        case .home: model.selectFirst(); return .handled
        case .end:  model.selectLast(); return .handled
        case .pageDown: model.moveSelection(by: pageSize); return .handled
        case .pageUp:   model.moveSelection(by: -pageSize); return .handled
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
        switch p.key.character {
        case "r": model.refresh()
        case "n": model.newFolder()
        case ".": model.toggleHidden()
        case "c": model.copyPathToPasteboard()
        case "l": model.goToPathPrompt()
        case "t": model.openTerminalHere()
        case "f": model.revealInFinder()
        case "[": model.goBack()
        case "]": model.goForward()
        case "h": model.goHome()
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

    var body: some View {
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
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
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

struct FileRow: View {
    let item: FileItem
    let selected: Bool
    let softSelected: Bool
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
        .onHover { hovering = $0 }
    }

    private var background: some View {
        Group {
            if selected {
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
        ("→ / Return", "Open file or enter folder"),
        ("← / Backspace", "Go up to parent folder"),
        ("type letters", "Incremental filter (Esc to clear)"),
        ("Home / End", "Jump to top / bottom"),
        ("PageUp / PageDown", "Page through list"),
        ("⌘← / ⌘→", "Back / Forward history"),
        ("⌘↑ / ⌘↓", "Parent folder / Open"),
        ("⌘R", "Refresh"),
        ("⌘N", "New folder"),
        ("⌘Return", "Rename selected"),
        ("⌘Delete", "Move to Trash"),
        ("⌘.", "Toggle hidden files"),
        ("⌘C", "Copy path"),
        ("⌘L", "Go to path…"),
        ("⌘F", "Reveal in Finder"),
        ("⌘T", "Open Terminal here"),
        ("⌘H", "Home folder"),
        ("⌘S / ⌘⇧S", "Cycle sort / Flip direction"),
        ("⌘1…4", "Sort by Name / Size / Date / Type"),
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
