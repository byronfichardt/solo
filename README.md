# Solo

A single-pane, keyboard-driven file manager for macOS — inspired by [Marta](https://marta.sh).
Native SwiftUI, fast, minimal. One column, real Finder icons, type-to-find, and Marta-style
keyboard navigation.

![single pane](https://img.shields.io/badge/panes-1-blue) ![swift](https://img.shields.io/badge/swift-6-orange)

## Features

- **Single pane** directory listing with Name / Size / Modified columns
- **Quick Look** — press `Space` to preview the selected file (Finder-style)
- **Type-to-filter** — just start typing to incrementally filter the current folder (Esc clears)
- **Full keyboard navigation** — arrows, Home/End, PageUp/Down, back/forward history
- **Real system icons** via `NSWorkspace`
- **File operations** — rename, new folder, move to Trash (all keyboard-driven)
- **Sorting** by Name / Size / Date / Type, ascending/descending, folders always on top
- **Breadcrumb path bar** — click any component to jump there
- **Hidden files** toggle (`⌘.`)
- **Reveal in Finder**, **Open Terminal here**, **Copy path**, **Go to path…**
- Opens files with their default app; double-click or Enter to open

## Keyboard shortcuts

Press **⌘/** in the app for the full cheat sheet.

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move cursor |
| `Space` | Quick Look preview |
| `→` / `Return` | Open file or enter folder |
| `←` / `Backspace` | Go up to parent |
| type letters | Incremental filter (`Esc` to clear) |
| `Home` / `End` | Jump to top / bottom |
| `PageUp` / `PageDown` | Page through list |
| `⌘←` / `⌘→` | Back / Forward history |
| `⌘↑` / `⌘↓` | Parent folder / Open |
| `⌘R` | Refresh |
| `⌘N` | New folder |
| `⌘Return` | Rename selected |
| `⌘Delete` | Move to Trash |
| `⌘.` | Toggle hidden files |
| `⌘C` | Copy path |
| `⌘L` | Go to path… |
| `⌘F` | Reveal in Finder |
| `⌘T` | Open Terminal here |
| `⌘H` | Home folder |
| `⌘S` / `⌘⇧S` | Cycle sort / Flip direction |
| `⌘1…4` | Sort by Name / Size / Date / Type |

## Build & run

Requires the Swift toolchain (Swift 6, macOS 14+). No Xcode required.

```bash
# Run directly during development
swift run Solo                 # opens your home folder
swift run Solo ~/projects      # opens a specific folder

# Build a double-clickable Solo.app bundle
./build-app.sh
open Solo.app
open Solo.app --args ~/projects
```

To install, drag `Solo.app` into `/Applications`.

## Architecture

| File | Responsibility |
|------|----------------|
| `SoloApp.swift` | App entry, window, start-directory resolution |
| `DirectoryModel.swift` | Observable state: listing, selection, sort, filter, navigation, file ops |
| `FileItem.swift` | One directory entry + cached icon and formatted metadata |
| `ContentView.swift` | UI (path bar, columns, list, status bar, help) + all keyboard handling |
| `Prompt.swift` | Modal `NSAlert` text prompt for rename / new folder / go-to-path |

## Notes

- The app is ad-hoc signed locally so it launches without a developer account. If macOS
  Gatekeeper objects after copying it elsewhere, right-click → Open the first time.
- File operations use the system Trash (recoverable) — nothing is hard-deleted.
- Sort order, the hidden-files toggle, window size, and the last folder are remembered
  across launches (via `UserDefaults`). Pass a folder on the command line to override
  the remembered start folder.
