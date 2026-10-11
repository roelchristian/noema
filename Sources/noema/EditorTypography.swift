import AppKit
import VaultCore

/// Configurable document typography. Application chrome remains in NoemaTypography.
@MainActor struct EditorTypography: Equatable {
    static let defaultSize = 16.0
    static let sizeRange = 10.0...32.0
    let family: String
    let size: Double

    enum Role: CaseIterable {
        case heading1, heading2, heading3, body, quote, list, code, mathSource, math, supporting

        var scale: CGFloat {
            switch self {
            case .heading1: 1.93
            case .heading2: 1.53
            case .heading3: 1.27
            case .code, .mathSource, .supporting: 0.88
            case .body, .quote, .list, .math: 1
            }
        }

        var weight: NSFont.Weight {
            switch self {
            case .heading1, .heading2, .heading3: .semibold
            default: .regular
            }
        }
    }

    init(family: String = "", size: Double = defaultSize) {
        self.family = family
        self.size = size.isFinite ? min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) : Self.defaultSize
    }

    static var current: Self { load() }

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(family: defaults.string(forKey: EditorPreferences.fontFamilyKey) ?? "",
             size: (defaults.object(forKey: EditorPreferences.fontSizeKey) as? Double) ?? defaultSize)
    }

    static func role(for kind: BlockKind) -> Role {
        switch kind {
        case .heading1: .heading1
        case .heading2: .heading2
        case .heading3: .heading3
        case .quote: .quote
        case .bullet, .numbered, .task, .toggle: .list
        case .code: .code
        case .math: .mathSource
        default: .body
        }
    }

    func pointSize(for role: Role) -> CGFloat { CGFloat(size) * role.scale }

    func font(for role: Role, weight: NSFont.Weight? = nil) -> NSFont {
        let weight = weight ?? role.weight
        let pointSize = pointSize(for: role)
        switch role {
        case .code, .mathSource:
            return .monospacedSystemFont(ofSize: pointSize, weight: weight)
        case .math:
            return mathematicalFont(ofSize: pointSize, weight: weight)
        default:
            return familyFont(ofSize: pointSize, weight: weight)
        }
    }

    /// Inline code scales with its surrounding role; math keeps that role's size.
    /// Explicit inline style remains separate from presentation-only heading weight.
    func font(for role: Role, style: InlineStyle) -> NSFont {
        let weight: NSFont.Weight = style.bold ? .bold : role.weight
        var font: NSFont
        if style.code {
            let pointSize = pointSize(for: role) * ([Role.code, .mathSource].contains(role) ? 1 : Role.code.scale)
            font = .monospacedSystemFont(ofSize: pointSize, weight: weight)
        } else if style.math {
            font = mathematicalFont(ofSize: pointSize(for: role), weight: weight)
        } else {
            font = self.font(for: role, weight: weight)
        }
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    // Compatibility for document callers that need a specific weight or offset.
    func font(offset: CGFloat = 0, weight: NSFont.Weight = .regular) -> NSFont {
        familyFont(ofSize: max(1, CGFloat(size) + offset), weight: weight)
    }

    private struct FamilyFontKey: Hashable {
        var family: String
        var size: CGFloat
        var weight: CGFloat
    }
    private static var familyFonts: [FamilyFontKey: NSFont] = [:]

    private func familyFont(ofSize pointSize: CGFloat, weight: NSFont.Weight) -> NSFont {
        let key = FamilyFontKey(family: family, size: pointSize, weight: weight.rawValue)
        if let cached = Self.familyFonts[key] { return cached }
        let font = resolveFamilyFont(ofSize: pointSize, weight: weight)
        Self.familyFonts[key] = font
        return font
    }

    private func resolveFamilyFont(ofSize pointSize: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard !family.isEmpty,
              let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else {
            return .systemFont(ofSize: pointSize, weight: weight)
        }
        // Select a real upright family face by its native descriptor weight. This
        // preserves Medium and Semibold where present, and deliberately uses the
        // nearest available face when a family has only Regular/Bold.
        let faces = members.compactMap { member -> NSFont? in
            guard let name = member.first as? String,
                  let font = NSFont(name: name, size: pointSize),
                  !NSFontManager.shared.traits(of: font).contains(.italicFontMask) else { return nil }
            return font
        }
        func distance(_ font: NSFont) -> CGFloat {
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            let native = CGFloat((traits?[.weight] as? NSNumber)?.doubleValue ?? Double(NSFont.Weight.regular.rawValue))
            return abs(native - weight.rawValue)
        }
        return faces.min { distance($0) < distance($1) }
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: pointSize)
            ?? .systemFont(ofSize: pointSize, weight: weight)
    }

    private func mathematicalFont(ofSize pointSize: CGFloat, weight: NSFont.Weight) -> NSFont {
        let descriptor = NSFont.systemFont(ofSize: pointSize, weight: weight).fontDescriptor.withDesign(.serif)
        let font = descriptor.flatMap { NSFont(descriptor: $0, size: pointSize) }
            ?? NSFont.systemFont(ofSize: pointSize, weight: weight)
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
}
