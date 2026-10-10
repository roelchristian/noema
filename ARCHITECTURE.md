# Extending noema

## Where things live

**VaultCore** is independent of SwiftUI. `FileVaultRepository` owns canonical files and coordinated writes. `NoteCodec` handles lossless Markdown bodies and frontmatter. `MarkdownService` analyzes links/tags and produces a Sendable preview model. `SQLiteSearchIndex` maintains rebuildable search/tag/backlink tables. `RecoveryStore` journals unsaved drafts outside the synced folder.

**noema** owns the UI. `AppModel` runs on the main actor; storage/index work runs in separate actors, and parsing runs in detached tasks. `ContentView` arranges navigation and pages. `NativeTextViews` bridges AppKit editing and attributed previews. `VaultWatcher` forwards file-presenter and recursive FSEvents notifications into debounced reconciliation, including changes from editors that do not coordinate their writes.

The `VaultRepository` and `SearchIndex` protocols are the seams for replacing storage/index implementations. Keep UI actions out of codecs, and keep filesystem work out of view bodies. SQLite connections are confined to their index actor.

## Identity and evolution

New wiki pages and sources get UUIDs. A plain external Markdown page gets a deterministic temporary identity derived from vault UUID and relative path; that identity is persisted on first app save. Moving such a page externally before its first save changes its temporary identity. Persisted IDs survive moves. App title changes add aliases and retain stable filenames.

Vault manifests have an explicit format version. Reject unsupported versions instead of silently rewriting data. Preserve unknown frontmatter fields for future extensions. Canonical knowledge lives in files; caches and derived data can always be rebuilt. Page bodies remain freeform Markdown.

## Later milestones

- **Provenance:** add source UUID references to wiki metadata and a source/page relationship view. Keep raw imports immutable and make relationships many-to-many. Existing source IDs and checksums provide identity and revision tracking.
- **Semantic retrieval:** derive heading-based sections with note/source UUID, heading path, content hash, and text. Store embeddings in local derived storage. Recompute changed sections, and label whether a passage is a source or a personal interpretation.
- **LLM context:** retrieve relevant passages, then apply the selected model’s tokenizer and context budget. Include compact identity/provenance metadata; do not replace the original text with a model’s token stream or generated summary.
- **Additional importers:** put PDF/web extraction behind an importer service; retain the original and treat extracted text as derived content. Extend source schema deliberately.
- **Mobile:** share VaultCore, build a separate UI, and test coordinated edits across platforms before claiming sync compatibility.

Start with one extension at a time. There is deliberately no server, AI SDK, vector store, or runtime plugin system in v1.
