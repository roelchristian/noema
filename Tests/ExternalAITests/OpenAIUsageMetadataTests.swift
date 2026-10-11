import Foundation
import Testing
@testable import ExternalAI

@Test func gatewayUsageAllowsOnlyBoundedProviderCounters() {
    let body = Data(#"{"object":"response","status":"completed","usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":30}},"output":[{"text":"synthetic-private-response"}]}"#.utf8)
    let usage = ExternalAIGateway.reportedUsage(from: body)
    #expect(usage?.inputTokens == 100)
    #expect(usage?.outputTokens == 20)
    #expect(usage?.cachedInputTokens == 30)
    let noCache = ExternalAIGateway.reportedUsage(from: Data(#"{"object":"response","status":"completed","usage":{"input_tokens":100,"output_tokens":20}}"#.utf8))
    #expect(noCache?.cachedInputTokens == nil)
}

@Test func gatewayUsageRejectsInvalidCountersWithoutAffectingOutput() throws {
    for usage in [#"{"input_tokens":-1,"output_tokens":2}"#,
                  #"{"input_tokens":1000000001,"output_tokens":2}"#,
                  #"{"input_tokens":1.5,"output_tokens":2}"#,
                  #"{"input_tokens":"secret","output_tokens":2}"#,
                  #"{"input_tokens":true,"output_tokens":2}"#,
                  #"{"input_tokens":1,"output_tokens":2,"input_tokens_details":{"cached_tokens":3}}"#] {
        let body = Data("{\"object\":\"response\",\"status\":\"completed\",\"usage\":\(usage),\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Valid output\"}]}]}".utf8)
        #expect(ExternalAIGateway.reportedUsage(from: body) == nil)
        #expect(try ExternalAIGateway.summary(from: body) == "Valid output")
    }
    #expect(ExternalAIGateway.reportedUsage(from: Data(#"{"object":"other","status":"completed","usage":{"input_tokens":1,"output_tokens":2}}"#.utf8)) == nil)
}
