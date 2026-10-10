import VaultCore
import AppKit

@MainActor struct SemanticPresentation {
    var id: String
    var title: String
    var symbol: String
    var accent: NSColor
    var statuses: [String]
    static let all: [Self] = [
        .init(id: "question", title: "Question", symbol: "questionmark.circle", accent: .systemBlue, statuses: ["open", "answered"]),
        .init(id: "idea", title: "Idea", symbol: "lightbulb", accent: .systemYellow, statuses: ["proposed", "developed", "archived"]),
        .init(id: "important", title: "Important", symbol: "exclamationmark.circle", accent: .systemOrange, statuses: []),
        .init(id: "starred", title: "Starred", symbol: "star", accent: .systemYellow, statuses: []),
        .init(id: "definition", title: "Definition", symbol: "book", accent: .systemPurple, statuses: []),
        .init(id: "example", title: "Example", symbol: "curlybraces", accent: .secondaryLabelColor, statuses: []),
        .init(id: "insight", title: "Insight", symbol: "sparkles", accent: .systemTeal, statuses: []),
        .init(id: "warning", title: "Warning", symbol: "exclamationmark.triangle", accent: .systemRed, statuses: []),
        .init(id: "reference", title: "Reference", symbol: "bookmark", accent: .systemTeal, statuses: []),
        .init(id: "summary", title: "Summary", symbol: "list.bullet.rectangle", accent: .secondaryLabelColor, statuses: [])
    ]
    static func find(_ id: String?) -> Self? { all.first { $0.id == id } }
}
