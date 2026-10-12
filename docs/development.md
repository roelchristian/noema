# Development

Requires macOS 26+ and Apple's Swift 6 command-line tools. The standing reference environment is Apple Silicon, macOS 27.0, Swift 6.2.4 and macOS SDK 26.2. Full Xcode is optional.

```sh
./scripts/run.sh
./scripts/build.sh debug
./scripts/build.sh release
./scripts/test.sh --skip-update
python3 scripts/check-storage-boundary.py --selftest
python3 scripts/check-repository-hygiene.py --selftest
codesign --verify --deep --strict dist/noema.app
```

Run commands at the repository root. The build packages and locally signs a sandboxed development app and creates `dist/noema.zip`; outputs remain untracked in `.build` and `dist`. This is ad-hoc signing, not notarization. Native file coordination, pasteboard, security scopes and icon packaging can require execution outside a restricted automation sandbox. See [validation](validation.md) for environment and acceptance limits.

External AI keys in these ad-hoc builds use the local login Keychain, with access restricted to the creating app. After rebuilding, an inaccessible saved key can be removed in OpenAI connection settings and saved again for the new build. Noema suppresses login-Keychain password dialogs for credential operations; if the Keychain is locked, unlock it separately in Keychain Access. A certificate-signed distribution requires provisioned app identity entitlements for the data-protection Keychain; changing signing modes does not migrate credentials. See the [credential contract](contracts/external-ai.md#authorization-lifecycle-contract).

To inspect an OpenAI validation failure, open **Settings → Intelligence → OpenAI connection**, enable **OpenAI debug mode** while a vault is unlocked, retry the action, then expand **Latest rejected OpenAI response**. The raw bounded response can include private content. Debugging lasts only for the current vault session; disabling it or ending that session clears the response. It is never saved to logs or history.

## Repository retention

Permanent content is source, tests, fixtures, canonical resources, current contracts and reproducible procedures. PRs retain concise commands/outcomes, environment, exceptions and unresolved acceptance. Logs, screenshots, benchmark samples, transcripts, investigations and intermediate reports are temporary local evidence.

Use `.local/agent-runs/<run-id>/`. Private local instructions belong in `AGENTS.local.md`. Do not commit either. Attach needed visual review material to a PR or designated review artifact; approved permanent fixtures require an exact path and durable reason in `scripts/repository-hygiene-fixtures.json`.

A run uses `.active` while executing (a file or lock directory), `.pinned` to retain it, `.complete` when execution finishes (including failure), and `.failed` to identify diagnostics from unsuccessful work. Remove `.active` only after work stops; failed runs also carry `.failed` and expire after seven days unless pinned. Cleanup requires `.complete`, protects active/pinned runs, and measures age from the completion marker. The seven-day default applies only to finished disposable outputs.

```sh
./scripts/cleanup-local-evidence.sh --older-than 7d --dry-run --protect-active
./scripts/cleanup-local-evidence.sh --older-than 7d --protect-active
# Explicit early deletion of otherwise eligible completed runs:
./scripts/cleanup-local-evidence.sh --force --dry-run
```

Successful test/build wrappers run age-based cleanup. `--force` bypasses age only; active/pinned runs remain protected and completion is still required. Cleanup never targets user vaults, worktrees, `Examples/Demo Vault`, recovery data, previews or protected fixtures. Its dedicated managed-root and symlink checks prevent path escape. Periodic development maintenance can run the same command.

## Documentation maintenance

Update current contracts in place; remove superseded statements. Routine passing runs belong in the PR validation section (normally at most 15 lines), not a new report or appended journal. Update [validation](validation.md) only for a changed baseline, procedure, acceptance status or limitation. New permanent decisions must explain lasting choices and belong under `docs/decisions/`; do not archive execution reports there.

The hygiene checker fails on root Markdown outside `README.md`/`AGENTS.md`, tracked local output, generated validation artifacts or documentation evidence directories, historical-report names and broken repository documentation references. Size limits initially warn: 120 lines for agent policy; approximately 200–300 lines for standing validation. Never shorten safety contracts or suppress failure evidence to meet a numerical limit.

## Native workspace controls

The native window toolbar presents the document title once, alongside navigation,
document editing and lock controls, and global commands. Its contextual actions menu
provides Rename, summary actions and Delete. `⌃⌘S` toggles sidebar, `⌥⌘I` toggles
contextual inspector, and
`⇧⌘F` expands and focuses toolbar vault search; `⌘P` opens title-oriented Quick Open
in the same control. Search retains the current document, query and library scope;
Up/Down selects a quick result and Return opens it. Escape dismisses results first,
then collapses the field. Narrow windows use an anchored field presentation.
Scope refinement supports All, Pages, Sources and Semantic Blocks; **Show all results**
opens the full list, with **Return to workspace** preserving the previous document.
Sidebar/inspector intent
and divider widths persist independently; narrow windows can temporarily hide a pane
without changing intent. Welcome/locked and open workspace have separate saved frames.
Validate native divider restoration, minimum-size collapse, full-screen transitions
and auxiliary-window isolation using the [standing matrix](validation.md#native-window-acceptance).

## Core workflow

For a quick tour, open `Examples/Demo Vault`. Keep your personal content vaults outside this source repository.

### Vaults
- **Create a vault:** Click **Create a vault** (default name **My Knowledge Vault**) and choose a parent folder such as **iCloud Drive / Noema**. Creation publishes a complete plaintext v1 folder only after confirmation and rejects occupied names. Optionally enable **Require authentication in Noema** before creation: Noema then authenticates before showing the new vault. Cancelling authentication preserves the created folder and its preference for a later **Open Vault** retry. **Encrypted vault** remains unavailable; encryption and recovery-key protection are separate future work.
- **Access authentication:** **Settings → Vault access on this Mac** changes the open vault's preference after native macOS authentication. Enabled vaults require a fresh attempt on initial opening, unlocking, reopening after close, or restarting Noema; selecting the same locked folder to restore permission follows the same requirement. Existing vaults default to disabled. The preference is stored locally under the vault UUID and does not travel with the folder to another Mac. This protects casual access through Noema; editable preferences, direct filesystem access and compromised process code remain outside the boundary. Files, indexes, drafts and previews remain plaintext. Native prompt/accessibility acceptance remains [pending](validation.md#native-authentication-device-acceptance).
- **Vault menu, session locking & notices:** The vault-name menu at the bottom of the sidebar (and the **Vault** menu bar item) groups **Open Vault in Finder**, **Refresh from Files**, **Lock Vault** / **Unlock Vault** (`⌥⌘L`), **Close Vault** (`⇧⌘W`), **Trash** (with item count), recoverable drafts, vault notices, and **Open / Create Vault…**. Locking a vault flushes or journals pending edits, closes open source readers and Settings (including its attached sheet), detaches the search index and file watcher, clears loaded notes and sources from memory, and revokes in-app session access until unlocked (application-level access revocation; files on disk remain plaintext v1 until cryptographic vault storage is enabled). Global Settings can be reopened while locked. Error banners and vault notices can be dismissed individually or with **Dismiss All** for the current session.

### Pages
- **Browse & organize:** Select **Pages** to search, sort (by update date or title), and filter by tag in the main workspace, or use **Recent Pages** and **All Pages** in the sidebar. Create a blank page (`⌘N`) or use **New Personal Page** for an Overview / Personal context / Connections template.
- **Links & tags:** Add comma-separated topics or inline `#tags`. Type `[[` for wiki-link suggestions (`[[Pertinax|my reading]]`). Renaming a page keeps its filename stable and records the old title as an alias so existing links continue to resolve.
- **Editing lock:** Toggle **Lock Editing** via row swipe, hover/focus button, toolbar, context menu, or **Properties → Status → Editing** in the inspector. Locking prevents accidental content or reference edits without encrypting the file or changing its `updated_at` timestamp.
- **Provenance references:** Link pages and sources many-to-many under **References → Sources** for a page or **References → Referring pages** for a source. Linked items can be opened directly from the inspector even when a page is locked.

### Sources
- **Add sources (`⇧⌘I`):** Select up to 5 files at a time via **Add Source → From Files…**, paste text from the **Vault** menu, or capture up to 5 HTTP/HTTPS pages (HTML, plain text, or PDF up to 2 MB, 20-second timeout) via **Add Source → By URL…**.
- **Linked vs. imported:** File selection links external originals via read-only security-scoped bookmarks by default. Check **Import into vault** to copy files up to **2 MB (2,000,000 bytes)** into the vault. Folders and duplicate sources (matched by byte checksum or linked path) are rejected.
- **Inspect & read:** Sources appear in a sortable Finder-style table (**File Name**, **Original File Name**, **Location**, **Kind**, **Size**, **Availability**, **Captured**) with a resizable metadata and AI-summary inspector. Double-click a row to open a read-only native text reader or Quick Look preview. Context menus support vault-only **Rename** and **Delete**.
- **Check availability:** Use **Check Availability** (per source or via **Source Actions → Check Availability of All Sources**) to verify linked files, imported checksums, or URL reachability off the main actor. Unreachable URL captures are marked archived while keeping their captured bytes, title, and summary intact.

### On-device Apple Intelligence
Automatic title, classification and source processing run locally via Apple Intelligence. **Noema → Settings… → Intelligence** selects the provider for explicit actions; action overrides never change background processing. Existing local summary opt-in and placement live under **On-device intelligence**. OpenAI content enrichment, title suggestions and page composition use the selected submission confirmation policy; see the [external AI contract](contracts/external-ai.md). Local features include:
- **Automatic titles & source naming:** Untitled new pages receive a concise topic title in the detected language when you save, switch views, or quit (and on explicit `⌘S` / **Done** for reopened `Untitled` pages). Pages renamed in the background display a session blue dot. Newly added text, Markdown, HTML, and text-bearing PDF sources queue concurrent on-device title (2–6 words, max 8) and summary generation (`aiSummary`).
- **Page & source summaries:** Use **Summarize** or **Regenerate Summary** in **Insights → AI summary** on an unlocked page or source. The section retains selected-provider and consent disclosure, generation status, and saved provider/model provenance; its **Summary options** menu offers Copy, Delete (pages), cancellation and Intelligence settings. The document actions menu exposes the same summary commands when the inspector is closed. OpenAI defaults to asking before sending; Settings also offers once per unlocked vault session or no routine confirmation; an authenticated session uses compact disclosure with an expandable exact-text preview. Native page summaries require the preserved local opt-in. Page summaries pin a collapsible **AI-generated summary** banner above the editor and appear in the inspector; regeneration and summary management remain in Insights and the document menu. **Show page summaries** can be set to **Editor when sidebar is closed** (default) or **Sidebar only**.
- **Generated metadata:** Summarize/Regenerate updates summary and verified LCC together in one structured inference. Properties shows classification code, local caption and provenance as read-only metadata. Existing human titles and page bodies are preserved; an unset title can be filled on initial enrichment. **Suggest Title** remains an explicit reviewed proposal. Legacy classifications remain readable until enrichment replaces them; removing a summary preserves classification. Preferences consolidate Content enrichment and Page creation, with legacy summary choices taking precedence over the retired LCC override.
- **Create pages with AI:** **Create Page with AI** offers an existing source, a topic researched with Bing (up to three readable results), or a URL fetched locally (2 MB, 20 seconds, public destinations only). Both providers produce a title, body, summary and classification together. Review the draft and title before **Publish Page**. Source relationships and verified web references are retained. URL mode can retain the capture as a source at publication; that intact source remains if the subsequent page write fails. No cloud operation starts merely by import or provider selection.

## Block and math editing

Select text and activate hyperlinks with ordinary clicks while reading. Press **Edit**, choose **Edit Article** in the context menu, or Option-click an unlocked article to start native block editing; edits autosave after 500 ms of inactivity. Document font family and size (`10–32 pt`, default `16 pt` for new preferences) are configurable in **Settings → Document reading and editing**. Existing saved sizes remain selected. Articles and readable Markdown, HTML and plain-text sources share these preferences; unavailable fonts retain their saved choice and use the system face. Headings, paragraph rhythm, code and semantic labels scale together within a centered reading measure capped at 680 pt. Controls, metadata and Quick Look retain native typography. See the [editorial contract](contracts/block-editor.md#editorial-typography).

- **Slash commands (`/`):** Type `/` in an empty block or after whitespace (with fuzzy matching and aliases like `/h2`, `/math`, `/ques`) to insert basic blocks (paragraphs, 3 heading levels, bullets, numbered lists, tasks, quotes, code, display math `$$`, dividers, callouts, nested toggles) or semantic blocks (**Question**, **Idea**, **Important**, **Starred**, **Definition**, **Example**, **Insight**, **Warning**, **Reference**, **Summary**).
- **Semantic blocks:** Semantic icons appear in the left margin (with optional statuses for **Question** and **Idea**); turn on **Settings → Block display → Show semantic block headings** to show labels above block text. The sidebar **Semantic Blocks** collection and the page inspector index all tagged blocks across the vault for filtering and one-click jump navigation.
- **Math & TeX:** Supports inline (`$...$`, `\(...\)`) and display (`$$...$$`, `\[...\]`) math in the editor and previews. Configure reusable `\newcommand` macros (0–3 arguments) in **Settings → Math & TeX → View or Edit Custom Commands…** or define them inline.
- **Block handles:** Hover a paragraph or focus the editor to reveal its content-relative handle. Click to select a block, Shift-click to extend the block selection, or Command-click to toggle membership. Drag a handle to reorder siblings; Escape cancels. Block Actions applies move, duplicate, delete, copy and transformations to the selected blocks. Native text selection remains available through the text itself.
- **Shortcuts & actions:**

| Shortcut | Action |
| :--- | :--- |
| `⌘S` | Save immediately |
| `⇧⌘F` | Focus full-vault toolbar search |
| `⌘P` | Quick Open by page/source title or page alias |
| `⌘K` | Edit a hyperlink while editing text |
| `⇧⌘I` | Add sources from files |
| `⌘B` / `⌘I` / `⌘U` | Toggle bold, italic, or underline |
| `⇧⌘B` | Open Block Actions menu (convert, tag, status, duplicate, copy Markdown/link, move, delete) |
| `⌥⌘↑` / `⌥⌘↓` | Move block or subtree up / down |
| `Tab` / `Shift-Tab` | Indent / outdent block nesting |
| `⇧⌘Return` | Toggle task checkbox (`Shift-Return` inserts a newline in code/math) |
| `⌘A` / `⌥⌘A` | Select current block text / select entire document |

- **Markdown compatibility:** Plain text, Markdown, and RTF paste preserve supported formatting (with original RTF retained in metadata for recovery). Blocks persist as readable Markdown with a versioned JSON envelope in a trailing HTML comment. Opening ordinary external Markdown does not rewrite it, and external Markdown edits take precedence over a stale envelope. See [block editor contract](contracts/block-editor.md) for details.

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
- **App-local storage:** `AppModel` places `search.sqlite` (and SQLite-managed `search.sqlite-wal` / `search.sqlite-shm` while present) and `Drafts/<note UUID>.json` under `<Application Support URL>/KnowledgeVault/<vault UUID>/`, outside the synced vault. The base is the runtime URL returned by Foundation for the user's Application Support directory; a sandboxed app can resolve it inside its app container. An unsandboxed example is `~/Library/Application Support/KnowledgeVault/<vault UUID>/`. Tests can substitute the base with `localStorageRoot`. Keep `Drafts` if you have unsaved recovery work; the search index is rebuildable. These files remain plaintext when the vault is locked.

## iCloud, conflicts, and Trash

- **Coordinated sync:** Noema uses security-scoped folder bookmarks, `NSFileCoordinator`, and a file presenter to observe external changes. **Saved locally** confirms a local write on this Mac, not completion of an iCloud upload. Use **Refresh from Files** if external edits have not yet appeared.
- **Conflict preservation:** If a page changes on disk while you are editing, Noema keeps the disk version and saves your competing draft to `Conflicts/` and local recovery storage so you can reload or save as a new page. iCloud conflict versions are copied before being marked resolved.
- **Recoverable Trash (`Removed Pages`):** Open **Trash** from the bottom-left vault menu to restore or permanently delete trashed pages and source records in a single unified list (external linked files are never deleted). Restore checks for identity, title, or duplicate-source collisions, while **Empty Trash…** and permanent deletion verify snapshots so modified, unreadable, or conflicted items are preserved and reported. Items in `Removed Pages` expire automatically after **15 days** on vault open/refresh (undated items receive a full 15-day grace period, and any surviving legacy `.Trash` Markdown files are migrated automatically under coordinated access).

## Example vault fixture validation

Run the example-vault quality checks when changing `Examples/Demo Vault` or its LCC
metadata:

```sh
./scripts/validate-fixtures.sh --skip-update
```

The script explicitly includes `NoemaFixtureValidationTests` with
`NOEMA_FIXTURE_VALIDATION=1` and filters the run to that target. The
[fixture checks](../Tests/NoemaFixtureValidationTests/DemoVaultFixtureValidationTests.swift)
require at least one demo page and source, decode their metadata with the production
codecs, and require a non-empty LCC for each. This sample-content requirement is
reviewed independently of runtime LCC serialization, persistence and source-to-page
inheritance assertions in the routine regression suite.

## Explicit visual validation

Routine tests retain text layout, selection/content preservation, color contrast and
inspector bounds assertions. Screenshot capture is excluded from the default Swift
package test graph. The dedicated `NoemaVisualValidationTests` target is included
only with `NOEMA_VISUAL_VALIDATION=1`; the harness scripts set that value and route
PNG output into an active managed evidence run:

```sh
validation/ui-design-tokens/capture.sh token-review baseline
# After making the proposed visual change:
validation/ui-design-tokens/capture.sh token-review after
python3 validation/ui-design-tokens/select-evidence.py --run-id token-review
validation/visual-validation/capture-typography.sh typography-review after
```

Both phases capture the current checkout; preserve the before captures before
changing sources. The token harness covers every applicable page/source inspector
tab at minimum, ideal and maximum widths across both themes, light/dark modes and
standard/increased contrast, plus workspace/native-control fixtures. Typography
capture exercises production article/source rendering with isolated preferences.
Successful captures are marked complete; selection can reopen a completed run.

The retired UI.TYP01 generator remains recoverable from
`2c68a2dff43f3195241bdf16491f138295a407de:Tests/NoemaEditorTests/TypographyBaselineCaptureTests.swift`.
Its baseline production ref is `b6cd5c73bdc97b49c8016ac0bd97fa28a1c743c4`.
Historical pre-token code is reproduced from Git history, rather than compatibility
branches in today's harness. Native raster captures establish fixture appearance;
live VoiceOver, focus, dragging, OS accessibility settings and pane resizing still
require the standing device acceptance procedure. Preserve images and provenance
according to the retention policy, and pin evidence needed for later review.
