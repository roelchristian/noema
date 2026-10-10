# Noema

**A personal atlas of thought.**

A native macOS personal wiki, with a separate read-only library of raw sources.

The interface uses native macOS Liquid Glass navigation and toolbars, glass search and editing controls, and an orbital glass mark inspired by connected thoughts. Writing and source content retain readable standard backgrounds. The mark shares geometry with the packaged icon; see `Resources/Brand/README.md` for the exported layers and the current `.icns` packaging limitation.

**System appearance:** App chrome, controls, writing surfaces, selection, and previews follow macOS Light/Dark appearance, accent and highlight colors, and accessibility settings. Appearance settings are managed in System Settings; Noema no longer overrides them. Midnight Iris colors are confined to the orbital identity and icon exports.

The middle pane omits the window-title branding. Page and source headers use a compact 26-point title with reduced top spacing. Document controls sit in the main pane, centered vertically beside the title; creation and vault menus remain available there when no document is selected.

The middle page list starts at 385 points wide, about 1.75 times the sidebar's default 220 points. Sources uses a full-width native Finder-style table with sortable, resizable File Name, Original File Name, Location, Kind, Size, Availability, and Captured columns. Availability defaults to Available on addition. Use **Check Availability** in the source context menu or details sidebar, or **Source Actions → Check Availability of All Sources** beside Add Source. Checks queue serially with a muted spinner/message in the Availability column. Missing linked originals remain listed with an unavailable status after refresh; checks also report access, download, and imported-checksum problems. Selecting a source shows metadata and its saved AI-generated summary in a resizable sidebar to the right of the table. Double-clicking opens a separate native window: a read-only reader for UTF-8 Markdown, text, and HTML, or Quick Look for PDFs and other system-supported file formats. Unsupported Quick Look formats may have no content preview. Native split-view dividers remain resizable.

Selected pages also show a resizable details sidebar with file metadata and the saved AI summary, or a Generate AI Summary option. Use the Page details toolbar button or close button to toggle it. While it is open, the summary and generation indicator above the editor are completely hidden; closing it restores the existing summary display. Summary generation requires enabling Apple Intelligence summaries in Settings and an unlocked page. With page details open, action icons move below the page title. Both page and source sidebars initially show up to three lines of their AI summary; use Show more / Show less to expand or collapse it. Selecting a different item or replacing its summary resets the preview to three lines.

List rows have padded side margins and show the last-updated time for pages (capture time for sources): a time today, or a date for older entries. A saved AI summary appears as a two-line preview with a sparkles icon; pages without one show their opening content instead.

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
2. Select **Pages** to browse your writing. Swipe left on a page row to reveal **Delete** (moves it to recoverable vault trash after confirmation), or swipe right for **Lock** / **Unlock**. Locked pages show a lock icon beside their list title. These actions are also in the row’s context menu; page headers begin with the title. Use **New Personal Page** for optional Overview / Personal context / Connections headings, or create a blank page with ⌘N.
3. Add topics in the comma-separated field or write inline `#history` tags. Type `[[` for page suggestions. A link such as `[[Pertinax|my reading]]` can show a friendly label.
4. Click **Edit** or click the article text area once to start native block editing; click **Done** or press Escape to finish. The lock control beside Edit and Trash in the top toolbar prevents article edits; clicking a locked article shows an unlock reminder in the page header. The square-and-pencil **New page** icon opens the page-creation menu.
5. Select **Sources**, then **Add Source…** to link files. Check **Import into vault** to copy a file of at most 2 MB. Click a row to view metadata and its AI-generated summary; double-click to open its native reader or Quick Look window; originals cannot be edited in the app. Paste text remains available in the Vault menu.

