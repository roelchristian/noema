import AppKit

@MainActor enum NoemaAbout {
    private static let blurb = """
    A personal atlas of thought.

    *Noema* (Greek νόημα) is, in its older philosophical sense, ‘that which is thought’: the object, content, or result of *noein*, to apprehend with the mind. It belongs to the same family as *nous*, intellect, and still carries something of the Greek confidence that thought might take hold of a thing by seeing it inwardly. In Plato and later Greek philosophy the word can mean a thought, conception, or object of understanding, before the term acquired the strange technical afterlife Husserl was to give it.

    For Husserl, the *noema* is not simply the thing thought about, nor a private image lodged somewhere in the mind, but the object precisely *as it is intended* in an act of consciousness. The tree seen from the window, the remembered house, the imagined city, are each given under a certain aspect or mode, and this structured ‘object-as-meant’ is noematic; opposed to it is the *noesis*, the intending act itself. Thus an old Greek word for what thought has before it becomes, in phenomenology, the delicate residue left when one asks not merely what a thing is, but how it appears to consciousness.

    *Noema* therefore marks a small but consequential migration in meaning: from the Greek ‘thought’ or ‘object of thought’ to Husserl’s intentional correlate, the world insofar as it is disclosed in a particular act of perceiving, remembering, judging, or imagining. One might say that the Greek word still looks toward the intelligible thing, whereas Husserl turns back toward the manner of its givenness; the same object may endure, yet its noema alters with distance, memory, doubt, expectation. It is a word for that peculiar interval in which the world remains before us, though never without the light, angle, and history by which we have come to see it.
    """

    static var credits: NSAttributedString {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let result = NSMutableAttributedString(string: "")
        // The fixed copy uses asterisks only for italic spans.
        for (index, fragment) in blurb.components(separatedBy: "*").enumerated() {
            result.append(NSAttributedString(string: fragment, attributes: [
                .font: index.isMultiple(of: 2) ? font : italicFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}
