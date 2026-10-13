import Foundation

/// Shared type symbols for canonical targets; labels remain visible and accessible.
enum KnowledgeTypePresentation {
    static let knowledgeSymbol = "point.3.connected.trianglepath.dotted"
    static func symbol(for typeKey: String) -> String {
        switch typeKey {
        case "person": "person"
        case "place": "mappin.and.ellipse"
        case "concept": "lightbulb"
        case "event": "flag"
        case "question": "questionmark.circle"
        case "definition": "text.book.closed"
        default: knowledgeSymbol
        }
    }
}
