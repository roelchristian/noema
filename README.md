# Noema

**A personal atlas of thought.**

A native macOS personal wiki, with a separate read-only library of raw sources.

The interface uses native macOS Liquid Glass navigation and toolbars, glass search and editing controls, and an orbital glass mark inspired by connected thoughts. Writing and source content retain readable standard backgrounds. The mark shares geometry with the packaged icon; see `Resources/Brand/README.md` for the exported layers and the current `.icns` packaging limitation.

**System appearance:** App chrome, controls, writing surfaces, selection, and previews follow macOS Light/Dark appearance, accent and highlight colors, and accessibility settings. Appearance settings are managed in System Settings; Noema no longer overrides them. Midnight Iris colors are confined to the orbital identity and icon exports.

## Build and run

Requires macOS 26+, Apple’s Swift 6 command-line tools, and internet access for the first dependency download. Full Xcode is optional. The tested development machine runs macOS 27 with Swift 6.2.4 and the macOS 26.2 SDK.

```sh
./scripts/run.sh
```

For an optimized build:

```sh
./scripts/build.sh release
open "dist/noema.app"
```

The script packages and locally signs a sandboxed app and creates `dist/noema.zip`. The archive excludes Finder/iCloud extended attributes; use it when moving the app out of this iCloud-backed Documents folder. This is a personal development build, not a notarized distribution. The package can also be opened in Xcode. SwiftPM dependencies are pinned in `Package.resolved`; cache/build outputs stay in `.build`.

## Your first vault

For a quick tour, open `Examples/Demo Vault`. Its pages contain illustrative personal context, and you can create a separate vault for your own writing.

1. Click **Create a vault**. Create or choose a dedicated folder, locally or in iCloud Drive. Keep your content vault separate from this source-code folder.
2. Select **Pages** to browse your writing; page headers begin with the title. Use **New Personal Page** for optional Overview / Personal context / Connections headings, or create a blank page with ⌘N.
3. Add topics in the comma-separated field or write inline `#history` tags. Type `[[` for page suggestions. A link such as `[[Pertinax|my reading]]` can show a friendly label.
4. Click **Edit** or click the article text area once to start native block editing; click **Done** or press Escape to finish. The lock control beside Edit and Trash in the top toolbar prevents article edits; clicking a locked article shows an unlock reminder in the page header. The square-and-pencil **New page** icon opens the page-creation menu.
5. Select **Sources** to import UTF-8 `.txt` / `.md` files or paste text with an optional original URL. Originals cannot be edited in the app. Imported Markdown also has an Original view.

**⌘S** saves immediately, **⌘P / ⇧⌘F** focuses vault search, **⌘B / ⌘I / ⌘U** toggles bold/italic/underline, and **⌘K** edits a hyperlink, and **⇧⌘I** imports sources. Editing saves after 500 ms of inactivity. Page title changes keep the filename stable and add the old title as an alias, so links continue working.

Sources and wiki pages are independent in v1. No AI provider is contacted. Raw data stays distinguishable from your interpretation.

## Block editing

Type `/` in an empty paragraph or after whitespace to search block commands. The compact menu opens directly above or below the caret within the visible editor, scrolls to fit the available space, separates basic and semantic blocks, and shows semantic icon colors. Aliases such as `/h2` and `/ques` and fuzzy matching are supported; use arrows and Return, or Escape to dismiss. Paragraphs, three heading levels, bullets, numbering, tasks, quotes, code, dividers, callouts, and nested toggles share the same command layer.

The caret and block accent stay aligned when you start typing in an empty block after choosing a command.

Question, Idea, Important, Starred, Definition, Example, Insight, Warning, Reference, and Summary add editable semantic icons outside the article margin without replacing a heading or list structure. Bullets, numbering, checkboxes, and toggle arrows sit inside the margin. Semantic blocks, quotes, callouts, and code have extra vertical spacing. Semantic names and statuses remain available to VoiceOver and **Block Actions**; Question and Idea have optional statuses there. Use **⇧⌘B** or the native context menu for conversion, tags, status, duplication, Markdown copy, block links, moving, indentation, deletion, and inline formatting. Hover at the left margin to reveal a drag handle and click it for block actions. Native drag/drop remains an outstanding acceptance issue; use Move up/down or ⌥⌘↑/↓ to reorder a subtree. Tab/Shift Tab explicitly changes nesting.

