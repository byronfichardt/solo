import Foundation
import AppKit

/// Resolves and caches file icons on the main actor.
///
/// `NSWorkspace.icon(forFile:)` is not free, and Solo previously called it from
/// `FileItem.icon` — a computed property — which meant every SwiftUI redraw of a
/// row (hover, selection, scroll) refetched the icon and mutated the size of the
/// OS's *shared* icon instance. Caching by path resolves each icon once and never
/// touches shared state, so scrolling large folders stays smooth.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        let path = url.path
        if let cached = cache[path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }

    /// Drop cached icons. Called when a directory is (re)loaded so a file replaced
    /// at the same path picks up its new icon, and the cache can't grow unbounded
    /// across a long session. The scroll-jank fix is per-render caching within a
    /// listing, which this preserves — icons simply refetch once per folder visit.
    static func clear() { cache.removeAll(keepingCapacity: true) }
}

/// One entry in a directory listing.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDir: Bool
    let isSymlink: Bool
    let isPackage: Bool
    let size: Int64          // -1 for directories we didn't measure
    let modified: Date
    let created: Date

    var id: URL { url }

    var ext: String {
        isDir ? "" : url.pathExtension.lowercased()
    }

    init(url: URL) {
        self.url = url
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey,
            .isPackageKey, .localizedNameKey
        ]
        let v = try? url.resourceValues(forKeys: keys)
        self.name = v?.localizedName ?? url.lastPathComponent
        self.isSymlink = v?.isSymbolicLink ?? false
        self.isPackage = v?.isPackage ?? false
        // A package (e.g. .app) is technically a directory but we treat it as a file for opening.
        let dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        self.isDir = dir
        self.size = dir ? -1 : Int64(v?.fileSize ?? v?.totalFileAllocatedSize ?? 0)
        self.modified = v?.contentModificationDate ?? .distantPast
        self.created = v?.creationDate ?? (v?.contentModificationDate ?? .distantPast)
    }

    /// System icon for the file, fetched through `IconCache` so it is resolved once
    /// per path instead of on every SwiftUI render (see the cache for why).
    @MainActor var icon: NSImage { IconCache.icon(for: url) }

    var sizeString: String {
        guard !isDir else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var modifiedString: String {
        FileItem.dateFormatter.string(from: modified)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
