import Foundation

public enum LCCClassificationLevel: String, Codable, Sendable, CaseIterable {
    case `class`, subclass, schedule
}

/// Finite locally verified vocabulary. Numeric entries are exact schedule headings, never
/// acceptance of arbitrary syntactically plausible numbers or bibliographic shelf marks.
/// Source: Library of Congress Classification Outline, https://www.loc.gov/catdir/cpso/lcco/
/// Law includes the explicitly listed broad subdivisions and religious-law subclasses;
/// country-specific law schedules are deliberately outside this suggestion vocabulary.
/// Existing stored classifications and manually entered call numbers are not rewritten.
public enum LCCClassificationVocabulary {
    public static let outlineCodes: Set<String> = Set("""
        A AC AE AG AI AM AN AP AS AY AZ
        B BC BD BF BH BJ BL BM BP BQ BR BS BT BV BX
        C CB CC CD CE CJ CN CR CS CT
        D DA DAW DB DC DD DE DF DG DH DJ DJK DK DL DP DQ DR DS DT DU DX
        E F
        G GA GB GC GE GF GN GR GT GV
        H HA HB HC HD HE HF HG HJ HM HN HQ HS HT HV HX
        J JA JC JF JJ JK JL JN JQ JS JV JZ
        K KB KBM KBP KBR KBU KD KDZ KE KF KG KH KJ KK KL KZ
        L LA LB LC LD LE LF LG LH LJ LT
        M ML MT
        N NA NB NC ND NE NK NX
        P PA PB PC PD PE PF PG PH PJ PK PL PM PN PQ PR PS PT PZ
        Q QA QB QC QD QE QH QK QL QM QP QR
        R RA RB RC RD RE RF RG RJ RK RL RM RS RT RV RX RZ
        S SB SD SF SH SK
        T TA TC TD TE TF TG TH TJ TK TL TN TP TR TS TT TX
        U UA UB UC UD UE UF UG UH
        V VA VB VC VD VE VF VG VK VM
        Z ZA
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    // Exact entries verified in the Library of Congress 2025 Q schedule, pages 13 and 21–22.
    // https://www.loc.gov/aba/publications/FreeLCC/LCC_Q2025TEXT.pdf
    public static let scheduleCaptions: [String: String] = [
        "QA76": "Computer science: general works",
        "QA76.87": "Neural computers and neural networks",
        "QA76.875": "Artificial immune systems and immunocomputers",
        "QA76.88": "Supercomputers and high performance computing",
        "QA76.884": "Biocomputers",
        "QA76.885": "Petaflops computers",
        "QA76.887": "Molecular computers and DNA computers",
        "QA76.889": "Quantum computers",
        "QA76.89": "Pen-based computers",
        "QA76.893": "Tablet computers"
    ]
    public static let codes = outlineCodes.union(scheduleCaptions.keys)
    private static let classCaptions: [String: String] = [
        "A": "General works", "B": "Philosophy, psychology and religion", "C": "Auxiliary sciences of history",
        "D": "World history", "E": "History of the Americas", "F": "History of the Americas",
        "G": "Geography, anthropology and recreation", "H": "Social sciences", "J": "Political science",
        "K": "Law", "L": "Education", "M": "Music", "N": "Fine arts", "P": "Language and literature",
        "Q": "Science", "R": "Medicine", "S": "Agriculture", "T": "Technology", "U": "Military science",
        "V": "Naval science", "Z": "Bibliography, library science and information resources"
    ]
    private static let subclassCaptions: [String: String] = [
        "QA": "Mathematics", "QB": "Astronomy", "QC": "Physics", "QD": "Chemistry", "QE": "Geology",
        "QH": "Natural history and biology", "QK": "Botany", "QL": "Zoology", "QM": "Human anatomy",
        "QP": "Physiology", "QR": "Microbiology", "TX": "Home economics", "TK": "Electrical engineering",
        "PN": "Literature", "PS": "American literature", "PR": "English literature", "DG": "History of Italy"
    ]
    public static func level(for code: String) -> LCCClassificationLevel? {
        guard isAuthorized(code) else { return nil }
        if scheduleCaptions[code] != nil { return .schedule }
        return code.count == 1 ? .class : .subclass
    }
    public static func caption(for code: String) -> String? {
        guard isAuthorized(code) else { return nil }
        return scheduleCaptions[code] ?? subclassCaptions[code] ?? classCaptions[code]
            ?? classCaptions[String(code.prefix(1))].map { "\($0) — subclass \(code)" }
    }

    /// Remote structured outputs must match exactly, without whitespace or case repair.
    public static func isAuthorized(_ code: String) -> Bool { codes.contains(code) }

    /// Native legacy generation produces full call numbers. New suggestions may retain only
    /// their authorized subject prefix; this never changes an existing accepted classification.
    public static func suggestionCode(fromCallNumber text: String) -> String? {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.range(of: #"^[A-Z]{1,3}(?:[0-9]{1,4}(?:\.[A-Z0-9]+)*)?$"#,
                         options: .regularExpression) != nil else { return nil }
        if isAuthorized(code) { return code }
        let prefix = String(code.prefix(while: { $0.isLetter }))
        return isAuthorized(prefix) ? prefix : nil
    }
}
