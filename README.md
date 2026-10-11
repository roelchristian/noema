# Noema

**A personal atlas of thought.**

Noema is a native macOS personal wiki paired with a read-only library of raw sources. It combines a Liquid Glass interface, a structured block and TeX math editor, optional on-device Apple Intelligence, and portable plaintext storage.

## Highlights

- **Three-pane workspace:** A hierarchical sidebar (`250–290 pt`) with global search (`⌘K` / `⌘P` / `⇧⌘F`) and top-level **Pages**, **Sources**, and **Semantic Blocks** collections; a distraction-free main workspace; and a resizable right inspector for properties, provenance references, semantic blocks, and AI summaries.
- **Native appearance & themes:** Starts with the **Midnight Iris** palette. **Settings → Appearance** offers **System**, **Midnight Iris**, **Forest**, **Amber**, and **Rose**, with live dropdown previews and a toggle to apply the full palette or accent color only. Every theme adapts to macOS Light/Dark appearance and accessibility settings.
- **Brand & identity:** Uses an orbital glass mark that shares geometry with the packaged icon (see [Resources/Brand/README.md](Resources/Brand/README.md)). **Noema → About Noema** presents the Greek and phenomenological background of the name in a fixed `660 × 560 pt` window.

## Build and run

Requires macOS 26+, Apple’s Swift 6 command-line tools, and internet access for the first dependency download. Full Xcode is optional. (Tested on macOS 27 with Swift 6.2.4 and the macOS 26.2 SDK.)

```sh
./scripts/run.sh
```

For an optimized release build:

```sh
./scripts/build.sh release
open "dist/noema.app"
```

The build script packages and locally signs a sandboxed development app and creates `dist/noema.zip` (stripping Finder/iCloud extended attributes so it can be moved out of iCloud-backed folders). Dependencies are pinned in `Package.resolved` and build outputs stay in `.build`.

## Core workflow

For a quick tour, open `Examples/Demo Vault`. Keep your personal content vaults outside this source repository.

### Vaults
- **Create a vault:** Click **Create a vault** (default name **My Knowledge Vault**) and choose a parent folder such as **iCloud Drive / Noema**. Creation publishes a complete plaintext v1 folder only after confirmation and rejects occupied names. (**Encrypted vault** is shown as **Coming soon**; Touch ID and recovery keys are not yet enabled.)
- **Vault menu & notices:** The vault-name menu at the bottom of the sidebar groups **Open Vault in Finder**, **Refresh from Files**, **Trash** (with item count), recoverable drafts, vault notices, and **Open / Create Vault…**. Error banners and vault notices can be dismissed individually or with **Dismiss All** for the current session.

### Pages
- **Browse & organize:** Select **Pages** to search, sort (by update date or title), and filter by tag in the main workspace, or use **Recent Pages** and **All Pages** in the sidebar. Create a blank page (`⌘N`) or use **New Personal Page** for an Overview / Personal context / Connections template.
- **Links & tags:** Add comma-separated topics or inline `#tags`. Type `[[` for wiki-link suggestions (`[[Pertinax|my reading]]`). Renaming a page keeps its filename stable and records the old title as an alias so existing links continue to resolve.
- **Editing lock:** Toggle **Lock Editing** via row swipe, hover/focus button, toolbar, context menu, or the inspector **Protection** row. Locking prevents accidental content or reference edits without encrypting the file or changing its `updated_at` timestamp.
- **Provenance references:** Link pages and sources many-to-many under **Page details → Sources** or **Source details → Pages**. Linked items can be opened directly from the inspector even when a page is locked.

