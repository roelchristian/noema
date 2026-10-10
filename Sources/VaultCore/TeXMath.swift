import Foundation

public struct TeXMacro: Codable, Equatable, Identifiable, Sendable {
    public static let maxArguments = 3

    public var id: String { name }
    public var name: String
    public var argCount: Int
    public var body: String

    public var command: String { "\\" + name }

    public var newcommandString: String {
        if argCount > 0 {
            return "\\newcommand{\\\(name)}[\(argCount)]{\(body)}"
        }
        return "\\newcommand{\\\(name)}{\(body)}"
    }

    public init?(name: String, argCount: Int = 0, body: String) {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("\\") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isLetter && $0.isASCII }),
              (0...Self.maxArguments).contains(argCount) else { return nil }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty, Self.validPlaceholders(in: trimmedBody, maxArgs: argCount) else { return nil }
        self.name = cleaned
        self.argCount = argCount
        self.body = trimmedBody
    }

    private static func validPlaceholders(in body: String, maxArgs: Int) -> Bool {
        let chars = Array(body)
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count {
                index += 2
                continue
            }
            if chars[index] == "#", index + 1 < chars.count, let digit = chars[index + 1].wholeNumberValue {
                if digit < 1 || digit > maxArgs { return false }
                index += 2
                continue
            }
            index += 1
        }
        return true
    }

    public static func parseNewcommand(_ input: String) -> TeXMacro? {
        let (macros, remaining) = parseNewcommands(in: input)
        guard macros.count == 1, remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return macros.first
    }

    public static func parseNewcommands(in input: String) -> (macros: [TeXMacro], remaining: String) {
        let chars = Array(input)
        var index = 0
        var macros: [TeXMacro] = []
        var remaining = ""

        func skipSpaces(_ pos: inout Int) {
            while pos < chars.count && (chars[pos] == " " || chars[pos] == "\t") { pos += 1 }
        }

        func readBalancedBraces(_ pos: inout Int) -> String? {
            skipSpaces(&pos)
            guard pos < chars.count, chars[pos] == "{" else { return nil }
            pos += 1
            var depth = 1
            var content: [Character] = []
            while pos < chars.count && depth > 0 {
                let c = chars[pos]
                if c == "\\", pos + 1 < chars.count {
                    content.append(c)
                    content.append(chars[pos + 1])
                    pos += 2
                    continue
                }
                if c == "{" {
                    depth += 1
                    content.append(c)
                } else if c == "}" {
                    depth -= 1
                    if depth > 0 { content.append(c) }
                } else {
                    content.append(c)
                }
                pos += 1
            }
            return depth == 0 ? String(content) : nil
        }

        let prefix = Array("\\newcommand")
        while index < chars.count {
            if index + prefix.count <= chars.count && Array(chars[index..<(index + prefix.count)]) == prefix {
                var cursor = index + prefix.count
                if cursor < chars.count && chars[cursor] == "*" { cursor += 1 }
                skipSpaces(&cursor)
                var cmdName: String?
                if cursor < chars.count && chars[cursor] == "{" {
                    cmdName = readBalancedBraces(&cursor)
                } else if cursor < chars.count && chars[cursor] == "\\" {
                    cursor += 1
                    var letters: [Character] = []
                    while cursor < chars.count && chars[cursor].isLetter && chars[cursor].isASCII {
                        letters.append(chars[cursor])
                        cursor += 1
                    }
                    if !letters.isEmpty { cmdName = "\\" + String(letters) }
                }
                if let rawName = cmdName {
                    skipSpaces(&cursor)
                    var argCount = 0
                    var validArgs = true
                    if cursor < chars.count && chars[cursor] == "[" {
                        cursor += 1
                        var digits: [Character] = []
                        while cursor < chars.count && chars[cursor] != "]" {
                            digits.append(chars[cursor])
                            cursor += 1
                        }
                        if cursor < chars.count && chars[cursor] == "]" {
                            cursor += 1
                            if let parsed = Int(String(digits).trimmingCharacters(in: .whitespaces)),
                               (0...Self.maxArguments).contains(parsed) {
                                argCount = parsed
                            } else {
                                validArgs = false
                            }
                        } else {
                            validArgs = false
                        }
                    }
                    if validArgs, let body = readBalancedBraces(&cursor),
                       let macro = TeXMacro(name: rawName, argCount: argCount, body: body) {
                        if let existing = macros.firstIndex(where: { $0.name == macro.name }) {
                            macros[existing] = macro
                        } else {
                            macros.append(macro)
                        }
                        if cursor < chars.count && chars[cursor] == "\n" { cursor += 1 }
                        index = cursor
                        continue
                    }
                }
            }
            remaining.append(chars[index])
            index += 1
        }
        return (macros, remaining)
    }
}

