import AppKit

@MainActor struct EditorTypography: Equatable {
    static let defaultSize = 15.0
    static let sizeRange = 10.0...32.0
    let family: String
    let size: Double

    init(family: String = "", size: Double = defaultSize) {
        self.family = family
        self.size = size.isFinite ? min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) : Self.defaultSize
    }

    static var current: Self {
        load()
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        return Self(family: defaults.string(forKey: EditorPreferences.fontFamilyKey) ?? "",
                    size: (defaults.object(forKey: EditorPreferences.fontSizeKey) as? Double) ?? defaultSize)
    }

    func font(offset: CGFloat = 0, weight: NSFont.Weight = .regular) -> NSFont {
        let pointSize = CGFloat(size) + offset
        guard !family.isEmpty,
              let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: pointSize) else {
            return .systemFont(ofSize: pointSize, weight: weight)
        }
        return weight == .regular ? font : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
}