### Sources
- **Add sources (`⇧⌘I`):** Select up to 5 files at a time via **Add Source → From Files…**, paste text from the **Vault** menu, or capture up to 5 HTTP/HTTPS pages (HTML, plain text, or PDF up to 2 MB, 20-second timeout) via **Add Source → By URL…**.
- **Linked vs. imported:** File selection links external originals via read-only security-scoped bookmarks by default. Check **Import into vault** to copy files up to **2 MB (2,000,000 bytes)** into the vault. Folders and duplicate sources (matched by byte checksum or linked path) are rejected.
- **Inspect & read:** Sources appear in a sortable Finder-style table (**File Name**, **Original File Name**, **Location**, **Kind**, **Size**, **Availability**, **Captured**) with a resizable metadata and AI-summary inspector. Double-click a row to open a read-only native text reader or Quick Look preview. Context menus support vault-only **Rename** and **Delete**.
- **Check availability:** Use **Check Availability** (per source or via **Source Actions → Check Availability of All Sources**) to verify linked files, imported checksums, or URL reachability off the main actor. Unreachable URL captures are marked archived while keeping their captured bytes, title, and summary intact.

### On-device Apple Intelligence
No remote AI provider is contacted; all inference runs locally via Apple Intelligence (**Noema → Settings… → Apple Intelligence**):
- **Automatic titles & source naming:** Untitled new pages receive a concise topic title in the detected language when you save, switch views, or quit (and on explicit `⌘S` / **Done** for reopened `Untitled` pages). Pages renamed in the background display a session blue dot. Newly added text, Markdown, HTML, and text-bearing PDF sources queue concurrent on-device title (2–6 words, max 8) and summary generation (`aiSummary`).
- **Page & source summaries:** Click **Summarize** on an unlocked page (or **Generate / Regenerate AI Summary** in the page or source inspector). Page summaries pin a collapsible **AI-generated summary** banner above the editor and in the inspector; **Show page summaries** can be set to **Editor when sidebar is closed** (default) or **Sidebar only**.
- **Create pages with AI:** Choose **Create Page with AI** on a source to draft an editable wiki page from its first 6,000 characters with the source linked automatically. Choose **New page → From topic with AI…** to query Bing web search, fetch up to 3 readable top results (≤ 2 MB each), and synthesize a cited article on-device (fails cleanly without a model-knowledge fallback if search/results are unreadable).

## Block and math editing

Click an unlocked article or press **Edit** to start native block editing; edits autosave after 500 ms of inactivity. Font family and size (`10–32 pt`, default `15 pt` for pages and `14 pt` for source readers) are configurable in **Settings → Editor**.

- **Slash commands (`/`):** Type `/` in an empty block or after whitespace (with fuzzy matching and aliases like `/h2`, `/math`, `/ques`) to insert basic blocks (paragraphs, 3 heading levels, bullets, numbered lists, tasks, quotes, code, display math `$$`, dividers, callouts, nested toggles) or semantic blocks (**Question**, **Idea**, **Important**, **Starred**, **Definition**, **Example**, **Insight**, **Warning**, **Reference**, **Summary**).
- **Semantic blocks:** Semantic icons appear in the left margin (with optional statuses for **Question** and **Idea**); turn on **Settings → Block display → Show semantic block headings** to show labels above block text. The sidebar **Semantic Blocks** collection and the page inspector index all tagged blocks across the vault for filtering and one-click jump navigation.
- **Math & TeX:** Supports inline (`$...$`, `\(...\)`) and display (`$$...$$`, `\[...\]`) math in the editor and previews. Configure reusable `\newcommand` macros (0–3 arguments) in **Settings → Math & TeX → View or Edit Custom Commands…** or define them inline.
- **Shortcuts & actions:**

| Shortcut | Action |
| :--- | :--- |
| `⌘S` | Save immediately |
| `⌘K` / `⌘P` / `⇧⌘F` | Focus global vault search (`⌘K` edits a hyperlink while editing text) |
| `⇧⌘I` | Add sources from files |
| `⌘B` / `⌘I` / `⌘U` | Toggle bold, italic, or underline |
| `⇧⌘B` | Open Block Actions menu (convert, tag, status, duplicate, copy Markdown/link, move, delete) |
| `⌥⌘↑` / `⌥⌘↓` | Move block or subtree up / down |
| `Tab` / `Shift-Tab` | Indent / outdent block nesting |
| `⇧⌘Return` | Toggle task checkbox (`Shift-Return` inserts a newline in code/math) |
| `⌘A` / `⌥⌘A` | Select current block text / select entire document |