public enum TeXMacroStore {
    public static let defaultsKey = "customTeXMacros"

    public static func load(from defaults: UserDefaults = .standard) -> [TeXMacro] {
        guard let raw = defaults.string(forKey: defaultsKey), !raw.isEmpty else { return [] }
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([TeXMacro].self, from: data) {
            return decoded
        }
        return TeXMacro.parseNewcommands(in: raw).macros
    }

    public static func save(_ macros: [TeXMacro], to defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(macros), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: defaultsKey)
        }
    }

    @discardableResult
    public static func upsert(_ macro: TeXMacro, in defaults: UserDefaults = .standard) -> [TeXMacro] {
        var macros = load(from: defaults)
        if let index = macros.firstIndex(where: { $0.name == macro.name }) {
            macros[index] = macro
        } else {
            macros.append(macro)
        }
        save(macros, to: defaults)
        return macros
    }

    @discardableResult
    public static func update(originalName: String, with macro: TeXMacro, in defaults: UserDefaults = .standard) -> [TeXMacro] {
        let cleanedOriginal = originalName.hasPrefix("\\") ? String(originalName.dropFirst()) : originalName
        var macros = load(from: defaults)
        if let originalIndex = macros.firstIndex(where: { $0.name == cleanedOriginal }) {
            macros[originalIndex] = macro
            if cleanedOriginal != macro.name {
                macros.enumerated().reversed().forEach { idx, item in
                    if idx != originalIndex && item.name == macro.name {
                        macros.remove(at: idx)
                    }
                }
            }
        } else if let existingIndex = macros.firstIndex(where: { $0.name == macro.name }) {
            macros[existingIndex] = macro
        } else {
            macros.append(macro)
        }
        save(macros, to: defaults)
        return macros
    }

    @discardableResult
    public static func updateFromNewcommand(originalName: String, _ input: String, in defaults: UserDefaults = .standard) -> [TeXMacro]? {
        guard let macro = TeXMacro.parseNewcommand(input) else { return nil }
        return update(originalName: originalName, with: macro, in: defaults)
    }

    @discardableResult
    public static func remove(name: String, in defaults: UserDefaults = .standard) -> [TeXMacro] {
        let cleaned = name.hasPrefix("\\") ? String(name.dropFirst()) : name
        var macros = load(from: defaults)
        macros.removeAll { $0.name == cleaned }
        save(macros, to: defaults)
        return macros
    }

    public static func addFromNewcommand(_ input: String, in defaults: UserDefaults = .standard) -> [TeXMacro]? {
        let (parsed, remaining) = TeXMacro.parseNewcommands(in: input)
        guard !parsed.isEmpty, remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var current = load(from: defaults)
        for macro in parsed {
            if let index = current.firstIndex(where: { $0.name == macro.name }) {
                current[index] = macro
            } else {
                current.append(macro)
            }
        }
        save(current, to: defaults)
        return current
    }
}

