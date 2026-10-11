import Foundation
import Testing
@testable import ExternalAI

private func summaryResponse(status: String = "completed", reason: String? = nil,
                             output: [[String: Any]]) throws -> Data {
    var response: [String: Any] = ["object": "response", "status": status, "output": output]
    if let reason { response["incomplete_details"] = ["reason": reason] }
    return try JSONSerialization.data(withJSONObject: response)
}

private func summaryMessage(_ text: String, status: String = "completed") -> [String: Any] {
    ["type": "message", "role": "assistant", "status": status,
     "content": [["type": "output_text", "text": text]]]
}

@Test func summaryLunaHasBoundedReasoningHeadroomWithoutChangingOtherModels() throws {
    for model in ["gpt-6-luna", "gpt-4.1-mini", "custom-model"] {
        let data = try ExternalAIGateway.summaryBody(content: "Exact selected text", model: model)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == model)
        #expect(body["input"] as? String == "Exact selected text")
        #expect(body["store"] as? Bool == false)
        #expect(body["tools"] == nil)
        if model == "gpt-6-luna" {
            #expect(body["max_output_tokens"] as? Int == 8_192)
            #expect((body["reasoning"] as? [String: String]) == ["effort": "low"])
        } else {
            #expect(body["max_output_tokens"] as? Int == 2_048)
            #expect(body["reasoning"] == nil)
        }
    }
}

@Test(arguments: ExternalAIReasoningEffort.allCases)
func summaryUsesSelectedReasoningEffortWithoutChangingRequestBounds(effort: ExternalAIReasoningEffort) throws {
    for model in ["gpt-6-luna", "gpt-4.1-mini", "custom-model"] {
        let data = try ExternalAIGateway.summaryBody(content: "Exact selected text", model: model, reasoningEffort: effort)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if model == "gpt-6-luna" {
            #expect((body["reasoning"] as? [String: String]) == ["effort": effort.rawValue])
            #expect(body["max_output_tokens"] as? Int == 8_192)
        } else {
            #expect(body["reasoning"] == nil)
            #expect(body["max_output_tokens"] as? Int == 2_048)
        }
        #expect(body["input"] as? String == "Exact selected text")
        #expect(body["store"] as? Bool == false)
        #expect(body["tools"] == nil)
    }
}

@Test func summaryAcceptsReasoningAlongsideCompletedAssistantText() throws {
    let privateReasoning = "synthetic-reasoning-must-not-be-published"
    let reasoning: [String: Any] = ["type": "reasoning", "summary": [
        ["type": "summary_text", "text": privateReasoning]]]
    let body = try summaryResponse(output: [reasoning, summaryMessage("  A concise summary.\n")])
    #expect(try ExternalAIGateway.summary(from: body) == "A concise summary.")
    let afterMessage = try summaryResponse(output: [summaryMessage("A concise summary."), reasoning])
    #expect(try ExternalAIGateway.summary(from: afterMessage) == "A concise summary.")
}

@Test func summaryStillRejectsReasoningWithoutAnAnswerAndUnexpectedOperations() throws {
    for output in [
        [["type": "reasoning", "summary": []]],
        [["type": "function_call", "arguments": "synthetic"], summaryMessage("A summary.")],
        [["type": "web_search_call"], summaryMessage("A summary.")],
        [summaryMessage("A partial summary.", status: "incomplete")],
        [["type": "reasoning", "status": "in_progress"], summaryMessage("A summary.")],
        [summaryMessage(" \n ")]
    ] as [[[String: Any]]] {
        let body = try summaryResponse(output: output)
        #expect(throws: ExternalAIError.invalidResponse) { try ExternalAIGateway.summary(from: body) }
    }
}

@Test func summaryIncompleteReasonsAreSpecificAndNeverPublishPartialText() throws {
    let cases: [(String?, ExternalAIError)] = [("max_output_tokens", .summaryOutputLimitReached),
        ("content_filter", .summaryRefused), (nil, .summaryIncomplete),
        ("synthetic-private-provider-text", .summaryIncomplete)]
    for (reason, failure) in cases {
        for output in [[], [summaryMessage("Do not publish this partial answer.", status: "incomplete")]] {
            let body = try summaryResponse(status: "incomplete", reason: reason, output: output)
            #expect(throws: failure) { try ExternalAIGateway.summary(from: body) }
        }
        #expect(!failure.localizedDescription.contains("synthetic-private-provider-text"))
    }
}

@Test func summaryRefusalDoesNotBecomeSummaryTextOrLeakProviderDetails() throws {
    let body = try summaryResponse(output: [["type": "message", "role": "assistant", "status": "completed",
        "content": [["type": "output_text", "text": "Partial answer"],
                    ["type": "refusal", "refusal": "synthetic-private-provider-text"]]]])
    #expect(throws: ExternalAIError.summaryRefused) { try ExternalAIGateway.summary(from: body) }
    #expect(!ExternalAIError.summaryRefused.localizedDescription.contains("synthetic-private-provider-text"))
}

@Test func summaryReasoningCannotBypassUTF8OrResponseBounds() throws {
    let reasoning: [String: Any] = ["type": "reasoning", "summary": []]
    let oversized = try summaryResponse(output: [reasoning,
        summaryMessage(String(repeating: "🙂", count: ExternalAILimits.maximumSummaryBytes / 4 + 1))])
    #expect(throws: ExternalAIError.responseTooLarge) { try ExternalAIGateway.summary(from: oversized) }
    let oversizedReasoning = try summaryResponse(output: [["type": "reasoning", "summary": [
        ["type": "summary_text", "text": String(repeating: "a", count: ExternalAILimits.maximumResponseBytes)]]],
        summaryMessage("A summary.")])
    #expect(throws: ExternalAIError.responseTooLarge) { try ExternalAIGateway.summary(from: oversizedReasoning) }
}
