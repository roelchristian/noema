import Foundation

/// A bounded min-heap whose root is the worst retained item. No query/vector state persists.
struct EmbeddingSearchHeap<Element> {
    let capacity: Int
    let precedes: (Element, Element) -> Bool
    private(set) var elements: [Element] = []

    mutating func insert(_ value: Element) {
        guard capacity > 0 else { return }
        if elements.count < capacity {
            elements.append(value)
            var child = elements.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(elements[parent], elements[child]) else { break }
                elements.swapAt(parent, child); child = parent
            }
        } else if precedes(value, elements[0]) {
            elements[0] = value
            var parent = 0
            while parent * 2 + 1 < elements.count {
                var child = parent * 2 + 1
                if child + 1 < elements.count, precedes(elements[child], elements[child + 1]) { child += 1 }
                guard precedes(elements[parent], elements[child]) else { break }
                elements.swapAt(parent, child); parent = child
            }
        }
    }
    func sorted() -> [Element] { elements.sorted(by: precedes) }
}

func embeddingPassagePrecedes(_ left: SemanticSearchPassage, _ right: SemanticSearchPassage) -> Bool {
    if left.cosineSimilarity != right.cosineSimilarity { return left.cosineSimilarity > right.cosineSimilarity }
    if left.chunk.ordinal != right.chunk.ordinal { return left.chunk.ordinal < right.chunk.ordinal }
    return left.chunk.chunkID < right.chunk.chunkID
}

func embeddingCandidatePrecedes(_ left: SemanticSearchCandidate, _ right: SemanticSearchCandidate) -> Bool {
    if left.cosineSimilarity != right.cosineSimilarity { return left.cosineSimilarity > right.cosineSimilarity }
    if left.identity.entityKind != right.identity.entityKind { return left.identity.entityKind.rawValue < right.identity.entityKind.rawValue }
    return left.identity.entityID.uuidString < right.identity.entityID.uuidString
}