public enum TeXMath {
    public static func expand(_ tex: String, macros: [TeXMacro] = TeXMacroStore.load()) -> String {
        let (inlineMacros, stripped) = TeXMacro.parseNewcommands(in: tex)
        var table: [String: TeXMacro] = [:]
        for macro in macros { table[macro.name] = macro }
        for macro in inlineMacros { table[macro.name] = macro }
        guard !table.isEmpty else { return stripped.trimmingCharacters(in: .whitespacesAndNewlines) }

        var current = stripped
        for _ in 0..<16 {
            let next = expandOnce(current, table: table)
            if next == current { break }
            current = next
        }
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expandOnce(_ input: String, table: [String: TeXMacro]) -> String {
        let chars = Array(input)
        var index = 0
        var output = ""

        func skipSpaces(_ pos: inout Int) {
            while pos < chars.count && (chars[pos] == " " || chars[pos] == "\t") { pos += 1 }
        }

        func readArgument(_ pos: inout Int) -> String? {
            skipSpaces(&pos)
            guard pos < chars.count else { return nil }
            if chars[pos] == "{" {
                pos += 1
                var depth = 1
                var content: [Character] = []
                while pos < chars.count && depth > 0 {
                    let c = chars[pos]
                    if c == "\\", pos + 1 < chars.count {
                        content.append(c)
                        content.append(chars[pos + 1])
                        pos += 2
                        continue
                    }
                    if c == "{" {
                        depth += 1
                        content.append(c)
                    } else if c == "}" {
                        depth -= 1
                        if depth > 0 { content.append(c) }
                    } else {
                        content.append(c)
                    }
                    pos += 1
                }
                return depth == 0 ? String(content) : nil
            } else if chars[pos] == "\\" {
                pos += 1
                var token = "\\"
                if pos < chars.count && chars[pos].isLetter && chars[pos].isASCII {
                    while pos < chars.count && chars[pos].isLetter && chars[pos].isASCII {
                        token.append(chars[pos])
                        pos += 1
                    }
                } else if pos < chars.count {
                    token.append(chars[pos])
                    pos += 1
                }
                return token
            } else {
                let c = String(chars[pos])
                pos += 1
                return c
            }
        }

        while index < chars.count {
            if chars[index] == "\\" {
                var cursor = index + 1
                var letters: [Character] = []
                while cursor < chars.count && chars[cursor].isLetter && chars[cursor].isASCII {
                    letters.append(chars[cursor])
                    cursor += 1
                }
                let name = String(letters)
                if !name.isEmpty, let macro = table[name] {
                    var argCursor = cursor
                    var args: [String] = []
                    var ok = true
                    for _ in 0..<macro.argCount {
                        if let arg = readArgument(&argCursor) {
                            args.append(arg)
                        } else {
                            ok = false
                            break
                        }
                    }
                    if ok {
                        output += substitute(body: macro.body, args: args)
                        index = argCursor
                        continue
                    }
                }
            }
            output.append(chars[index])
            index += 1
        }
        return output
    }

    private static func substitute(body: String, args: [String]) -> String {
        let chars = Array(body)
        var index = 0
        var result = ""
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count {
                result.append(chars[index])
                result.append(chars[index + 1])
                index += 2
                continue
            }
            if chars[index] == "#", index + 1 < chars.count,
               let digit = chars[index + 1].wholeNumberValue,
               digit >= 1 && digit <= args.count {
                result += args[digit - 1]
                index += 2
                continue
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }

    public static func render(_ tex: String, display: Bool = false, macros: [TeXMacro] = TeXMacroStore.load()) -> String {
        let expanded = expand(tex, macros: macros)
        guard !expanded.isEmpty else { return "" }
        let rendered = renderExpression(expanded)
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
        "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "div": "÷", "pm": "±", "mp": "∓", "cdot": "·", "ast": "∗", "star": "⋆",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝",
        "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃", "nexists": "∄",
        "neg": "¬", "lnot": "¬", "land": "∧", "lor": "∨",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⇔", "implies": "⇒", "mapsto": "↦",
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "oplus": "⊕", "otimes": "⊗", "odot": "⊙", "perp": "⊥", "parallel": "∥", "angle": "∠",
        "triangle": "△", "Box": "□", "square": "□", "circ": "∘", "bullet": "•",
        "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        "aleph": "ℵ", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "wp": "℘",
        "sin": "sin", "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec", "csc": "csc",
        "log": "log", "ln": "ln", "exp": "exp", "lim": "lim", "sup": "sup", "inf": "inf",
        "min": "min", "max": "max", "det": "det", "dim": "dim", "ker": "ker", "deg": "deg", "gcd": "gcd",
        "quad": "  ", "qquad": "    "
    ]

    private static let blackboardBold: [Character: String] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
        "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
        "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
        "V": "𝕍", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ", "1": "𝟙"
    ]

    private static let calligraphic: [Character: String] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ", "G": "𝒢",
        "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ", "M": "ℳ", "N": "𝒩",
        "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ", "S": "𝒮", "T": "𝒯", "U": "𝒰",
        "V": "𝒱", "W": "𝒲", "X": "𝒳", "Y": "𝒴", "Z": "𝒵"
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "T": "ᵀ", "x": "ˣ", "y": "ʸ"
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ",
        "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
    ]

