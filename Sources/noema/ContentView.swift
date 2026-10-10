import SwiftUI
import VaultCore

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.noemaTheme) private var theme
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
                if model.currentNote != nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { if model.reading { model.beginEditing() } else { model.finishEditing() } } label: {
                            Label(model.reading ? "Edit" : "Done", systemImage: model.reading ? "pencil" : "checkmark")
                        }.disabled(model.editingLocked)
                        Button { showTrashConfirmation = true } label: {
                            Label("Move page to vault trash", systemImage: "trash")
                        }.help("Move page to vault trash")
                    }
                } else if model.currentSource?.metadata.storedFilename.hasSuffix(".md") == true {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Source view", selection: $sourceOriginal) {
                            Text("Read").tag(false)
                            Text("Original").tag(true)
                        }.pickerStyle(.segmented).frame(minWidth: 160)
                    }
                }
                if model.currentNote != nil || model.currentSource?.metadata.storedFilename.hasSuffix(".md") == true {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.scope == .sources {
                        Button { model.importFiles() } label: { Label("Import source", systemImage: "square.and.arrow.down") }
                        Button { model.showPasteSource = true } label: { Label("Paste source", systemImage: "doc.on.clipboard") }
                    } else {
                        Menu {
                            Button("Blank wiki page") { model.newPage() }
                            Button("Personal page template") { model.newPage(template: true) }
                        } label: { Label("New page", systemImage: "plus") }
                            .accessibilityLabel("New page")
                    }
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Open another vault…") { model.chooseVault(create: false) }
                        Button { model.revealVault() } label: { Label("Reveal vault in Finder", systemImage: "folder") }
                        Button { Task { await model.refresh() } } label: { Label("Refresh from files", systemImage: "arrow.clockwise") }
                        Button("Vault notices (\(model.issues.count))") { model.showIssues = true }
                        Button("Recover drafts (\(model.recoveredDrafts.count))") { model.showRecovery = true }.disabled(model.recoveredDrafts.isEmpty)
                    } label: { Label("Vault options", systemImage: "ellipsis.circle") }
                        .accessibilityLabel("Vault options")
                }
            }
        }
        .sheet(isPresented: $model.showPasteSource) { PasteSourceSheet(model: model) }
        .sheet(isPresented: $model.showRecovery) { recoverySheet }
        .sheet(isPresented: $model.showIssues) { noticesSheet }
        .sheet(isPresented: Binding(get: { !model.ambiguousMatches.isEmpty }, set: { if !$0 { model.ambiguousMatches = [] } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose a page").font(.title2.bold())
                Text("More than one page matches this title or alias.").foregroundStyle(theme.text())
                ForEach(model.ambiguousMatches) { note in
                    Button { model.ambiguousMatches = []; model.select(note.id) } label: { VStack(alignment: .leading) { Text(note.title); Text(note.relativePath).font(.caption).foregroundStyle(theme.text()) } }
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
        .onChange(of: model.selectedID) { sourceOriginal = false }
    }
    private var welcome: some View {
        VStack(spacing: 24) {
            NoemaMark().frame(width: 116, height: 116).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("noema").font(.system(size: 38, weight: .medium))
                Text("A personal atlas of thought.")
                    .font(.title3).foregroundStyle(theme.text())
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 14) {
                    Button("Create a vault…") { model.chooseVault(create: true) }.buttonStyle(.glassProminent)
                    Button("Open a vault…") { model.chooseVault(create: false) }.buttonStyle(.glass).tint(nil)
                }.controlSize(.large)
            }
            Text("Choose a folder on your Mac or in iCloud Drive. Your files stay yours.")
                .font(.callout).foregroundStyle(theme.text())
            if model.busy { ProgressView() }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).frame(maxWidth: 560).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sidebar: some View {
        List(selection: Binding(get: { Optional(model.scope) }, set: { if let scope = $0 { model.changeScope(scope) } })) {
            Section("Library") {
                navigationLabel("Wiki", symbol: "book.closed").badge(model.notes.count).tag(LibraryScope.wiki)
                navigationLabel("Sources", symbol: "tray.full").badge(model.sources.count).tag(LibraryScope.sources)
            }
            if !model.tags.isEmpty {
                Section("Topics") { ForEach(model.tags, id: \.self) { tag in navigationLabel(tag, symbol: "number", topic: true).tag(LibraryScope.tag(tag)) } }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 4) {
                NoemaMark().frame(width: 40, height: 40).accessibilityHidden(true)
                Text("noema").font(.title3.weight(.medium))
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 6)
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
                }.buttonStyle(.glass).tint(nil).controlSize(.small).help("Open another vault")
                    .accessibilityLabel("Open another vault. Current vault: \(model.vaultName)")
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func navigationLabel(_ title: String, symbol: String, topic: Bool = false) -> some View {
        Label {
            Text(title).foregroundStyle(theme.text(.textPrimary))
        } icon: {
            Image(systemName: symbol).foregroundStyle(theme.text(topic ? .graphHighlight : .accentPrimary, on: .background))
        }
    }
    private var library: some View {
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                ContentUnavailableView(model.searchText.isEmpty ? "\(model.scopeTitle) is empty" : "No matches", systemImage: model.scope == .sources ? "tray" : "doc.text.magnifyingglass", description: Text(model.searchText.isEmpty ? (model.scope == .sources ? "Import a text file or paste a source to begin." : "Create a page to start building your wiki.") : "Try another word or topic."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title).foregroundStyle(theme.text(.textPrimary, on: .background)).font(.headline).lineLimit(1)
                            Text(row.excerpt.replacingOccurrences(of: "\n", with: " ")).font(.callout)
                                .foregroundStyle(theme.text(row.id == model.selectedID ? .textPrimary : .textMuted, on: .background)).lineLimit(2)
                            if !row.tags.isEmpty {
                                Text(row.tags.prefix(3).map { "#" + $0 }.joined(separator: "  ")).font(.caption)
                                    .foregroundStyle(theme.text(row.id == model.selectedID ? .textPrimary : .graphHighlight, on: .background)).lineLimit(1)
                            }
                        }.padding(.vertical, 7).tag(row.id)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            HStack { Text(libraryCount); Spacer(); Text("⌘P") }.font(.caption).foregroundStyle(theme.text()).padding(12)
        }
        .background(theme.color(.background))
        .safeAreaBar(edge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(model.scopeTitle).font(.title2.bold()); Spacer(); if model.busy { ProgressView().controlSize(.small) } }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.text())
                    ZStack(alignment: .leading) {
                        TextField("", text: $model.searchText)
                            .accessibilityLabel("Search \(model.scope == .sources ? "sources" : "wiki")")
                            .textFieldStyle(.plain).focused($searchFocused)
                        if model.searchText.isEmpty {
                            Text("Search \(model.scope == .sources ? "sources" : "wiki")")
                                .foregroundStyle(theme.text()).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: { Label("Clear search", systemImage: "xmark.circle.fill").labelStyle(.iconOnly) }
                            .buttonStyle(.plain).foregroundStyle(theme.text())
                    }
                }.padding(10).glassEffect(.regular.interactive(), in: Capsule())
            }.padding(18)
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
                if let notice = model.editorNotice, model.currentNote != nil {
                    Label(notice, systemImage: "info.circle").font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.color(.surfaceElevated))
                }
                pageHeader
                Divider().overlay(theme.color(.border))
                ZStack(alignment: .topLeading) {
                    if let source = model.currentSource, sourceOriginal || source.metadata.storedFilename.hasSuffix(".txt") {
                        MarkdownEditor(text: .constant(model.body), action: nil, onWikiQuery: { _ in }, editable: false)
                    } else if model.currentNote != nil {
                        RichArticleView(text: $model.body, reading: model.reading, locked: model.editingLocked, action: model.editorAction, onBegin: model.beginEditing, onEnd: model.finishEditing, onWikiLink: model.followWikiLink, onWikiQuery: { model.wikiQuery = $0 }, noteID: model.currentNote?.id, onBlockLink: model.openBlockURL)
                            .id(model.selectedID)
                    } else { MarkdownPreview(blocks: model.preview, onWikiLink: model.followWikiLink) }
                    if !model.reading, model.currentNote != nil, model.wikiQuery != nil, !model.linkSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Link a page").font(.caption).foregroundStyle(theme.text()).padding(8)
                            ForEach(model.linkSuggestions) { note in
                                Button { model.suggestLink(note.title) } label: { Label(note.title, systemImage: "link").frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(.plain)
                            }
                        }.padding(6).frame(width: 270).glassEffect(.regular, in: .rect(cornerRadius: 16)).padding(16)
                    }
                }.frame(maxWidth: 980).frame(maxWidth: .infinity)
                if model.currentNote != nil { pageFooter }
            }
            .background(theme.color(.surfaceElevated))
            .onChange(of: model.body) { model.edited() }
            .onChange(of: model.title) { model.edited() }
            .onChange(of: model.tagInput) { model.edited() }
            .onChange(of: model.reading) { if model.reading { model.generatePreview() } }
        } else {
            VStack(spacing: 18) {
                NoemaMark().frame(width: 76, height: 76).accessibilityHidden(true)
                Text(model.scope == .sources ? "Keep the original. Find your meaning." : "A personal atlas of thought.").font(.title2.weight(.medium))
                Text(model.scope == .sources ? "Browse raw material here. Your interpretations belong in the wiki." : "Choose a page, or start with a thought you want to connect.").foregroundStyle(theme.text())
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
                Label(model.currentSource == nil ? "Personal wiki" : "Raw source", systemImage: model.currentSource == nil ? "book.closed" : "tray.full")
                    .font(.caption.weight(.medium)).foregroundStyle(theme.text())
                Spacer()
                if model.currentNote != nil {
                    if let hint = model.editingHint {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.toggleEditingLock() } label: {
                        Image(systemName: model.editingLocked ? "lock.fill" : "lock.open")
                    }.buttonStyle(.plain).foregroundStyle(theme.text())
                        .help(model.editingLocked ? "Unlock article" : "Lock article against editing")
                        .accessibilityLabel(model.editingLocked ? "Unlock article" : "Lock article")
                }
                if model.currentSource != nil {
                    Label("Read only", systemImage: "lock").font(.caption).foregroundStyle(theme.text())
                }
            }
            if model.currentNote != nil {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    if model.reading {
                        Text(model.title).font(.system(size: 32, weight: .semibold)).textSelection(.enabled)
                            .onTapGesture(count: 2) { model.beginEditing() }
                    } else {
                        TextField("Page title", text: $model.title).textFieldStyle(.plain).font(.system(size: 32, weight: .semibold))
                    }
                    Spacer()

                }
                if !model.reading {
                    HStack {
                        Image(systemName: "number").foregroundStyle(theme.text())
                        TextField("Topics, separated by commas", text: $model.tagInput).textFieldStyle(.plain).font(.callout)
                    }
                }
                if let note = model.currentNote, !note.allTags.isEmpty {
                    HStack { ForEach(note.allTags.prefix(8), id: \.self) { tag in Button("#" + tag) { model.changeScope(.tag(tag)) }.font(.caption).foregroundStyle(theme.text(.graphHighlight, on: .background)).buttonStyle(.bordered).tint(theme.color(.graphHighlight)).controlSize(.small) } }
                }
            } else {
                Text(model.title).font(.system(size: 32, weight: .semibold)).textSelection(.enabled)
                if let source = model.currentSource {
                    HStack {
                        Text(source.metadata.originalFilename)
                        Text("· Imported " + String(source.metadata.capturedAt.prefix(10)))
                        if let address = source.metadata.originURL, let url = URL(string: address) { Link("Original URL", destination: url).foregroundStyle(theme.text(.accentSecondary)) }
                    }.font(.caption).foregroundStyle(theme.text())
                }
            }
        }.padding(28)
    }
    private var pageFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.backlinks.isEmpty {
                HStack(alignment: .top) {
                    Text("Linked from").font(.caption).foregroundStyle(theme.text())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(model.backlinks) { note in Button(note.title) { model.select(note.id) }.buttonStyle(.link).foregroundStyle(theme.text(.accentSecondary)).tint(theme.color(.accentSecondary)).font(.caption) } }
                    }
                }
            }
            HStack {
                Label(model.saveStatus, systemImage: model.dirty ? "circle.dotted" : "checkmark.circle").font(.caption).foregroundStyle(theme.text())
                Spacer()
                Text("\(model.wordCount) words").font(.caption).foregroundStyle(theme.text())
                if !model.reading {
                    Text("/ commands · Esc to finish").font(.caption).foregroundStyle(theme.text())
                    HStack(spacing: 12) {
                        Button { model.format("**", "**") } label: { Label("Bold", systemImage: "bold").labelStyle(.iconOnly) }.help("Bold · ⌘B")
                        Button { model.format("*", "*") } label: { Label("Italic", systemImage: "italic").labelStyle(.iconOnly) }.help("Italic · ⌘I")
                        Button { model.format("[[", "]]") } label: { Label("Wiki link", systemImage: "link").labelStyle(.iconOnly) }.help("Wiki link")
                    }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
        }.padding(.horizontal, 28).padding(.vertical, 14).background(theme.color(.surfaceElevated))
    }
    private var recoverySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recoverable drafts").font(.title2.bold())
            Text("Create a new page from a draft to keep the disk version intact.").foregroundStyle(theme.text())
            List(model.recoveredDrafts) { draft in
                VStack(alignment: .leading, spacing: 8) {
                    Text(draft.title).font(.headline)
                    Text(draft.body.prefix(240)).font(.caption).foregroundStyle(theme.text()).textSelection(.enabled)
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
            if model.issues.isEmpty { Text("Your vault is up to date locally.").foregroundStyle(theme.text()) }
            List(model.issues, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
            HStack { Button("Reveal vault") { model.revealVault() }; Spacer(); Button("Done") { model.showIssues = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 580, height: 420)
    }
}

struct PasteSourceSheet: View {
    @Bindable var model: AppModel
    @Environment(\.noemaTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var url = ""
    @State private var importing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preserve a source").font(.title2.bold())
            Text("Store the original text here. Write your understanding in the wiki.").foregroundStyle(theme.text())
            TextField("Source title", text: $title)
            TextField("Original URL (optional)", text: $url)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden).background(theme.color(.surfaceElevated)).border(theme.color(.border))
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save source") {
                    importing = true
                    Task { if await model.pasteSource(title: title, text: text, originURL: url) { dismiss() }; importing = false }
                }.buttonStyle(.glassProminent).disabled(text.isEmpty || importing).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 660, height: 540)
    }
}
