import Foundation
import Testing
@testable import VaultCore

@Test func entityPropertyScalarValidationAndRoundtrip() throws {
    let values: [EntityPropertyValue] = [.text(""), .number(1.25),
        .date(try EntityPropertyDate(year: 2024, month: 2, day: 29)),
        .boolean(false), .url("https://example.com/path")]
    for value in values {
        try value.validate(for: value.kind)
        let decoded = try JSONDecoder().decode(EntityPropertyValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }
    #expect(throws: EntityPropertyValidationError.nonFiniteNumber) { try EntityPropertyValue.number(.nan).validate() }
    #expect(throws: EntityPropertyValidationError.nonFiniteNumber) { try EntityPropertyValue.number(.infinity).validate() }
    #expect(throws: EntityPropertyValidationError.kindMismatch) { try EntityPropertyValue.text("1").validate(for: .number) }
    for invalid in ["relative/path", "file:///tmp/file", "https://", "https://example.com/a b"] {
        #expect(throws: EntityPropertyValidationError.invalidURL) { try EntityPropertyValue.url(invalid).validate() }
    }
}

@Test func entityPropertyDatesPreserveGranularityAndRejectInvalidCalendarDates() throws {
    #expect(try EntityPropertyDate(year: 2024).encodedDate == "2024")
    #expect(try EntityPropertyDate(year: 2024, month: 2).encodedDate == "2024-02")
    #expect(try EntityPropertyDate(year: 2024, month: 2, day: 29).encodedDate == "2024-02-29")
    for year in [1900, 2023] {
        #expect(throws: EntityPropertyValidationError.invalidDate) { try EntityPropertyDate(year: year, month: 2, day: 29) }
    }
    #expect(throws: EntityPropertyValidationError.invalidDate) { try EntityPropertyDate(year: 2024, day: 1) }
    #expect(throws: EntityPropertyValidationError.invalidDate) { try EntityPropertyDate(year: 2024, month: 4, day: 31) }
}

@Test func entityPropertyDefinitionsNormalizeWithoutChangingDisplayLabel() throws {
    let definition = try EntityPropertyDefinition(vaultID: UUID(), label: "  Research\t Topic \n", kind: .text)
    #expect(definition.normalizedKey == "research topic")
    #expect(definition.label == "  Research\t Topic \n")
    #expect(try JSONDecoder().decode(EntityPropertyDefinition.self, from: JSONEncoder().encode(definition)) == definition)
    #expect(throws: EntityPropertyValidationError.emptyLabel) {
        try EntityPropertyDefinition(vaultID: UUID(), label: " \n ", kind: .text)
    }
}

@Test func entityRelationshipPresentationRetainsFutureFieldsAndValidatesHints() throws {
    let raw = Data(#"{"inverseLabel":"Works created","sourceTypeKeys":["creativeWork"],"targetTypeKeys":["person"],"future":{"display":true}}"#.utf8)
    let value = try JSONDecoder().decode(EntityPropertyPresentation.self, from: raw)
    try value.validate()
    #expect(value.unknownFields["future"] == .object(["display": .bool(true)]))
    #expect(try JSONDecoder().decode(EntityPropertyPresentation.self, from: JSONEncoder().encode(value)) == value)
    let definition = try EntityPropertyDefinition(vaultID: UUID(), label: "Created by", kind: .entityReference, presentation: value)
    #expect(definition.relationshipLabel(direction: .incoming) == "Works created")
    #expect(definition.relationshipLabel(direction: .outgoing) == "Created by")
    #expect(throws: EntityPropertyValidationError.kindMismatch) {
        try EntityPropertyDefinition(vaultID: UUID(), label: "Text", kind: .text, presentation: value)
    }
    #expect(throws: EntityPropertyValidationError.emptyLabel) { try EntityPropertyPresentation(inverseLabel: " \n ").validate() }
    for keys in [["person", "person"], [""], [" person "]] {
        #expect(throws: EntityPropertyValidationError.invalidMetadata) { try EntityPropertyPresentation(sourceTypeKeys: keys).validate() }
    }
    // Future registry keys are preserved as advisory intent, without inventing a type.
    try EntityPropertyPresentation(targetTypeKeys: ["futureType"]).validate()
}