- **Markdown compatibility:** Plain text, Markdown, and RTF paste preserve supported formatting (with original RTF retained in metadata for recovery). Blocks persist as readable Markdown with a versioned JSON envelope in a trailing HTML comment. Opening ordinary external Markdown does not rewrite it, and external Markdown edits take precedence over a stale envelope. See [BLOCK_EDITOR.md](BLOCK_EDITOR.md) for details.

## Portable file format

```text
My Vault/
  vault.json                     # formatVersion: 1, stable vault UUID
  Wiki/
    Pertinax.md                  # frontmatter and editable Markdown body
  Sources/
    <source-uuid>/
      original.txt              # original bytes; may instead be original.md, .pdf, etc.
      metadata.json             # identity, origin, capture time, checksum, optional AI summary
  Conflicts/                    # preserved competing drafts and iCloud conflict versions
  Removed Pages/                # recoverable trashed pages and source directories (15-day retention)
  Trash Retention.json          # first-seen timestamps for undated trash entries
```

- **Wiki frontmatter:** `id`, `title`, `aliases`, `tags`, optional `lcc` (Library of Congress Classification code), `created_at`, `updated_at`, and optional `sources` UUID references and lock state. Unknown YAML fields are preserved semantically; external Markdown files receive frontmatter only on their first app save.
- **Source metadata:** `id`, `title`, `capturedAt`, `originalFilename`, optional `originURL`, optional `lcc`, `sha256`, `storedFilename`, and optional `aiSummary`, `fileSize`, `linkedBookmark`, `isURLSource`, and `webAvailabilityIssue`. Imported originals are stored byte-for-byte via staged `.import-<uuid>` directories and published only once both original and metadata exist.
- **App-local storage:** Rebuildable SQLite search indexes and unsaved recovery drafts live outside the synced vault under `~/Library/Application Support/KnowledgeVault/<vault-uuid>`. Keep `Drafts` if you have unsaved recovery work; deleting the SQLite index simply triggers a rebuild on next open.

## iCloud, conflicts, and Trash

- **Coordinated sync:** Noema uses security-scoped folder bookmarks, `NSFileCoordinator`, and a file presenter to observe external changes. **Saved locally** confirms a local write on this Mac, not completion of an iCloud upload. Use **Refresh from Files** if external edits have not yet appeared.
- **Conflict preservation:** If a page changes on disk while you are editing, Noema keeps the disk version and saves your competing draft to `Conflicts/` and local recovery storage so you can reload or save as a new page. iCloud conflict versions are copied before being marked resolved.
- **Recoverable Trash (`Removed Pages`):** Open **Trash** from the bottom-left vault menu to restore or permanently delete trashed pages and source records in a single unified list (external linked files are never deleted). Restore checks for identity, title, or duplicate-source collisions, while **Empty Trash…** and permanent deletion verify snapshots so modified, unreadable, or conflicted items are preserved and reported. Items in `Removed Pages` expire automatically after **15 days** on vault open/refresh (undated items receive a full 15-day grace period, and any surviving legacy `.Trash` Markdown files are migrated automatically under coordinated access).

## Testing and architecture

Build and test wrappers automatically run the storage boundary guard (`python3 scripts/check-storage-boundary.py --selftest`; see [STORAGE_ACCESS_AUDIT.md](STORAGE_ACCESS_AUDIT.md)).

```sh
./scripts/test.sh
VAULT_BENCHMARK=1 ./scripts/test.sh --filter benchmarkFiveThousandEntries
```

`./scripts/test.sh` configures the command-line Swift Testing framework flags and runs the regression suite across temporary vaults and native editor fixtures (covering block editing, TeX macros, metadata round-trips, source integrity, conflict/trash recovery, and SQLite indexing). Run it directly in Terminal if an automation sandbox blocks macOS file coordination.

- See [ARCHITECTURE.md](ARCHITECTURE.md) for component boundaries, concurrency ownership, and the storage adapter contract.
- See [BLOCK_EDITOR.md](BLOCK_EDITOR.md) for block document persistence and Markdown compatibility.
- See [VALIDATION.md](VALIDATION.md) for recorded test evidence, benchmark baselines, and standing environment/two-Mac iCloud limitations.