**Add Source:** Click **Add Source…** (also in the Vault menu) and select up to **five files**. Folders are not supported. The picker defaults to linking without copying or modifying originals. Check **Import into vault** to copy files; imports larger than **2 MB (2,000,000 bytes)** are rejected, while linking has no import size limit. Accepted files appear immediately with the original filename in the second column and **Generating title** plus a spinner in File Name. One queue uses the same on-device article title rules to generate display names: a specific central-topic noun phrase, ideally 2–6 words and at most 8, in the detected language, with no synopsis or Markdown; **Renaming n of n files…** appears in muted text at the bottom. For each queued file, title and summary inference run concurrently on this Mac. The generated title and a concise summary are saved together in source metadata (`aiSummary`); summaries are not displayed in the table and survive later manual renames. Original filenames and bytes remain intact. The source context menu and metadata sidebar offer **Generate AI Summary**, or **Regenerate AI Summary** when one is saved. Generation preserves the display name and existing summary until it succeeds; actions are disabled during source inference. The file context menu offers **Rename** with a pencil icon to change this vault-only display name, and **Delete** with a trash icon and confirmation. Deleting a linked source removes its vault record and leaves the external original intact; deleting an imported source permanently removes its original and metadata from the vault. Changed originals or stale metadata block deletion until refreshed. Manual rename/delete takes precedence over pending AI naming. Text/Markdown/HTML and text-bearing PDFs provide naming content; unavailable Apple Intelligence, unreadable files, and unsupported content retain the original display name and show a notice. Location distinguishes linked files from in-vault originals; Size reports source bytes. **Refresh from Files** reloads linked content and sizes. Persisted linked access uses read-only security-scoped bookmarks specific to this Mac/app. Missing files or stale permissions appear in Vault notices. Older app versions cannot load linked records or binary originals; text imports remain compatible. Binary search content is not extracted.

**⌘S** saves immediately, **⌘P / ⇧⌘F** focuses vault search, **⌘B / ⌘I / ⌘U** toggles bold/italic/underline, and **⌘K** edits a hyperlink, and **⇧⌘I** imports sources. Editing saves after 500 ms of inactivity. Page title changes keep the filename stable and add the old title as an alias, so links continue working.

New pages created without a title receive an automatic on-device Apple Intelligence title from their content when you finish editing, save, switch pages or views, switch apps, or quit. Generation continues in the background after leaving the page and does not require focus. Titles name the central topic as a short, specific noun phrase rather than summarizing the article. Titles use the detected article language, falling back to the system preferred language, and Markdown formatting is removed. A native blue dot marks pages renamed while another page is selected or the app is inactive; opening the page clears it. These unread title indicators last for the current session. Quit waits for pending title attempts. User titles are preserved. Apple Intelligence must be available; otherwise the saved page keeps its placeholder title. Automatic title eligibility applies to pages created during the current session. Explicit ⌘S / Save Page and the top Done/checkmark also attempt naming for reopened pages whose title is blank or still an Untitled placeholder (including numbered placeholders).

Sources and wiki pages are independent in v1. No remote AI provider is contacted. Optional on-device Apple Intelligence summaries are available in **Noema → Settings… → Apple Intelligence**. Enable them, then click **Summarize** on an unlocked page. **Generating AI Summary...** appears as one compact centered line below the page title while working, without reserving space for the result. The new Summary block appears only after generation succeeds. The generated semantic Summary block is pinned above the editor and labeled **AI-generated summary**; regenerate it after edits. Scrolling down a long page smoothly collapses the summary to a small, single-line excerpt; Reduce Motion disables the animation. Both summary states use a subtle native frosted background across the full area between the dividers. Use Delete to delete the generated summary without deleting your writing. Use Show/Hide to expand or collapse it; returning to the top expands it again. It is saved in the portable block document. Apple Intelligence must be enabled and its model ready; failures leave the page unchanged. Raw data stays distinguishable from your interpretation.

## Block editing

Reading and editing use compact 80-point side margins, retaining a gutter for block icons and handles.

Type `/` in an empty paragraph or after whitespace to search block commands. The compact menu opens directly above or below the caret within the visible editor, scrolls to fit the available space, separates basic and semantic blocks, and shows semantic icon colors. Aliases such as `/h2` and `/ques` and fuzzy matching are supported; use arrows and Return, or Escape to dismiss. Paragraphs, three heading levels, bullets, numbering, tasks, quotes, code, dividers, callouts, and nested toggles share the same command layer.

