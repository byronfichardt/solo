import Foundation
import AppKit

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

    /// Cached system icon for the file.
    var icon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }

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
