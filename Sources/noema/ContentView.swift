import SwiftUI
import AppKit
import VaultCore

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.noemaTheme) private var theme
    @FocusState private var searchFocused: Bool
    @State private var showTrashConfirmation = false
    @State private var trashPageID: UUID?
    @State private var permanentDeletion: TrashedPage?
    @State private var dismissedExternalChange = false
    @State private var sourceOriginal = false
    @State private var showPageDetails = true
    @State private var condensedInspector = false
    @State private var sourceSelection: UUID?
    @State private var renamingSource: SourceRecord?
    @State private var sourceName = ""
    @State private var deletingSource: SourceRecord?
    @State private var sourceSortOrder = [KeyPathComparator(\LibraryRow.title)]
    @AppStorage(EditorPreferences.aiSummariesKey) private var aiSummaries = false
    var body: some View {
        Group {
            if model.root == nil { welcome }
            else if model.scope == .sources {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
                } detail: {
                    HSplitView {
                        library.frame(minWidth: 520)
                        if let source = model.sources.first(where: { $0.id == sourceSelection }) {
                            sourceInspector(source).frame(minWidth: 280, idealWidth: 340, maxWidth: 400)
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
                } content: {
                    library.navigationSplitViewColumnWidth(min: model.scope == .sources ? 520 : 385, ideal: model.scope == .sources ? 620 : 385, max: model.scope == .sources ? 850 : 490)
                } detail: {
                    HSplitView {
                        detail.frame(minWidth: 360)
                        if showPageDetails, let note = model.currentNote {
                            pageInspector(note).frame(minWidth: 280, idealWidth: 340, maxWidth: 400)
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .toolbar(removing: .title)
        .sheet(isPresented: $model.showURLSource) { URLSourceSheet(model: model) }
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
            Button("Move to Trash", role: .destructive) { model.trashPage(trashPageID) }
        } message: { Text("The Markdown file stays recoverable in the vault’s .Trash folder.") }
        .alert("Rename Source", isPresented: Binding(get: { renamingSource != nil }, set: { if !$0 { renamingSource = nil } })) {
            TextField("File Name", text: $sourceName)
            Button("Rename") {
                if let source = renamingSource { model.renameSource(source, title: sourceName) }
                renamingSource = nil
            }.disabled(sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renamingSource = nil }
        } message: { Text("Changes the source name stored in the vault. The original file name and file stay unchanged.") }
        .alert("Delete Source?", isPresented: Binding(get: { deletingSource != nil }, set: { if !$0 { deletingSource = nil } })) {
            Button("Delete", role: .destructive) {
                if let source = deletingSource { model.deleteSource(source) }
                deletingSource = nil
            }
            Button("Cancel", role: .cancel) { deletingSource = nil }
        } message: {
            Text(deletingSource?.metadata.isLinked == true
                 ? "Remove ‘\(deletingSource?.title ?? "")’ from Sources? Its linked original will remain on your filesystem."
                 : "Permanently delete ‘\(deletingSource?.title ?? "")’ and its imported original from the vault? This cannot be undone.")
        }
        .onChange(of: model.searchText) { model.queryChanged() }
        .onChange(of: model.body) { if model.scope == .semantic { model.queryChanged() } }
        .onChange(of: model.title) { if model.scope == .semantic { model.queryChanged() } }
        .onChange(of: model.searchFocusToken) { searchFocused = true }
        .onChange(of: model.selectedID) { sourceOriginal = false; dismissedExternalChange = false }
        .onChange(of: model.externalChange) { dismissedExternalChange = false }
        .onChange(of: model.root) { sourceSelection = nil; renamingSource = nil; deletingSource = nil }
    }
    private var welcome: some View {
        VStack(spacing: 24) {
            NoemaMark().frame(width: 116, height: 116).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Noema").font(.system(size: 38, weight: .medium))
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
            if let error = model.errorMessage { DismissibleNotice(message: error) { model.errorMessage = nil }.frame(maxWidth: 560) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sidebar: some View {
        List(selection: Binding(get: { Optional(model.scope) }, set: { if let scope = $0 { model.changeScope(scope) } })) {
            Section("Library") {
                navigationLabel("Pages", symbol: "book.closed").badge(model.notes.count).tag(LibraryScope.wiki)
                navigationLabel("Sources", symbol: "tray.full").badge(model.sources.count).tag(LibraryScope.sources)
                navigationLabel("Semantic Blocks", symbol: "tag").tag(LibraryScope.semantic)
                navigationLabel("Trash", symbol: "trash").badge(model.trashedPages.count).tag(LibraryScope.trash)
            }
            if !model.tags.isEmpty {
                Section("Topics") { ForEach(model.tags, id: \.self) { tag in navigationLabel(tag, symbol: "number", topic: true).tag(LibraryScope.tag(tag)) } }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 4) {
                NoemaMark().frame(width: 40, height: 40).accessibilityHidden(true)
                Text("Noema").font(.title3.weight(.medium))
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
    @ViewBuilder private var library: some View {
        if model.scope == .trash { trashLibrary } else { pageLibrary }
    }
    private var pageLibrary: some View {
        VStack(spacing: 0) {
            if model.scope == .sources {
                sourceTable
            } else if model.scope == .semantic {
                semanticBlockList
            } else if model.rows.isEmpty {
                ContentUnavailableView(model.searchText.isEmpty ? "\(model.scopeTitle) is empty" : "No matches", systemImage: model.scope == .sources ? "tray" : "doc.text.magnifyingglass", description: Text(model.searchText.isEmpty ? (model.scope == .sources ? "Import a text file or paste a source to begin." : "Create a page to start building your wiki.") : "Try another word or topic."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                if row.kind == .wiki, model.unseenRenamedPages.contains(row.id) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Color(nsColor: .systemBlue))
                                        .help("Page renamed since you last viewed it")
                                        .accessibilityLabel("Unread title change")
                                }
                                Text(row.title).font(.headline).lineLimit(1)
                                if row.kind == .wiki, model.notes.first(where: { $0.id == row.id })?.isEditingLocked == true {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .help("Page locked against editing")
                                        .accessibilityLabel("Page locked against editing")
                                }
                                Spacer(minLength: 8)
                                if let date = row.updatedAt {
                                    Text(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().year())
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                                        .help(date.formatted(date: .long, time: .shortened))
                                        .accessibilityLabel("\(row.kind == .wiki ? "Last updated" : "Captured") \(date.formatted(date: .long, time: .shortened))")
                                }
                            }.foregroundStyle(theme.text(.textPrimary, on: .background))
                            HStack(alignment: .top, spacing: 5) {
                                if row.hasAISummary {
                                    Image(systemName: "sparkles").accessibilityLabel("AI-generated summary")
                                }
                                Text(row.excerpt.replacingOccurrences(of: "\n", with: " ")).lineLimit(2)
                            }.font(.callout)
                                .foregroundStyle(theme.text(row.id == model.selectedID ? .textPrimary : .textMuted, on: .background))
                            if !row.tags.isEmpty {
                                Text(row.tags.prefix(3).map { "#" + $0 }.joined(separator: "  ")).font(.caption)
                                    .foregroundStyle(theme.text(row.id == model.selectedID ? .textPrimary : .graphHighlight, on: .background)).lineLimit(1)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 10).tag(row.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if row.kind == .wiki {
                                Button(role: .destructive) { trashPageID = row.id; showTrashConfirmation = true } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if row.kind == .wiki, let note = model.notes.first(where: { $0.id == row.id }) {
                                Button { model.toggleEditingLock(row.id) } label: {
                                    Label(note.isEditingLocked ? "Unlock" : "Lock", systemImage: note.isEditingLocked ? "lock.open" : "lock")
                                }
                            }
                        }
                        .contextMenu {
                            if row.kind == .wiki, let note = model.notes.first(where: { $0.id == row.id }) {
                                Button(note.isEditingLocked ? "Unlock" : "Lock") { model.toggleEditingLock(row.id) }
                                Button("Delete…", role: .destructive) { trashPageID = row.id; showTrashConfirmation = true }
                            }
                        }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            HStack {
                Text(libraryCount)
                if model.scope == .sources, model.sourceRenameTotal > 0 {
                    Text("Renaming \(min(model.sourceRenameCompleted + 1, model.sourceRenameTotal)) of \(model.sourceRenameTotal) files…")
                }
                Spacer(); Text("⌘P")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .background(theme.color(.background))
        .safeAreaBar(edge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.scopeTitle).font(.title2.bold()); Spacer()
                    if model.scope == .sources {
                        Menu {
                            Button("Check Availability of All Sources") { model.checkSourceAvailability(model.sources) }
                                .disabled(model.sources.isEmpty || !model.checkingSourceAvailability.isEmpty)
                        } label: { Label("Source Actions", systemImage: "ellipsis.circle") }
                        Menu("Add Source") {
                            Button("From Files…") { model.addSource() }
                            Button("By URL…") { model.showURLSource = true }
                        }
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                }
                if model.scope == .sources, let error = model.errorMessage {
                    DismissibleNotice(message: error) { model.errorMessage = nil }
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.text())
                    ZStack(alignment: .leading) {
                        TextField("", text: $model.searchText)
                            .accessibilityLabel("Search \(model.scope == .semantic ? "semantic blocks" : model.scope == .sources ? "sources" : "pages")")
                            .textFieldStyle(.plain).focused($searchFocused)
                        if model.searchText.isEmpty {
                            Text("Search \(model.scope == .semantic ? "semantic blocks" : model.scope == .sources ? "sources" : "pages")")
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
    private var sourceTable: some View {
        Table(model.rows.sorted(using: sourceSortOrder),
              selection: $sourceSelection,
              sortOrder: $sourceSortOrder) {
            TableColumn("File Name", value: \.title) { row in
                if model.generatingSourceTitles.contains(row.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Generating title").foregroundStyle(.secondary)
                    }
                } else { Label(row.title, systemImage: "doc.text").lineLimit(1).help(row.title) }
            }.width(min: 160, ideal: 220)
            TableColumn("Original File Name", value: \.originalFilename) { row in
                Text(row.originalFilename).lineLimit(1).help(row.originalFilename)
            }.width(min: 100, ideal: 150)
            TableColumn("Location", value: \.sourceLocation) { row in
                Label(row.sourceLocation, systemImage: row.sourceLocation == "Linked" ? "link" : "tray.full")
                    .help(row.sourceLocation == "Linked" ? "Read-only linked original" : "Original stored in vault")
            }.width(min: 85, ideal: 95)
            TableColumn("Availability") { row in
                sourceAvailabilityStatus(row.id)
            }.width(min: 150, ideal: 180)
            TableColumn("Kind", value: \.fileKind)
                .width(min: 80, ideal: 90)
            TableColumn("Size", value: \.fileSize) { row in
                Text(ByteCountFormatter.string(fromByteCount: Int64(row.fileSize), countStyle: .file))
            }.width(min: 70, ideal: 90)
            TableColumn("Captured", value: \.captureSortDate) { row in
                if let date = row.updatedAt {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .lineLimit(1).help(date.formatted(date: .long, time: .shortened))
                } else { Text("—") }
            }.width(min: 100, ideal: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let source = model.sources.first(where: { $0.id == id }) {
                Button("Open Preview") { model.openSource(id) }
                sourceSummaryButton(source)
                Button("Check Availability") { model.checkSourceAvailability([source]) }
                    .disabled(model.checkingSourceAvailability.contains(id))
                Button { sourceName = source.title; renamingSource = source } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { deletingSource = source } label: { Label("Delete", systemImage: "trash") }
            }
        } primaryAction: { ids in if let id = ids.first { model.openSource(id) } }
        .accessibilityLabel("Sources table")
    }
    @ViewBuilder private func sourceAvailabilityStatus(_ id: UUID) -> some View {
        if model.checkingSourceAvailability.contains(id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking availability…").foregroundStyle(.secondary)
            }
        } else {
            Text(model.availabilityLabel(id)).lineLimit(1).help(model.availabilityLabel(id))
        }
    }
    private func sourceSummaryButton(_ source: SourceRecord, compact: Bool = false) -> some View {
        let hasSummary = source.metadata.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return Button(compact ? (hasSummary ? "Regenerate" : "Generate") : (hasSummary ? "Regenerate AI Summary" : "Generate AI Summary")) {
            model.generateSourceSummary(source)
        }
        .disabled(model.generatingSourceTitles.contains(source.id) || model.generatingSourceSummaries.contains(source.id))
    }
    private func metadataDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: value)
        if date == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            date = formatter.date(from: value)
        }
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
    private func inspectorToolbar(close: @escaping () -> Void) -> some View {
        HStack {
            Text("Inspector").font(.headline)
            Spacer()
            Toggle(isOn: $condensedInspector) {
                Label("Condensed inspector", systemImage: "rectangle.compress.vertical").labelStyle(.iconOnly)
            }.toggleStyle(.button).help("Condensed inspector")
            Button(action: close) {
                Label("Close inspector", systemImage: "xmark").labelStyle(.iconOnly)
            }.buttonStyle(.borderless).help("Close inspector")
        }.controlSize(.small).padding(.horizontal, 20).padding(.vertical, 10)
    }
    private func inspectorIdentity(title: String, kind: String, date: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DOCUMENT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(kind + " · " + metadataDate(date)).font(.caption).foregroundStyle(.secondary).help(date)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sourceReferences(_ note: NoteRecord) -> some View {
        let canEdit = !note.isEditingLocked && !model.editorReadOnly && !model.updatingSourceReferences
        return InspectorSection(title: "Sources", count: note.linkedSourceIDs.count, condensed: condensedInspector) {
            if note.linkedSourceIDs.isEmpty {
                Text("No sources linked").foregroundStyle(.secondary)
                Text("Attach a reference from your source library.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(note.linkedSourceIDs, id: \.self) { id in
                SourceAssociationRow(
                    title: model.sources.first(where: { $0.id == id })?.title ?? "Unavailable source",
                    openLabel: "Open source", canOpen: model.sources.contains { $0.id == id }, canRemove: canEdit,
                    open: { model.openSource(id) },
                    remove: { model.setSourceReference(pageID: note.id, sourceID: id, linked: false) }
                ).id(note.id.uuidString + id.uuidString)
            }
        } actions: {
            Menu("Add") {
                ForEach(model.sources.filter { !note.linkedSourceIDs.contains($0.id) }) { source in
                    Button(source.title) { model.setSourceReference(pageID: note.id, sourceID: source.id, linked: true) }
                }
            }.disabled(!canEdit || model.sources.allSatisfy { note.linkedSourceIDs.contains($0.id) })
        }
    }
    private func sourcePages(_ source: SourceRecord) -> some View {
        let pages = model.notes.filter { $0.linkedSourceIDs.contains(source.id) }
        return InspectorSection(title: "Pages", count: pages.count, condensed: condensedInspector) {
            if pages.isEmpty { Text("No pages reference this source.").foregroundStyle(.secondary) }
            ForEach(pages) { note in
                SourceAssociationRow(
                    title: note.title, openLabel: "Open page", canOpen: true,
                    canRemove: !note.isEditingLocked && !model.updatingSourceReferences,
                    open: { model.select(note.id, scope: .wiki) },
                    remove: { model.setSourceReference(pageID: note.id, sourceID: source.id, linked: false) }
                ).id(source.id.uuidString + note.id.uuidString)
            }
        } actions: {
            Menu("Add") {
                ForEach(model.notes.filter { !$0.isEditingLocked && !$0.linkedSourceIDs.contains(source.id) }) { note in
                    Button(note.title) { model.setSourceReference(pageID: note.id, sourceID: source.id, linked: true) }
                }
            }.disabled(model.updatingSourceReferences)
        }
    }
    private func sourceInspector(_ source: SourceRecord) -> some View {
        VStack(spacing: 0) {
            inspectorToolbar { sourceSelection = nil }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inspectorIdentity(title: source.title, kind: source.metadata.originalFilename.split(separator: ".").last.map { $0.uppercased() } ?? "Source", date: source.metadata.capturedAt)
                    InspectorSection(title: "Properties", condensed: false) {
                        LabeledContent("Availability") { sourceAvailabilityStatus(source.id) }.font(.caption)
                        InspectorProperty("Original file", source.metadata.originalFilename)
                        InspectorProperty("Location", source.metadata.isLinked ? "Linked" : "In vault")
                        if let size = source.metadata.fileSize {
                            InspectorProperty("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        }
                        InspectorProperty("Captured", metadataDate(source.metadata.capturedAt)).help(source.metadata.capturedAt)
                        if let origin = source.metadata.originURL, let url = URL(string: origin), !origin.isEmpty {
                            LabeledContent("Origin") { Link(origin, destination: url) }.font(.caption)
                        }
                    } actions: {
                        Menu {
                            Button("Open Preview") { model.openSource(source.id) }
                            Button("Check Availability") { model.checkSourceAvailability([source]) }
                                .disabled(model.checkingSourceAvailability.contains(source.id))
                        } label: { Label("Source actions", systemImage: "ellipsis").labelStyle(.iconOnly) }
                        .menuStyle(.borderlessButton).fixedSize().help("Source actions")
                    }
                    sourcePages(source)
                    InspectorSection(title: "AI summary", condensed: condensedInspector) {
                        if model.generatingSourceSummaries.contains(source.id) || model.generatingSourceTitles.contains(source.id) {
                            HStack { ProgressView().controlSize(.mini); Text("Generating summary…").foregroundStyle(.secondary) }
                        }
                        if let summary = source.metadata.aiSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            SidebarAISummary(text: summary).id(source.id)
                            Text("AI-generated").font(.caption).foregroundStyle(.secondary)
                        } else { Text("No AI summary available.").foregroundStyle(.secondary) }
                    } actions: { sourceSummaryButton(source, compact: true).labelStyle(.titleOnly) }
                }.textSelection(.enabled).padding(20)
            }
        }.frame(maxHeight: .infinity).background(theme.color(.background)).accessibilityLabel("Source inspector")
    }
    private func pageInspector(_ note: NoteRecord) -> some View {
        let document = BlockDocumentCodec.decode(model.body)
        let summary = document.aiSummary
        return VStack(spacing: 0) {
            inspectorToolbar { showPageDetails = false }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inspectorIdentity(title: model.title, kind: "Markdown", date: note.updatedAt)
                    InspectorSection(title: "Properties", condensed: false) {
                        LabeledContent("Location") {
                            Button(note.relativePath) {
                                if let root = model.root { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(note.relativePath)]) }
                            }.buttonStyle(.link).foregroundStyle(.primary)
                        }.font(.caption)
                        InspectorProperty("Created", metadataDate(note.createdAt)).help(note.createdAt)
                        InspectorProperty("Modified", metadataDate(note.updatedAt)).help(note.updatedAt)
                        InspectorProperty("Tags", Array(Set(model.editedTags + note.inlineTags)).sorted().joined(separator: ", "))
                        if !note.aliases.isEmpty { InspectorProperty("Aliases", note.aliases.joined(separator: ", ")) }
                        LabeledContent("Protection") {
                            Button { model.toggleEditingLock() } label: {
                                Label(model.editingLocked ? "Locked" : "Unlocked", systemImage: model.editingLocked ? "lock" : "lock.open")
                            }.buttonStyle(.borderless).help(model.editingLocked ? "Unlock page" : "Lock page")
                        }.font(.caption)
                    } actions: { EmptyView() }
                    sourceReferences(note)
                    InspectorSection(title: "Semantic blocks", count: document.semanticGroups.flatMap(\.blocks).count, condensed: condensedInspector) {
                        if document.semanticGroups.isEmpty { Text("No semantic blocks on this page.").foregroundStyle(.secondary) }
                        ForEach(document.semanticGroups, id: \.tag) { group in
                            ForEach(group.blocks) { block in
                                SemanticBlockSidebarRow(block: block) {
                                    model.editorAction = EditorAction(operation: .block(block.id))
                                }
                            }
                        }
                    } actions: { EmptyView() }
                    InspectorSection(title: "AI summary", condensed: condensedInspector) {
                        if !aiSummaries { Text("Enable summaries in Noema → Settings → Apple Intelligence.").font(.caption).foregroundStyle(.secondary) }
                        if model.generatingAISummary {
                            HStack { ProgressView().controlSize(.mini); Text("Generating summary…").foregroundStyle(.secondary) }
                        }
                        if let summary {
                            SidebarAISummary(text: summary.text).id(note.id)
                            Text("AI-generated").font(.caption).foregroundStyle(.secondary)
                        } else { Text("No AI summary available.").foregroundStyle(.secondary) }
                    } actions: {
                        Menu {
                            Button(summary == nil ? "Generate Summary" : "Regenerate Summary") { model.summarizePage() }
                                .disabled(!aiSummaries || model.editingLocked || model.generatingAISummary)
                            if summary != nil {
                                Button("Delete Summary", role: .destructive) { model.deleteAISummary() }
                                    .disabled(model.editingLocked || model.generatingAISummary)
                            }
                        } label: { Label("Summary actions", systemImage: "ellipsis").labelStyle(.iconOnly) }
                        .menuStyle(.borderlessButton).fixedSize().help("Summary actions")
                    }
                }.textSelection(.enabled).padding(20)
            }
        }.frame(maxHeight: .infinity).background(theme.color(.background)).accessibilityLabel("Page inspector")
    }
    private var trashLibrary: some View {
        VStack(spacing: 0) {
            if model.trashedPages.isEmpty {
                ContentUnavailableView("Trash is empty", systemImage: "trash", description: Text("Deleted pages appear here until restored or permanently deleted."))
            } else {
                List {
                    ForEach(model.trashedPages) { page in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.note.title).font(.headline)
                            HStack {
                                Button("Restore") { model.restoreTrashedPage(page) }
                                Button("Delete permanently…", role: .destructive) { permanentDeletion = page }
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 7)
                        .contextMenu {
                            Button("Restore") { model.restoreTrashedPage(page) }
                            Button("Delete permanently…", role: .destructive) { permanentDeletion = page }
                        }
                    }
                }.listStyle(.plain)
            }
            Text("\(model.trashedPages.count) deleted pages").font(.caption).foregroundStyle(.secondary).padding(12)
            if let error = model.errorMessage { DismissibleNotice(message: error) { model.errorMessage = nil }.padding(12) }
        }
        .safeAreaBar(edge: .top) { Text("Trash").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(18) }
        .alert("Permanently delete this page?", isPresented: Binding(get: { permanentDeletion != nil }, set: { if !$0 { permanentDeletion = nil } })) {
            Button("Delete permanently", role: .destructive) {
                if let page = permanentDeletion { model.permanentlyDeleteTrashedPage(page) }
                permanentDeletion = nil
            }
            Button("Cancel", role: .cancel) { permanentDeletion = nil }
        } message: { Text("‘\(permanentDeletion?.note.title ?? "")’ will be removed from the vault. This cannot be undone.") }
    }
    @ViewBuilder private var detail: some View {
        if model.currentNote != nil || model.currentSource != nil {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        DismissibleNotice(message: message) {
                            model.errorMessage = nil; dismissedExternalChange = model.externalChange
                        }.font(.callout)
                        if model.externalChange {
                            HStack {
                                Button("Reload disk version") { model.reloadDiskVersion() }
                                Button("Save draft as new page") { model.saveDraftAsNewPage() }
                            }
                        } else if model.currentNote != nil { Button("Try saving again") { model.saveNow() } }

                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12))
                } else if model.externalChange, !dismissedExternalChange {
                    HStack {
                        Label("This page changed or moved outside the app.", systemImage: "arrow.triangle.2.circlepath")
                        Spacer(); Button("Reload") { model.reloadDiskVersion() }
                        Button("Save a copy") { model.saveDraftAsNewPage() }
                        Button("Dismiss") { dismissedExternalChange = true }
                    }.font(.callout).padding(12).background(.orange.opacity(0.12))
                }
                if let notice = model.editorNotice, model.currentNote != nil {
                    DismissibleNotice(message: notice, isError: false) { model.editorNotice = nil }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.color(.surfaceElevated))
                }
                pageHeader
                Divider().overlay(theme.color(.border))
                ZStack(alignment: .topLeading) {
                    if let source = model.currentSource, sourceOriginal || source.metadata.storedFilename.hasSuffix(".txt") {
                        MarkdownEditor(text: .constant(model.body), action: nil, onWikiQuery: { _ in }, editable: false)
                    } else if model.currentNote != nil {
                        SummarizedArticleView(model: model, showsSummary: !showPageDetails)
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
                if let error = model.errorMessage { DismissibleNotice(message: error) { model.errorMessage = nil }.frame(maxWidth: 500) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top) { HStack { Spacer(); headerActions }.padding(.horizontal, 28).padding(.vertical, 8) }
        }
    }
    private var semanticBlockList: some View {
        Group {
            if model.semanticRows.isEmpty {
                ContentUnavailableView(model.searchText.isEmpty ? "No semantic blocks" : "No matches",
                    systemImage: "tag", description: Text("Search block text, semantic type, or page title."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedSemanticID }, set: { id in
                    if let hit = model.semanticRows.first(where: { $0.id == id }) {
                        model.select(hit.pageID, block: hit.blockID)
                    }
                })) {
                    ForEach(model.semanticRows) { hit in
                        let presentation = SemanticPresentation.find(hit.semantic)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: presentation?.symbol ?? "tag")
                                .font(.headline)
                                .foregroundStyle(Color(nsColor: presentation?.accent ?? .secondaryLabelColor))
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(presentation?.title ?? hit.semantic.capitalized).font(.headline)
                                Text(hit.preview.isEmpty ? "Empty block" : hit.preview).lineLimit(1)
                                Text(hit.pageTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 10).tag(hit.id)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
    }
    private var libraryCount: String {
        if model.scope == .semantic { return "\(model.semanticRows.count) semantic blocks" }
        let count = model.rows.count
        let noun = model.scope == .sources ? (count == 1 ? "source" : "sources") : (count == 1 ? "page" : "pages")
        return "\(count) \(noun)"
    }
    private var headerActions: some View {
        HStack(spacing: 16) {
            if model.root != nil {
                if model.currentNote != nil {
                    HStack(spacing: 8) {
                        Button { showPageDetails.toggle() } label: {
                            Label("Page details", systemImage: "sidebar.right")
                        }.help(showPageDetails ? "Hide page details" : "Show page details")
                        if aiSummaries {
                            Button { model.summarizePage() } label: { Label("Summarize", systemImage: "sparkles") }
                                .disabled(model.editingLocked || model.generatingAISummary)
                                .help("Generate an on-device AI summary")
                        }
                        Button { if model.reading { model.beginEditing() } else { model.finishEditing() } } label: {
                            Label(model.reading ? "Edit" : "Done", systemImage: model.reading ? "pencil" : "checkmark")
                        }.disabled(model.editingLocked)
                        Button { model.toggleEditingLock() } label: {
                            Label(model.editingLocked ? "Unlock article" : "Lock article", systemImage: model.editingLocked ? "lock.fill" : "lock.open")
                        }.help(model.editingLocked ? "Unlock article" : "Lock article against editing")
                        Button { trashPageID = model.currentNote?.id; showTrashConfirmation = true } label: {
                            Label("Move page to vault trash", systemImage: "trash")
                        }.help("Move page to vault trash")
                    }
                } else if model.currentSource?.metadata.storedFilename.hasSuffix(".md") == true {
                    HStack(spacing: 8) {
                        Picker("Source view", selection: $sourceOriginal) {
                            Text("Read").tag(false)
                            Text("Original").tag(true)
                        }.pickerStyle(.segmented).frame(minWidth: 160)
                    }
                }
                HStack(spacing: 8) {
                    if model.scope == .sources {
                        Menu("Add Source") {
                            Button("From Files…") { model.addSource() }
                            Button("By URL…") { model.showURLSource = true }
                        }
                    } else {
                        Menu {
                            Button("Blank page") { model.newPage() }
                            Button("Personal page template") { model.newPage(template: true) }
                        } label: { Label("New page", systemImage: "square.and.pencil") }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.roundedRectangle)
                            .help("New page")
                            .accessibilityLabel("New page")
                    }
                }
                HStack(spacing: 8) {
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
        }.labelStyle(.iconOnly).buttonStyle(.glass).fixedSize(horizontal: true, vertical: false)
    }
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice = model.aiSummaryNotice { DismissibleNotice(message: notice, isError: false) { model.aiSummaryNotice = nil }.font(.caption) }
            if model.currentSource != nil || model.editingHint != nil {
                HStack {
                    if model.currentSource != nil {
                        Label("Raw source", systemImage: "tray.full")
                            .font(.caption.weight(.medium)).foregroundStyle(theme.text())
                    }
                    Spacer()
                    if model.currentNote != nil, let hint = model.editingHint {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.currentSource != nil {
                        Label("Read only", systemImage: "lock").font(.caption).foregroundStyle(theme.text())
                    }
                }
            }
            if model.currentNote != nil {
                HStack(alignment: .center, spacing: 16) {
                    if model.reading {
                        Text(model.title).font(.system(size: 26, weight: .semibold)).textSelection(.enabled)
                            .onTapGesture(count: 2) { model.beginEditing() }
                    } else {
                        TextField("Page title", text: $model.title).textFieldStyle(.plain).font(.system(size: 26, weight: .semibold))
                    }
                    if !showPageDetails {
                        Spacer()
                        headerActions
                    }
                }
                if showPageDetails {
                    headerActions
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
                HStack(alignment: .center, spacing: 16) {
                    Text(model.title).font(.system(size: 26, weight: .semibold)).textSelection(.enabled)
                    Spacer()
                    headerActions
                }
                if let source = model.currentSource {
                    HStack {
                        Text(source.metadata.originalFilename)
                        Text((source.metadata.isLinked ? "· Linked " : "· Imported ") + String(source.metadata.capturedAt.prefix(10)))
                        if let address = source.metadata.originURL, let url = URL(string: address) { Link("Original URL", destination: url).foregroundStyle(theme.text(.accentSecondary)) }
                    }.font(.caption).foregroundStyle(theme.text())
                }
            }
        }.padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 20)
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
            if model.issues.isEmpty { Text("No active vault notices.").foregroundStyle(theme.text()) }
            List(model.issues, id: \.self) { issue in
                DismissibleNotice(message: issue, isError: false) { model.dismissVaultNotice(issue) }.font(.callout)
            }
            if !model.issues.isEmpty { Button("Dismiss All") { model.dismissAllVaultNotices() } }
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
            if let error = model.errorMessage { DismissibleNotice(message: error) { model.errorMessage = nil }.font(.caption) }
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


private struct SemanticBlockSidebarRow: View {
    let block: EditorBlock
    let navigate: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let presentation = SemanticPresentation.find(block.metadata.semantic)
        let preview = block.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        Button(action: navigate) {
            HStack(spacing: 8) {
                Image(systemName: presentation?.symbol ?? "tag")
                    .foregroundStyle(Color(nsColor: presentation?.accent ?? .secondaryLabelColor))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation?.title ?? block.metadata.semantic ?? "Block").font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Text(preview.isEmpty ? "Empty block" : preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }.font(.body).contentShape(Rectangle())
        }.buttonStyle(.borderless).focused($focused)
            .help(block.text)
            .accessibilityLabel("Go to \(presentation?.title ?? block.metadata.semantic ?? "tagged") block: \(preview.isEmpty ? "Empty block" : preview)")
    }
}

private struct InspectorProperty: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        LabeledContent { Text(value.isEmpty ? "None" : value).foregroundStyle(.primary) } label: {
            Text(title).foregroundStyle(.secondary)
        }.font(.caption)
    }
}

private struct InspectorSection<Content: View, Actions: View>: View {
    let title: String
    let count: Int?
    let condensed: Bool
    let content: Content
    let actions: Actions
    @State private var expanded: Bool
    init(title: String, count: Int? = nil, condensed: Bool, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.count = count; self.condensed = condensed
        self.content = content(); self.actions = actions()
        _expanded = State(initialValue: !condensed)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .center, spacing: 8) {
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    HStack(spacing: 6) {
                        Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                        if let count { Text(count.formatted()).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                actions.controlSize(.small).font(.caption)
            }
            if expanded { VStack(alignment: .leading, spacing: 8) { content }.frame(maxWidth: .infinity, alignment: .leading).font(.callout) }
        }.onChange(of: condensed) { expanded = !condensed }
    }
}

private struct SidebarAISummary: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel(expanded ? "Collapse AI-generated summary" : "Expand AI-generated summary")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
        .onChange(of: text) { expanded = false }
    }
}

private struct DismissibleNotice: View {
    var message: String
    var isError = true
    var dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message).foregroundStyle(isError ? Color.red : Color.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Label("Dismiss message", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
            }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss message")
        }
    }
}

private struct SourceAssociationRow: View {
    let title: String
    let openLabel: String
    let canOpen: Bool
    let canRemove: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button(action: open) {
                    Label(openLabel, systemImage: "arrow.up.forward.square").labelStyle(.iconOnly)
                }.disabled(!canOpen).help(openLabel)
                Button { confirmingRemoval = true } label: {
                    Label("Remove link", systemImage: "trash").labelStyle(.iconOnly)
                }.disabled(!canRemove || confirmingRemoval).help("Remove link")
            }
            if confirmingRemoval {
                Text("Remove this link? The page and source will be kept.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Remove", role: .destructive) {
                        confirmingRemoval = false
                        remove()
                    }.disabled(!canRemove)
                    Button("Cancel") { confirmingRemoval = false }
                }
            }
        }.onChange(of: canRemove) { if !canRemove { confirmingRemoval = false } }
    }
}

struct URLSourceSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var importing = false
    @State private var failures: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Sources by URL").font(.title2.bold())
            Text("Enter up to 5 http or https URLs, one per line. This Mac fetches each page and keeps a local copy.").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .accessibilityLabel("Source URLs, one per line").disabled(importing)
            if !failures.isEmpty {
                ScrollView { Text(failures.joined(separator: "\n")).foregroundStyle(.red).textSelection(.enabled) }.frame(maxHeight: 120)
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(importing)
                Spacer()
                if importing { ProgressView().controlSize(.small); Text("Fetching sources…").foregroundStyle(.secondary) }
                Button("Add Sources") {
                    importing = true; failures = []
                    Task { failures = await model.addURLSources(text); importing = false; if failures.isEmpty { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(importing || (try? WebSourceFetcher.lines(text)) == nil)
            }
        }.padding(24).frame(width: 600, height: 400).interactiveDismissDisabled(importing)
    }
}
