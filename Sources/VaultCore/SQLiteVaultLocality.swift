import Foundation

/// SQLite vaults require a local filesystem outside synchronized provider roots.
public enum SQLiteVaultLocality {
    public static func requireLocalRoot(_ root: URL) throws {
        guard root.isFileURL, root.standardizedFileURL == root.standardizedFileURL.resolvingSymlinksInPath() else {
            throw VaultContentStoreError.unsafePath(root.path)
        }
        var ancestor = root.standardizedFileURL
        while true {
            let values = try ancestor.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey])
            let name = ancestor.lastPathComponent.lowercased()
            let knownCloudRoot = ["cloudstorage", "mobile documents", "icloud drive", "dropbox", "onedrive", "google drive", "googledrive", "box"].contains {
                name == $0 || name.hasPrefix($0 + " ") || name.hasPrefix($0 + "-")
            }
            guard values.isUbiquitousItem != true, values.volumeIsLocal == true, !knownCloudRoot else {
                throw VaultError.invalid("SQLite storage requires a local vault outside cloud-backed folders.")
            }
            if ancestor.path == "/" { break }
            let parent = ancestor.deletingLastPathComponent().standardizedFileURL
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
    }

}
