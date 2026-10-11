import Foundation

/// The finite class/subclass vocabulary authorized for AI suggestions. This is a supported
/// outline vocabulary, not validation of complete shelf marks or numeric schedule ranges.
/// Source: Library of Congress Classification Outline, https://www.loc.gov/catdir/cpso/lcco/
/// Law includes the explicitly listed broad subdivisions and religious-law subclasses;
/// country-specific law schedules are deliberately outside this suggestion vocabulary.
/// Existing stored classifications and manually entered call numbers are not rewritten.
public enum LCCClassificationVocabulary {
    public static let codes: Set<String> = Set("""
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

    /// Remote structured outputs must match exactly, without whitespace or case repair.
    public static func isAuthorized(_ code: String) -> Bool { codes.contains(code) }

    /// Native legacy generation produces full call numbers. New suggestions may retain only
    /// their authorized subject prefix; this never changes an existing accepted classification.
    public static func suggestionCode(fromCallNumber text: String) -> String? {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.range(of: #"^[A-Z]{1,3}(?:[0-9]{1,4}(?:\.[A-Z0-9]+)*)?$"#,
                         options: .regularExpression) != nil else { return nil }
        let prefix = String(code.prefix(while: { $0.isLetter }))
        return isAuthorized(prefix) ? prefix : nil
    }
}
