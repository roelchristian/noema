import Foundation
import Yams

public enum NoteCodec {
    public static func decode(_ data: Data, path: String, vaultID: UUID) throws -> NoteRecord {
        guard let text = String(data: data, encoding: .utf8) else { throw VaultError.invalid("\(path) is not valid UTF-8 text.") }
        var header: String?
        var body = text
        if text.hasPrefix("---\n") || text.hasPrefix("---\r\n") {
            let lines = text.components(separatedBy: "\n")
            guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
                throw VaultError.invalid("\(path) has an unclosed YAML frontmatter block.")
            }
            header = lines[1..<end].joined(separator: "\n")
            body = lines.dropFirst(end + 1).joined(separator: "\n")
        }
        let node: Node?
        do { node = try header.flatMap { try Yams.compose(yaml: $0) } }
        catch { throw VaultError.invalid("\(path) has invalid YAML: \(error.localizedDescription)") }
        if let node, node.mapping == nil { throw VaultError.invalid("\(path) frontmatter must be a mapping.") }
        func string(_ key: String) -> String? { node?[key]?.scalar?.string }
        func strings(_ key: String) -> [String] {
            if let sequence = node?[key]?.sequence { return sequence.compactMap { $0.scalar?.string } }
            return string(key).map { [$0] } ?? []
        }
        if let rawID = string("id"), UUID(uuidString: rawID) == nil { throw VaultError.invalid("\(path) has an invalid note ID.") }
        let fallbackTitle = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var note = NoteRecord(
            id: string("id").flatMap(UUID.init(uuidString:)) ?? externalID(vault: vaultID, path: path),
            title: string("title") ?? fallbackTitle,
            aliases: strings("aliases"), tags: normalizeTags(strings("tags")),
            inlineTags: MarkdownService.analyze(body).tags,
            createdAt: string("created_at") ?? "", updatedAt: string("updated_at") ?? "",
            body: body, relativePath: path, contentHash: digest(data), originalHeader: header
        )
        note.editingLocked = string("editing_locked") == "true"
        return note
    }
    public static func encode(_ note: NoteRecord) throws -> Data {
        var node = try note.originalHeader.flatMap { try Yams.compose(yaml: $0) } ?? Node([:])
        if note.editingLocked != nil { node["editing_locked"] = Node(note.isEditingLocked ? "true" : "false") }
        node["id"] = Node(note.id.uuidString.lowercased())
        node["title"] = Node(note.title)
        node["aliases"] = Node(note.aliases.map { Node($0) })
        node["tags"] = Node(note.tags.map { Node($0) })
        node["created_at"] = Node(note.createdAt)
        node["updated_at"] = Node(note.updatedAt)
        return Data(("---\n" + (try Yams.serialize(node: node)) + "---\n" + note.body).utf8)
    }
}
