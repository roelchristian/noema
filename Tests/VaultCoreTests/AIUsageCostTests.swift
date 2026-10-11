import Foundation
import Testing
@testable import VaultCore

@Test func activityPricingIncludesCachedInputAndUsesEffectiveDate() throws {
    let first = try #require(AIUsagePrice(model: "test-model", effectiveFrom: Date(timeIntervalSince1970: 10),
        effectiveUntil: Date(timeIntervalSince1970: 20), inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 8))
    let next = try #require(AIUsagePrice(model: "test-model", effectiveFrom: Date(timeIntervalSince1970: 20),
        inputUSDPerMillion: 4, cachedInputUSDPerMillion: 1, outputUSDPerMillion: 16))
    let catalogue = AIUsagePricingCatalogue(version: "synthetic-test-v1", rates: [first, next])
    let usage = AIActivityUsage(inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 200)
    #expect(catalogue.estimatedCostUSD(model: "test-model", at: Date(timeIntervalSince1970: 15), usage: usage) == 0.0025)
    #expect(catalogue.estimatedCostUSD(model: "test-model", at: Date(timeIntervalSince1970: 20), usage: usage) == 0.005)
    #expect(catalogue.estimatedCostUSD(model: "test-model", at: Date(timeIntervalSince1970: 5), usage: usage) == nil)
    #expect(catalogue.estimatedCostUSD(model: "unknown", at: Date(timeIntervalSince1970: 15), usage: usage) == nil)
}

@Test func activityPricingPreservesUnknownUsageAndRates() throws {
    let price = try #require(AIUsagePrice(model: "test-model", effectiveFrom: .distantPast,
        inputUSDPerMillion: 2, outputUSDPerMillion: 8))
    let catalogue = AIUsagePricingCatalogue(version: "synthetic-test-v1", rates: [price])
    for usage in [AIActivityUsage(), AIActivityUsage(inputTokens: 10, outputTokens: 10),
                  AIActivityUsage(inputTokens: 10, outputTokens: 10, cachedInputTokens: 5),
                  AIActivityUsage(inputTokens: -1, outputTokens: 10, cachedInputTokens: 0)] {
        #expect(catalogue.estimatedCostUSD(model: "test-model", at: Date(), usage: usage) == nil)
    }
    let zero = AIActivityUsage(inputTokens: 0, outputTokens: 0, cachedInputTokens: 0)
    #expect(catalogue.estimatedCostUSD(model: "test-model", at: Date(), usage: zero) == 0)
    #expect(AIUsagePricingCatalogue.unpriced.estimatedCostUSD(model: "test-model", at: Date(), usage: zero) == nil)
    #expect(AIUsagePrice(model: "test-model", effectiveFrom: Date(), inputUSDPerMillion: .infinity, outputUSDPerMillion: 1) == nil)
    #expect(AIUsagePrice(model: "test-model", effectiveFrom: Date(), inputUSDPerMillion: 1, outputUSDPerMillion: -1) == nil)
}