Return splits a block and continues lists; Return on an empty list item exits. Backspace at the start converts structural blocks to text before merging. Shift Return inserts a newline inside code. **⌘A** selects current-block text; **⌥⌘A** selects the document. **⌥⌘↑/↓** moves a block, and **⇧⌘Return** toggles a task. Native undo/redo covers typing and block commands. Plain text, Markdown, and RTF paste preserve supported formatting; unsupported Markdown stays literal, and pasted RTF attachments retain the original RTF in metadata for recovery.

Blocks persist as readable Markdown with a versioned JSON envelope in a trailing HTML comment. It preserves UUIDs, rich formatting, semantic metadata, and the complete tree. Opening ordinary Markdown does not rewrite it. External Markdown changes take precedence over a stale envelope; its previous payload is kept for recovery and a notice is shown. A future envelope version opens read-only. See [BLOCK_EDITOR.md](BLOCK_EDITOR.md) for the compatibility decision and limits.

## Portable file format

```text
My Vault/
  vault.json                     # formatVersion: 1, stable vault UUID
  Wiki/
    Pertinax.md                  # frontmatter and editable Markdown body
  Sources/
    <source-uuid>/
      original.txt              # original bytes; may instead be original.md
      metadata.json             # identity, origin, capture time, checksum
  Conflicts/                    # preserved competing drafts/cloud versions
  .Trash/                       # recoverable removed pages, excluded from search
```

Wiki frontmatter contains `id`, `title`, `aliases`, `tags`, `created_at`, and `updated_at`. Unknown YAML fields are preserved semantically; YAML formatting/comments are not guaranteed to retain their original appearance after an app save. A Markdown file added externally is read without rewriting it; metadata is added on its first app save.

Source metadata contains `id`, `title`, `capturedAt`, `originalFilename`, optional `originURL`, `sha256`, and `storedFilename`. Originals are copied byte for byte. External source mutations are flagged rather than silently accepted. Source read-only behavior is an app rule; normal files remain accessible in Finder.

Local SQLite indexes and recovery drafts live in the app’s Application Support directory under `KnowledgeVault/<vault-uuid>` (the original storage name is retained so existing drafts remain recoverable). They are outside the synced vault. The index is disposable; **keep Drafts** if it contains unsaved work. Reopening a vault rebuilds a deleted search index from canonical files.

## iCloud and recovery

The app uses user-selected folder bookmarks, coordinated file reads/writes, and a file presenter to observe changes. iCloud Drive handles transport. **Saved locally** means the file was written on this Mac; it does not guarantee upload completion. Downloads and invalid files are surfaced under **Vault notices**. Use **Refresh from files** if another editor’s changes have not appeared yet.

If another editor changes a page while your draft is open, the app compares its content hash before saving. It keeps the disk version and preserves your competing draft in `Conflicts` and local recovery storage. Reload the disk version or save the draft as a new page. Detected iCloud conflict versions are copied before being marked resolved. Never use the index as your only backup; iCloud sync also propagates deletions.

Interrupted source imports remain in a hidden `.import-<uuid>` directory; completed sources are published only after both original and metadata exist. Removed pages remain in `.Trash` and can be restored in Finder.

## Testing

```sh
./scripts/test.sh
VAULT_BENCHMARK=1 ./scripts/test.sh --filter benchmarkFiveThousandEntries
```

Tests use temporary vaults and native editor fixtures, and cover block commands, caret/selection, undo/redo, rich paste, nesting, external-edit recovery, metadata round trips, original bytes, malformed imports, code-excluded links/tags, aliases, stale edits/deletions, trash, recovery drafts, full-text search, backlinks, and rebuilding indexes. The opt-in benchmark measures a 5,000-page initial scan/index, cached loading, and search p95. Cached loading is a service-level measurement; app launch/render time must also be assessed manually.

The test script locates the installed Swift Testing framework and disables cross-import overlays to support this machine’s command-line tools, which ship the Testing binary but omit the Foundation overlay module. Run the script directly in Terminal; a restricted automation environment may additionally require permission for Apple’s file-coordination service.

See `VALIDATION.md` for actual results and the outstanding two-Mac iCloud acceptance check.
