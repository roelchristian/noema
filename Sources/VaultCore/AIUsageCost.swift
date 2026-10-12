import Foundation

/// An explicitly versioned catalogue. No built-in prices are guessed for a model.
/// Rates are USD per million provider-reported tokens, not provider billing statements.
public struct AIUsagePricingCatalogue: Sendable {
    public let version: String
    public let rates: [AIUsagePrice]
    public static let unpriced = AIUsagePricingCatalogue(version: "unpriced-v1", rates: [])

    public init(version: String, rates: [AIUsagePrice]) {
        self.version = version
        self.rates = rates
    }

    public func estimatedCostUSD(model: String, at date: Date, usage: AIActivityUsage) -> Double? {
        guard let input = usage.inputTokens, let output = usage.outputTokens,
              input >= 0, output >= 0, date.timeIntervalSince1970.isFinite,
              let price = rates.filter({ $0.model == model && $0.effectiveFrom <= date
                  && ($0.effectiveUntil == nil || date < $0.effectiveUntil!) })
                .max(by: { $0.effectiveFrom < $1.effectiveFrom }) else { return nil }
        // Missing cache details must not silently charge cached input at the full rate.
        guard let cached = usage.cachedInputTokens, cached >= 0, cached <= input,
              cached == 0 || price.cachedInputUSDPerMillion != nil else { return nil }
        let total = (Double(input - cached) * price.inputUSDPerMillion
            + Double(cached) * (price.cachedInputUSDPerMillion ?? 0)
            + Double(output) * price.outputUSDPerMillion) / 1_000_000
        return total.isFinite && total >= 0 ? total : nil
    }
}

public struct AIUsagePrice: Sendable {
    public let model: String
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let inputUSDPerMillion: Double
    public let cachedInputUSDPerMillion: Double?
    public let outputUSDPerMillion: Double

    public init?(model: String, effectiveFrom: Date, effectiveUntil: Date? = nil,
                 inputUSDPerMillion: Double, cachedInputUSDPerMillion: Double? = nil,
                 outputUSDPerMillion: Double) {
        guard !model.isEmpty, model.utf8.count <= 100,
              model.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }),
              effectiveFrom.timeIntervalSince1970.isFinite,
              effectiveUntil.map({ $0.timeIntervalSince1970.isFinite && $0 > effectiveFrom }) ?? true,
              inputUSDPerMillion.isFinite, inputUSDPerMillion >= 0,
              outputUSDPerMillion.isFinite, outputUSDPerMillion >= 0,
              cachedInputUSDPerMillion.map({ $0.isFinite && $0 >= 0 }) ?? true else { return nil }
        self.model = model
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.inputUSDPerMillion = inputUSDPerMillion
        self.cachedInputUSDPerMillion = cachedInputUSDPerMillion
        self.outputUSDPerMillion = outputUSDPerMillion
    }
}
