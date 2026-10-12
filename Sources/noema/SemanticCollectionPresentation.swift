import SwiftUI
import AppKit
import VaultCore

extension SemanticPresentation {
    var key: String { id }
}


struct SemanticTypeFilterOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let count: Int

    init(id: String, title: String, symbol: String, count: Int) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.count = count
    }

    @MainActor
    init(id: String, count: Int) {
        let canonical = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let presentation = SemanticPresentation.find(canonical)
        self.id = canonical
        self.title = presentation?.title ?? canonical.capitalized
        self.symbol = presentation?.symbol ?? "tag"
        self.count = count
    }
}

enum SemanticCollectionPresentation {
    private struct Descriptor: Sendable {
        let key: String
        let title: String
        let symbol: String
    }

    private static let canonicalDescriptors: [Descriptor] = [
        .init(key: "question", title: "Question", symbol: "questionmark.circle"),
        .init(key: "idea", title: "Idea", symbol: "lightbulb"),
        .init(key: "important", title: "Important", symbol: "exclamationmark.circle"),
        .init(key: "starred", title: "Starred", symbol: "star"),
        .init(key: "definition", title: "Definition", symbol: "book"),
        .init(key: "example", title: "Example", symbol: "curlybraces"),
        .init(key: "insight", title: "Insight", symbol: "sparkles"),
        .init(key: "warning", title: "Warning", symbol: "exclamationmark.triangle"),
        .init(key: "reference", title: "Reference", symbol: "bookmark"),
        .init(key: "summary", title: "Summary", symbol: "list.bullet.rectangle")
    ]

    static func availableFilters(from rows: [SemanticBlockHit]) -> [SemanticTypeFilterOption] {
        var counts: [String: Int] = [:]
        for hit in rows {
            let key = hit.semantic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        guard !counts.isEmpty else { return [] }

        let descriptors: [Descriptor]
        if Thread.isMainThread {
            descriptors = MainActor.assumeIsolated {
                SemanticPresentation.all.map { Descriptor(key: $0.key, title: $0.title, symbol: $0.symbol) }
            }
        } else {
            descriptors = canonicalDescriptors
        }

        let descriptorByKey = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })
        let knownOrder = descriptors.map(\.key)
        let knownSet = Set(knownOrder)

        var options: [SemanticTypeFilterOption] = []
        for key in knownOrder {
            guard let count = counts[key], count > 0, let descriptor = descriptorByKey[key] else { continue }
            options.append(
                SemanticTypeFilterOption(
                    id: key,
                    title: descriptor.title,
                    symbol: descriptor.symbol,
                    count: count
                )
            )
        }

        let unknownKeys = counts.keys.filter { !knownSet.contains($0) }.sorted()
        for key in unknownKeys {
            guard let count = counts[key], count > 0 else { continue }
            options.append(
                SemanticTypeFilterOption(
                    id: key,
                    title: key.capitalized,
                    symbol: "tag",
                    count: count
                )
            )
        }

        return options
    }

    static func filteredRows(_ rows: [SemanticBlockHit], selectedSemantic: String?, selectedStatus: String? = nil) -> [SemanticBlockHit] {
        rows.filter { hit in
            let designationMatches = selectedSemantic.map { hit.semantic.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare($0) == .orderedSame } ?? true
            let statusMatches = selectedStatus.map { hit.status?.caseInsensitiveCompare($0) == .orderedSame } ?? true
            return designationMatches && statusMatches
        }
    }

    static func countLabel(filteredCount: Int, totalCount: Int, selectedSemantic: String?) -> String {
        if selectedSemantic == nil || filteredCount == totalCount {
            return "\(totalCount) semantic \(totalCount == 1 ? "block" : "blocks")"
        }
        return "\(filteredCount) of \(totalCount) semantic blocks"
    }

    static func statusLabel(for status: String?) -> String? {
        guard let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.capitalized
    }
}

struct SemanticBlockCollectionRow: View {
    let hit: SemanticBlockHit
    var status: String? = nil

    var body: some View {
        let canonical = hit.semantic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let presentation = SemanticPresentation.find(canonical) ?? SemanticPresentation.find(hit.semantic)
        let previewText = hit.preview.isEmpty
            ? "Empty block"
            : hit.preview.replacingOccurrences(of: "\n", with: " ")
        let typeTitle = presentation?.title ?? hit.semantic.trimmingCharacters(in: .whitespacesAndNewlines).capitalized

        HStack(alignment: .firstTextBaseline, spacing: NoemaSpacing.sm) {
            Image(systemName: presentation?.symbol ?? "tag")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color(nsColor: presentation?.accent ?? .secondaryLabelColor))
                .frame(width: NoemaMetrics.iconWidth, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(previewText)
                        .font(NoemaTypography.interfaceEmphasis)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let resolvedStatus = SemanticCollectionPresentation.statusLabel(for: status ?? hit.status) {
                        Text(resolvedStatus)
                            .font(NoemaTypography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(typeTitle)
                        .font(NoemaTypography.metadataEmphasis)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(hit.pageTitle)
                    .font(NoemaTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, NoemaSpacing.sm)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(typeTitle), \(hit.preview.isEmpty ? "Empty block" : hit.preview), in \(hit.pageTitle)")
    }
}

struct SemanticBlocksFilterBar: View {
    let options: [SemanticTypeFilterOption]
    @Binding var selectedSemantic: String?
    var busy: Bool = false

    var body: some View {
        HStack(spacing: NoemaSpacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("All Blocks") {
                        selectedSemantic = nil
                    }
                    .font(NoemaTypography.metadata)
                    .buttonStyle(.bordered)
                    .tint(selectedSemantic == nil ? .accentColor : nil)
                    .controlSize(.small)

                    ForEach(options) { option in
                        Button {
                            selectedSemantic = (selectedSemantic == option.id ? nil : option.id)
                        } label: {
                            Label(option.title, systemImage: option.symbol)
                        }
                        .font(NoemaTypography.metadata)
                        .buttonStyle(.bordered)
                        .tint(selectedSemantic == option.id ? .accentColor : nil)
                        .controlSize(.small)
                    }

                    if selectedSemantic != nil {
                        Button("Clear filter") {
                            selectedSemantic = nil
                        }
                        .font(NoemaTypography.metadata)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating library")
                    .accessibilityValue("In progress")
            }
        }
        .padding(.horizontal, NoemaSpacing.md)
        .padding(.vertical, 6)
    }
}