The caret and block accent stay aligned when you start typing in an empty block after choosing a command.

Question, Idea, Important, Starred, Definition, Example, Insight, Warning, Reference, and Summary add editable semantic icons outside the article margin without replacing a heading or list structure. Icons are shown by default. In **Noema → Settings… → Block display**, turn on **Show semantic block headings** to display names such as Idea and Question above their text in both reading and editing views. This app-wide preference survives relaunch and does not change page content. Bullets, numbering, checkboxes, and toggle arrows sit inside the margin. Semantic blocks, quotes, callouts, and code have extra vertical spacing. Semantic names and statuses remain available to VoiceOver and **Block Actions**; Question and Idea have optional statuses there. Use **⇧⌘B** or the native context menu for conversion, tags, status, duplication, Markdown copy, block links, moving, indentation, deletion, and inline formatting. Hover at the left margin to reveal a drag handle and click it for block actions. Native drag/drop remains an outstanding acceptance issue; use Move up/down or ⌥⌘↑/↓ to reorder a subtree. Tab/Shift Tab explicitly changes nesting.

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

Source metadata contains `id`, `title`, `capturedAt`, `originalFilename`, optional `originURL`, `sha256`, and `storedFilename`. Imported originals are copied byte for byte; linked originals stay at their external location. External source mutations are flagged rather than silently accepted. Source read-only behavior is an app rule; normal files remain accessible in Finder.

Local SQLite indexes and recovery drafts live in the app’s Application Support directory under `KnowledgeVault/<vault-uuid>` (the original storage name is retained so existing drafts remain recoverable). They are outside the synced vault. The index is disposable; **keep Drafts** if it contains unsaved work. Reopening a vault rebuilds a deleted search index from canonical files.

## iCloud and recovery

The app uses user-selected folder bookmarks, coordinated file reads/writes, and a file presenter to observe changes. iCloud Drive handles transport. **Saved locally** means the file was written on this Mac; it does not guarantee upload completion. Downloads and invalid files are surfaced under **Vault notices**. Use **Refresh from files** if another editor’s changes have not appeared yet.

If another editor changes a page while your draft is open, the app compares its content hash before saving. It keeps the disk version and preserves your competing draft in `Conflicts` and local recovery storage. Reload the disk version or save the draft as a new page. Detected iCloud conflict versions are copied before being marked resolved. Never use the index as your only backup; iCloud sync also propagates deletions.

Interrupted source imports remain in a hidden `.import-<uuid>` directory; completed sources are published only after both original and metadata exist. Removed pages remain in `.Trash`. Select **Trash** below Sources to restore a page or permanently delete it after confirmation. Restore preserves the file bytes and persisted identity, uses an available filename in Wiki, and refuses an existing identity or title collision; rename the active page first to resolve a title collision.

If the empty `.Trash` folder is removed externally, Noema recreates it when refreshing Trash or moving a page there, so page creation and refresh can continue.

## Testing

```sh
./scripts/test.sh
VAULT_BENCHMARK=1 ./scripts/test.sh --filter benchmarkFiveThousandEntries
```

Tests use temporary vaults and native editor fixtures, and cover block commands, caret/selection, undo/redo, rich paste, nesting, external-edit recovery, metadata round trips, original bytes, malformed imports, code-excluded links/tags, aliases, stale edits/deletions, trash, recovery drafts, full-text search, backlinks, and rebuilding indexes. The opt-in benchmark measures a 5,000-page initial scan/index, cached loading, and search p95. Cached loading is a service-level measurement; app launch/render time must also be assessed manually.

The test script locates the installed Swift Testing framework and disables cross-import overlays to support this machine’s command-line tools, which ship the Testing binary but omit the Foundation overlay module. Run the script directly in Terminal; a restricted automation environment may additionally require permission for Apple’s file-coordination service.

See `VALIDATION.md` for actual results and the outstanding two-Mac iCloud acceptance check.
