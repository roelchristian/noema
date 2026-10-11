import AppKit
import SwiftUI

@MainActor enum NoemaAbout {
    private static let blurb = """
    *Noema* (Greek νόημα) is, in its older philosophical sense, ‘that which is thought’: the object, content, or result of *noein*, to apprehend with the mind. It belongs to the same family as *nous*, intellect, and still carries something of the Greek confidence that thought might take hold of a thing by seeing it inwardly. In Plato and later Greek philosophy the word can mean a thought, conception, or object of understanding, before the term acquired the strange technical afterlife Husserl was to give it.

    For Husserl, the *noema* is not simply the thing thought about, nor a private image lodged somewhere in the mind, but the object precisely *as it is intended* in an act of consciousness. The tree seen from the window, the remembered house, the imagined city, are each given under a certain aspect or mode, and this structured ‘object-as-meant’ is noematic; opposed to it is the *noesis*, the intending act itself. Thus an old Greek word for what thought has before it becomes, in phenomenology, the delicate residue left when one asks not merely what a thing is, but how it appears to consciousness.

    *Noema* therefore marks a small but consequential migration in meaning: from the Greek ‘thought’ or ‘object of thought’ to Husserl’s intentional correlate, the world insofar as it is disclosed in a particular act of perceiving, remembering, judging, or imagining. One might say that the Greek word still looks toward the intelligible thing, whereas Husserl turns back toward the manner of its givenness; the same object may endure, yet its noema alters with distance, memory, doubt, expectation. It is a word for that peculiar interval in which the world remains before us, though never without the light, angle, and history by which we have come to see it.
    """

    static var paragraphs: [AttributedString] {
        blurb.components(separatedBy: "\n\n").map {
            (try? AttributedString(markdown: $0, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString($0)
        }
    }
}

struct NoemaAboutView: View {
    @Environment(\.noemaTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Noema").font(.largeTitle.bold())
                    Text("A personal atlas of thought.")
                        .foregroundStyle(theme.text(.textMuted, on: .background))
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text("Version \(version)").font(.caption)
                            .foregroundStyle(theme.text(.textMuted, on: .background))
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(NoemaAbout.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
                 ?? "© 2026 Roel Christian Yambao. All rights reserved.")
                .font(.caption)
                .foregroundStyle(theme.text(.textMuted, on: .background))
                .textSelection(.enabled)
        }
        .padding(28)
    }
}

// Keep the native title bar, closing and minimizing, while disabling resizing and fullscreen.
struct AboutWindowConstraints: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) { view.applyConstraints() }

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyConstraints()
        }

        func applyConstraints() {
            guard let window else { return }
            window.styleMask.remove(.resizable)
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}
