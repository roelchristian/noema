import SwiftUI
import VaultCore

struct ContentView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var showTrashConfirmation = false
    @State private var sourceOriginal = false
    var body: some View {
        Group {
            if model.root == nil { welcome }
            else {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
                } content: {
                    library.navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
                } detail: { detail }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .toolbar {
            if model.root != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.scope == .sources {
                        Button { model.importFiles() } label: { Label("Import source", systemImage: "square.and.arrow.down") }
                        Button { model.showPasteSource = true } label: { Label("Paste source", systemImage: "doc.on.clipboard") }
                    } else {
                        Menu {
                            Button("Blank wiki page") { model.newPage() }
                            Button("Personal page template") { model.newPage(template: true) }
                        } label: { Label("New page", systemImage: "plus") }
                    }
                    Menu {
                        Button("Open another vault…") { model.chooseVault(create: false) }
                        Button("Reveal vault in Finder") { model.revealVault() }
                        Button("Refresh from files") { Task { await model.refresh() } }
                        Button("Vault notices (\(model.issues.count))") { model.showIssues = true }
                        Button("Recover drafts (\(model.recoveredDrafts.count))") { model.showRecovery = true }.disabled(model.recoveredDrafts.isEmpty)
                    } label: { Label("Vault options", systemImage: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $model.showPasteSource) { PasteSourceSheet(model: model) }
        .sheet(isPresented: $model.showRecovery) { recoverySheet }
        .sheet(isPresented: $model.showIssues) { noticesSheet }
        .sheet(isPresented: Binding(get: { !model.ambiguousMatches.isEmpty }, set: { if !$0 { model.ambiguousMatches = [] } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose a page").font(.title2.bold())
                Text("More than one page matches this title or alias.").foregroundStyle(.secondary)
                ForEach(model.ambiguousMatches) { note in
                    Button { model.ambiguousMatches = []; model.select(note.id) } label: { VStack(alignment: .leading) { Text(note.title); Text(note.relativePath).font(.caption).foregroundStyle(.secondary) } }
                }
                Button("Cancel") { model.ambiguousMatches = [] }.keyboardShortcut(.cancelAction)
            }.padding(28).frame(width: 440)
        }
        .alert("Create this page?", isPresented: Binding(get: { model.unresolvedTarget != nil }, set: { if !$0 { model.unresolvedTarget = nil } })) {
            Button("Create") { if let name = model.unresolvedTarget { model.newPage(named: name) }; model.unresolvedTarget = nil }
            Button("Cancel", role: .cancel) { model.unresolvedTarget = nil }
        } message: { Text("‘\(model.unresolvedTarget ?? "")’ does not exist yet.") }
        .confirmationDialog("Move this page to vault trash?", isPresented: $showTrashConfirmation) {
            Button("Move to Trash", role: .destructive) { model.trashCurrent() }
        } message: { Text("The Markdown file stays recoverable in the vault’s .Trash folder.") }
        .onChange(of: model.searchText) { model.queryChanged() }
        .onChange(of: model.searchFocusToken) { searchFocused = true }
    }
    private var welcome: some View {
        VStack(spacing: 24) {
            Image(systemName: "books.vertical").font(.system(size: 64, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text("noema").font(.system(size: 34, weight: .semibold))
                Text("A personal atlas of thought.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button("Create a vault…") { model.chooseVault(create: true) }.buttonStyle(.glassProminent)
                Button("Open a vault…") { model.chooseVault(create: false) }.buttonStyle(.glass)
            }.controlSize(.large)
            Text("Choose a folder on your Mac or in iCloud Drive. Your files stay yours.")
                .font(.callout).foregroundStyle(.secondary)
            if model.busy { ProgressView() }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).frame(maxWidth: 560).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sidebar: some View {
        List(selection: Binding(get: { Optional(model.scope) }, set: { if let scope = $0 { model.changeScope(scope) } })) {
            Section("Library") {
                Label("Wiki", systemImage: "book.closed").badge(model.notes.count).tag(LibraryScope.wiki)
                Label("Sources", systemImage: "tray.full").badge(model.sources.count).tag(LibraryScope.sources)
            }
            if !model.tags.isEmpty {
                Section("Topics") { ForEach(model.tags, id: \.self) { tag in Label(tag, systemImage: "number").tag(LibraryScope.tag(tag)) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.recoveredDrafts.isEmpty {
                    Button { model.showRecovery = true } label: { Label("\(model.recoveredDrafts.count) recoverable draft(s)", systemImage: "clock.arrow.circlepath") }.buttonStyle(.plain).foregroundStyle(.orange)
                }
                if !model.issues.isEmpty {
                    Button { model.showIssues = true } label: { Label("\(model.issues.count) vault notice(s)", systemImage: "info.circle") }.buttonStyle(.plain)
                }
                Button { model.chooseVault(create: false) } label: {
                    HStack { Label(model.vaultName, systemImage: "folder").lineLimit(1); Spacer(); Image(systemName: "chevron.up.chevron.down") }
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).help("Open another vault")
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var library: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(model.scopeTitle).font(.title2.bold()); Spacer(); if model.busy { ProgressView().controlSize(.small) } }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(model.scope == .sources ? "sources" : "wiki")", text: $model.searchText).textFieldStyle(.plain).focused($searchFocused)
                    if !model.searchText.isEmpty { Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            }.padding(18)
            Divider()
            if model.rows.isEmpty {
                ContentUnavailableView(model.searchText.isEmpty ? "\(model.scopeTitle) is empty" : "No matches", systemImage: model.scope == .sources ? "tray" : "doc.text.magnifyingglass", description: Text(model.searchText.isEmpty ? (model.scope == .sources ? "Import a text file or paste a source to begin." : "Create a page to start building your wiki.") : "Try another word or topic."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title).font(.headline).lineLimit(1)
                            Text(row.excerpt.replacingOccurrences(of: "\n", with: " ")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            if !row.tags.isEmpty { Text(row.tags.prefix(3).map { "#" + $0 }.joined(separator: "  ")).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                        }.padding(.vertical, 7).tag(row.id)
                    }
                }.listStyle(.plain)
            }
            HStack { Text(libraryCount); Spacer(); Text("⌘K") }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
    }
    @ViewBuilder private var detail: some View {
        if model.currentNote != nil || model.currentSource != nil {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                        if model.externalChange {
                            HStack {
                                Button("Reload disk version") { model.reloadDiskVersion() }
                                Button("Save draft as new page") { model.saveDraftAsNewPage() }
                            }
                        } else if model.currentNote != nil { Button("Try saving again") { model.saveNow() } }
                        else { Button("Dismiss") { model.errorMessage = nil } }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12))
                } else if model.externalChange {
                    HStack {
                        Label("This page changed or moved outside the app.", systemImage: "arrow.triangle.2.circlepath")
                        Spacer(); Button("Reload") { model.reloadDiskVersion() }
                        Button("Save a copy") { model.saveDraftAsNewPage() }
                    }.font(.callout).padding(12).background(.orange.opacity(0.12))
                }
                pageHeader
                Divider()
                ZStack(alignment: .topLeading) {
                    if let source = model.currentSource, sourceOriginal || source.metadata.storedFilename.hasSuffix(".txt") {
                        MarkdownEditor(text: .constant(model.body), action: nil, onWikiQuery: { _ in }, editable: false)
                    } else if model.reading || model.currentSource != nil { MarkdownPreview(blocks: model.preview, onWikiLink: model.followWikiLink) }
                    else { MarkdownEditor(text: $model.body, action: model.editorAction, onWikiQuery: { model.wikiQuery = $0 }) }
                    if !model.reading, model.currentNote != nil, model.wikiQuery != nil, !model.linkSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LINK A PAGE").font(.caption2).foregroundStyle(.secondary).padding(8)
                            ForEach(model.linkSuggestions) { note in
                                Button { model.suggestLink(note.title) } label: { Label(note.title, systemImage: "link").frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(.plain)
                            }
                        }.padding(6).frame(width: 270).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 10, y: 4).padding(16)
                    }
                }.frame(maxWidth: 980).frame(maxWidth: .infinity)
                if model.currentNote != nil { pageFooter }
            }
            .onChange(of: model.body) { model.edited() }
            .onChange(of: model.title) { model.edited() }
            .onChange(of: model.tagInput) { model.edited() }
            .onChange(of: model.reading) { if model.reading { model.generatePreview() } }
        } else {
            VStack(spacing: 18) {
                Image(systemName: model.scope == .sources ? "tray.full" : "book.pages").font(.system(size: 48, weight: .light)).foregroundStyle(.tertiary)
                Text(model.scope == .sources ? "Keep the original. Find your meaning." : "A personal atlas of thought.").font(.title2.weight(.medium))
                Text(model.scope == .sources ? "Browse raw material here. Your interpretations belong in the wiki." : "Choose a page, or start with a thought you want to connect.").foregroundStyle(.secondary)
                if model.scope != .sources { Button("New personal page") { model.newPage(template: true) }.buttonStyle(.glass) }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: 500) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var libraryCount: String {
        let count = model.rows.count
        let noun = model.scope == .sources ? (count == 1 ? "source" : "sources") : (count == 1 ? "page" : "pages")
        return "\(count) \(noun)"
    }
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.currentSource == nil ? "PERSONAL WIKI" : "RAW SOURCE", systemImage: model.currentSource == nil ? "book.closed" : "tray.full")
                    .font(.caption.weight(.medium)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                if model.currentNote != nil {
                    Picker("View", selection: $model.reading) { Text("Edit").tag(false); Text("Read").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 140)
                    Button { showTrashConfirmation = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Move page to vault trash")
                } else {
                    if model.currentSource?.metadata.storedFilename.hasSuffix(".md") == true {
                        Picker("Source view", selection: $sourceOriginal) { Text("Read").tag(false); Text("Original").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 160)
                    }
                    Label("Read only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.currentNote != nil {
                TextField("Page title", text: $model.title).textFieldStyle(.plain).font(.system(size: 32, weight: .semibold))
                HStack {
                    Image(systemName: "number").foregroundStyle(.secondary)
                    TextField("Topics, separated by commas", text: $model.tagInput).textFieldStyle(.plain).font(.callout)
                }
                if let note = model.currentNote, !note.allTags.isEmpty {
                    HStack { ForEach(note.allTags.prefix(8), id: \.self) { tag in Button("#" + tag) { model.changeScope(.tag(tag)) }.font(.caption).buttonStyle(.bordered).controlSize(.small) } }
                }
            } else {
                Text(model.title).font(.system(size: 32, weight: .semibold)).textSelection(.enabled)
                if let source = model.currentSource {
                    HStack {
                        Text(source.metadata.originalFilename)
                        Text("· Imported " + String(source.metadata.capturedAt.prefix(10)))
                        if let address = source.metadata.originURL, let url = URL(string: address) { Link("Original URL", destination: url) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(28)
    }
    private var pageFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.backlinks.isEmpty {
                HStack(alignment: .top) {
                    Text("Linked from").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(model.backlinks) { note in Button(note.title) { model.select(note.id) }.buttonStyle(.link).font(.caption) } }
                    }
                }
            }
            HStack {
                Label(model.saveStatus, systemImage: model.dirty ? "circle.dotted" : "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.wordCount) words").font(.caption).foregroundStyle(.secondary)
                if !model.reading {
                    Button { model.format("**", "**") } label: { Image(systemName: "bold") }.help("Bold · ⌘B")
                    Button { model.format("*", "*") } label: { Image(systemName: "italic") }.help("Italic · ⌘I")
                    Button { model.format("[[", "]]") } label: { Image(systemName: "link") }.help("Wiki link")
                }
            }.buttonStyle(.borderless)
        }.padding(.horizontal, 28).padding(.vertical, 14).background(.background)
    }
    private var recoverySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recoverable drafts").font(.title2.bold())
            Text("Create a new page from a draft to keep the disk version intact.").foregroundStyle(.secondary)
            List(model.recoveredDrafts) { draft in
                VStack(alignment: .leading, spacing: 8) {
                    Text(draft.title).font(.headline)
                    Text(draft.body.prefix(240)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Recover as new page") { model.saveDraftAsNewPage(draft) }
                        Button("Discard draft", role: .destructive) { model.discardRecovery(draft) }
                    }
                }.padding(.vertical, 8)
            }
            Button("Done") { model.showRecovery = false }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 580, height: 480)
    }
    private var noticesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vault notices").font(.title2.bold())
            if model.issues.isEmpty { Text("Your vault is up to date locally.").foregroundStyle(.secondary) }
            List(model.issues, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
            HStack { Button("Reveal vault") { model.revealVault() }; Spacer(); Button("Done") { model.showIssues = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 580, height: 420)
    }
}

struct PasteSourceSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var url = ""
    @State private var importing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preserve a source").font(.title2.bold())
            Text("Store the original text here. Write your understanding in the wiki.").foregroundStyle(.secondary)
            TextField("Source title", text: $title)
            TextField("Original URL (optional)", text: $url)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).border(.quaternary)
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save source") {
                    importing = true
                    Task { if await model.pasteSource(title: title, text: text, originURL: url) { dismiss() }; importing = false }
                }.buttonStyle(.borderedProminent).disabled(text.isEmpty || importing).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 660, height: 540)
    }
}