    private static func renderExpression(_ input: String) -> String {
        let chars = Array(input)
        var index = 0
        var out = ""

        func skipSpaces(_ pos: inout Int) {
            while pos < chars.count && (chars[pos] == " " || chars[pos] == "\t") { pos += 1 }
        }

        func readGroup(_ pos: inout Int) -> String? {
            skipSpaces(&pos)
            guard pos < chars.count else { return nil }
            if chars[pos] == "{" {
                pos += 1
                var depth = 1
                var content: [Character] = []
                while pos < chars.count && depth > 0 {
                    let c = chars[pos]
                    if c == "\\", pos + 1 < chars.count {
                        content.append(c)
                        content.append(chars[pos + 1])
                        pos += 2
                        continue
                    }
                    if c == "{" {
                        depth += 1
                        content.append(c)
                    } else if c == "}" {
                        depth -= 1
                        if depth > 0 { content.append(c) }
                    } else {
                        content.append(c)
                    }
                    pos += 1
                }
                return depth == 0 ? String(content) : nil
            } else if chars[pos] == "\\" {
                pos += 1
                var token = "\\"
                if pos < chars.count && chars[pos].isLetter && chars[pos].isASCII {
                    while pos < chars.count && chars[pos].isLetter && chars[pos].isASCII {
                        token.append(chars[pos])
                        pos += 1
                    }
                } else if pos < chars.count {
                    token.append(chars[pos])
                    pos += 1
                }
                return token
            } else {
                let c = String(chars[pos])
                pos += 1
                return c
            }
        }

        func readOptionalBracket(_ pos: inout Int) -> String? {
            var copy = pos
            skipSpaces(&copy)
            guard copy < chars.count, chars[copy] == "[" else { return nil }
            copy += 1
            var content: [Character] = []
            while copy < chars.count && chars[copy] != "]" {
                content.append(chars[copy])
                copy += 1
            }
            guard copy < chars.count, chars[copy] == "]" else { return nil }
            pos = copy + 1
            return String(content)
        }

        func parenthesizeIfCompound(_ s: String) -> String {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.count <= 2 || (!trimmed.contains(" ") && !trimmed.contains("+") && !trimmed.contains("-")) {
                return trimmed
            }
            return "(\(trimmed))"
        }

        while index < chars.count {
            let c = chars[index]
            if c == "\\" {
                index += 1
                guard index < chars.count else { break }
                if !chars[index].isLetter || !chars[index].isASCII {
                    let esc = chars[index]
                    index += 1
                    switch esc {
                    case "{": out.append("{")
                    case "}": out.append("}")
                    case ",", ";", ":": out.append(" ")
                    case "!": break
                    case "\\": out.append("\n")
                    case "$", "%", "&", "_", "#": out.append(esc)
                    default: out.append(esc)
                    }
                    continue
                }
                var cmdChars: [Character] = []
                while index < chars.count && chars[index].isLetter && chars[index].isASCII {
                    cmdChars.append(chars[index])
                    index += 1
                }
                let cmd = String(cmdChars)
                switch cmd {
                case "left", "right":
                    skipSpaces(&index)
                    if index < chars.count && chars[index] == "." { index += 1 }
                case "frac", "dfrac", "tfrac":
                    if let num = readGroup(&index), let den = readGroup(&index) {
                        let rNum = renderExpression(num)
                        let rDen = renderExpression(den)
                        out += "\(parenthesizeIfCompound(rNum))/\(parenthesizeIfCompound(rDen))"
                    } else {
                        out += "\\\(cmd)"
                    }
                case "binom":
                    if let n = readGroup(&index), let k = readGroup(&index) {
                        out += "(\(renderExpression(n)) choose \(renderExpression(k)))"
                    }
                case "sqrt":
                    let root = readOptionalBracket(&index)
                    if let rad = readGroup(&index) {
                        let renderedRad = renderExpression(rad)
                        let prefix: String
                        if let root {
                            let renderedRoot = renderExpression(root)
                            prefix = formatSuperscript(renderedRoot) + "√"
                        } else {
                            prefix = "√"
                        }
                        out += renderedRad.count == 1 ? "\(prefix)\(renderedRad)" : "\(prefix)(\(renderedRad))"
                    }
                case "mathbb":
                    if let arg = readGroup(&index) {
                        out += arg.map { blackboardBold[$0] ?? String($0) }.joined()
                    }
                case "mathcal":
                    if let arg = readGroup(&index) {
                        out += arg.map { calligraphic[$0] ?? String($0) }.joined()
                    }
                case "text", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "operatorname":
                    if let arg = readGroup(&index) {
                        out += renderExpression(arg)
                    }
                case "hat":
                    if let arg = readGroup(&index) { out += renderExpression(arg) + "\u{0302}" }
                case "bar", "overline":
                    if let arg = readGroup(&index) { out += renderExpression(arg) + "\u{0304}" }
                case "vec":
                    if let arg = readGroup(&index) { out += renderExpression(arg) + "\u{20D7}" }
                case "tilde":
                    if let arg = readGroup(&index) { out += renderExpression(arg) + "\u{0303}" }
                case "dot":
                    if let arg = readGroup(&index) { out += renderExpression(arg) + "\u{0307}" }
                default:
                    if let sym = symbols[cmd] {
                        out += sym
                    } else {
                        out += "\\" + cmd
                    }
                }
            } else if c == "^" {
                index += 1
                if let group = readGroup(&index) {
                    let rendered = renderExpression(group)
                    out += formatSuperscript(rendered)
                }
            } else if c == "_" {
                index += 1
                if let group = readGroup(&index) {
                    let rendered = renderExpression(group)
                    out += formatSubscript(rendered)
                }
            } else if c == "{" || c == "}" {
                index += 1
            } else {
                out.append(c)
                index += 1
            }
        }
        return out
    }

    private static func formatSuperscript(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var mapped = ""
        for ch in text {
            guard let sup = superscripts[ch] else {
                return text.count == 1 ? "^\(text)" : "^(\(text))"
            }
            mapped.append(sup)
        }
        return mapped
    }

    private static func formatSubscript(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var mapped = ""
        for ch in text {
            guard let sub = subscripts[ch] else {
                return text.count == 1 ? "_\(text)" : "_(\(text))"
            }
            mapped.append(sub)
        }
        return mapped
    }
}
