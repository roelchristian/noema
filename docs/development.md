# Development

Requires macOS 26+ and Apple's Swift 6 command-line tools. The standing reference environment is Apple Silicon, macOS 27.0, Swift 6.2.4 and macOS SDK 26.2. Full Xcode is optional.

```sh
./scripts/run.sh
./scripts/build.sh debug
./scripts/build.sh release
./scripts/test.sh quick --skip-update
./scripts/test.sh standard --targets VaultCoreTests,NativeAuthenticationTests --skip-update
./scripts/test.sh extended --skip-update
./scripts/compile.sh
python3 scripts/check-storage-boundary.py --selftest
python3 scripts/check-repository-hygiene.py --selftest
codesign --verify --deep --strict dist/noema.app
```

Run commands at the repository root. The build packages and locally signs a sandboxed development app and creates `dist/noema.zip`; outputs remain untracked in `.build` and `dist`. This is ad-hoc signing, not notarization. Native file coordination, pasteboard, security scopes and icon packaging can require execution outside a restricted automation sandbox. See [validation](validation.md) for environment and acceptance limits.

External AI keys in these ad-hoc builds use the local login Keychain, with access restricted to the creating app. After rebuilding, an inaccessible saved key can be removed in OpenAI connection settings and saved again for the new build. Noema suppresses login-Keychain password dialogs for credential operations; if the Keychain is locked, unlock it separately in Keychain Access. A certificate-signed distribution requires provisioned app identity entitlements for the data-protection Keychain; changing signing modes does not migrate credentials. See the [credential contract](contracts/external-ai.md#authorization-lifecycle-contract).

To inspect an OpenAI validation failure, open **Settings → Intelligence → OpenAI connection**, enable **OpenAI debug mode** while a vault is unlocked, retry the action, then expand **Latest rejected OpenAI response**. The raw bounded response can include private content. Debugging lasts only for the current vault session; disabling it or ending that session clears the response. It is never saved to logs or history.

## Validation tiers and test discipline

`quick` selects domain test targets before SwiftPM builds its graph and excludes the
app/editor and specialised workloads. `standard --targets TargetA,TargetB` requires
an explicit affected-target list; include editor tests for UI changes and relevant
security/preservation tests when those boundaries change. `extended` runs every
retained functional target and is required before merging significant integration
work. Legacy flag-only `test.sh` calls retain full functional coverage. A SwiftPM
`--filter` narrows execution within the chosen graph; it does not isolate compilation.

Use `scripts/performance.sh` for opt-in benchmarks, the visual harnesses below for
full appearance matrices/captures, and `scripts/validate-fixtures.sh` for sample-vault
validation. `scripts/compile.sh` runs Swift compilation without icon generation,
app packaging or signing. Inspect each script's help before choosing specialised
SwiftPM flags. Native accessibility and crash-durability acceptance remain device checks.

Each added test must demonstrate a distinct regression risk, boundary condition or
contract. Extend an existing happy path when it already covers that risk. Reductions
need evidence of equivalent retained assertions; moving an exhaustive matrix into
specialised validation is different from deleting coverage. Protect transactional
integrity, revision conflicts, source-byte preservation, transaction rollback, recovery
drafts, authentication, AI submission consent and stale-result rejection. Markdown codecs and explicit import/export remain tested. Tests solely for retired
Markdown vault authority or historical schema upgrades are removed; canonical
schema-5 fixtures retain current revision, lifecycle, access and preservation checks.

## Test inventory and timing

`python3 scripts/test-inventory.py` reports physical source files, lines, Swift Testing
and XCTest declarations, parameterized declarations, known literal-array case counts
and unresolved dynamic collections per test directory. `--json` includes declaration
names/locations for before/after comparison. Counts include opt-in directories, not
just the active graph. Literal arrays with two argument collections count their
Cartesian product; `allCases`, dynamic arrays and loops require runtime logs. Neither
declaration counts nor known static cases imply tests actually executed or passed.

Capture inventory before a reduction in managed evidence, then repeat after it.
Run `python3 scripts/test-test-inventory.py` when changing the scanner. Check selected
SwiftPM graphs and verify every retained functional source remains in Extended;
moving workloads must conserve protected regression assertions. Run
`python3 scripts/test-validation-tiers.py` after manifest or runner changes; it
checks target selection, legacy harness routing and build-reuse guards. Review
runtime matrix cases as well as declaration counts; do not impose a numerical
test cap. Describe each new test's distinct risk and chosen tier in the PR.

Measure clean, incremental, warm and execution-only samples separately. Use the
same Mac/toolchain, dependency resolution, tier, flags and scratch build path for a
comparison; record the exact edit and retain failures. A clean build uses a fresh
scratch path without deleting existing caches or user data. Establish that graph,
then change one relevant source file for the incremental build. A comment-only edit
measures invalidation, not a semantic change; identify which was used. Repeat the
identical command without edits for warm end-to-end feedback. `--skip-build` gives
execution-only timing after a successful matching wrapper build using the same tier,
targets and specialised gates. Direct `swift` builds do not establish the wrapper's
graph stamp; first rerun the matching normal wrapper. Take at least three samples
per phase and compare medians; include filesystem-cache/dependency limitations.

```sh
python3 scripts/benchmark-validation.py --run-id test-clean-01 --phase clean -- \
  ./scripts/test.sh quick --scratch-path .local/agent-runs/test-clean-01/build --skip-update
# Preserve the shared scratch build while collecting dependent samples:
touch .local/agent-runs/test-clean-01/.pinned
# After a single recorded source-file edit, reuse that scratch path:
python3 scripts/benchmark-validation.py --run-id test-incremental-01 --phase incremental \
  --change 'Sources/VaultCore/<file>.swift: describe exact edit' -- \
  ./scripts/test.sh quick --scratch-path .local/agent-runs/test-clean-01/build --skip-update
python3 scripts/benchmark-validation.py --run-id test-warm-01 --phase warm -- \
  ./scripts/test.sh quick --scratch-path .local/agent-runs/test-clean-01/build --skip-update
python3 scripts/benchmark-validation.py --run-id test-execution-01 --phase execution -- \
  ./scripts/test.sh quick --scratch-path .local/agent-runs/test-clean-01/build --skip-build
```

The recorder saves command, source revision/status, toolchain, inventory, elapsed
wall time, exit code and full command output under a fresh managed run. Its timeout
defaults to 300 seconds; increase explicitly for full builds. Pin any shared scratch
run needed across samples so age-based cleanup cannot remove it. The recorder labels
phases; the operator must satisfy each phase's cache/edit preconditions. No speedup
or suite-reduction percentage is established until comparable successful samples
are collected. The proposed 50% faster Quick feedback and 25–35% reduction remain
provisional goals, and coverage takes priority over a numerical target.

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

Successful test/build wrappers run age-based cleanup. `--force` bypasses age only; active/pinned runs remain protected and completion is still required. Cleanup never targets user vaults, worktrees, recovery data, previews or protected fixtures. Its dedicated managed-root and symlink checks prevent path escape. Periodic development maintenance can run the same command.

## Documentation maintenance

Update current contracts in place; remove superseded statements. Routine passing runs belong in the PR validation section (normally at most 15 lines), not a new report or appended journal. Update [validation](validation.md) only for a changed baseline, procedure, acceptance status or limitation. New permanent decisions must explain lasting choices and belong under `docs/decisions/`; do not archive execution reports there.

The hygiene checker fails on root Markdown outside `README.md`/`AGENTS.md`, tracked local output, generated validation artifacts or documentation evidence directories, historical-report names and broken repository documentation references. Size limits initially warn: 120 lines for agent policy; approximately 200–300 lines for standing validation. Never shorten safety contracts or suppress failure evidence to meet a numerical limit.

## Native workspace controls

The standard unified window toolbar (`.unified`, Finder-sized icons) presents the active collection
(`Pages`, `Sources`, `Knowledge`, `Trash`) or opened document title once, alongside
navigation, document editing and lock controls, and global commands without a second
competing title bar below it. Page sorting stays with the collection list. Its contextual actions
menu provides Add to…, Move to…, Rename, summary actions and Delete. Add to…
checkmarks current collection/folder memberships and supports removal. Move to…
changes only the current container membership; elsewhere, choose the source from
the From submenu. Favourites remain independent, and membership removal keeps the
underlying page/source. Container contents show child folders for browsing and
consistent page/source/knowledge rows; use the header menu for contextual folder creation. `⌃⌘S` toggles sidebar, `⌃⌘L` toggles the collection list, `⌥⌘I` toggles
contextual inspector, and
`⇧⌘F` expands and focuses toolbar vault search; `⌘P` opens title-oriented Quick Open
in the same control. Search retains the current document, query and library scope;
Up/Down selects a quick result and Return opens it. Escape dismisses results first,
then collapses the field. Narrow windows use an anchored field presentation.
Scope refinement supports All, Pages, Sources and Semantic Blocks; **Show all results**
opens the full list, with **Return to workspace** preserving the previous document.
Sidebar, collection-list, and inspector intent
and divider widths persist independently; narrow windows can temporarily hide a pane
without changing intent. The collection list collapses before the content pane is
reduced below its minimum. Welcome/locked and open workspace have separate saved frames.
Validate native divider restoration, minimum-size collapse, full-screen transitions
and auxiliary-window isolation using the [standing matrix](validation.md#native-window-acceptance).

## Core workflow

Create a temporary schema-8 vault for a tour. Keep personal vaults outside this source repository.

### Vaults
- **Create a vault:** Click **Create a vault** (default name **My Knowledge Vault**) and choose a parent folder such as **iCloud Drive / Noema**. Creation publishes a complete plaintext schema-8 SQLite vault only after confirmation and rejects occupied names. Optionally enable **Require authentication in Noema** before creation: Noema then authenticates before showing the new vault. Cancelling authentication preserves the created folder and its preference for a later **Open Vault** retry. **Encrypted vault** remains unavailable; encryption and recovery-key protection are separate future work.
- **Access authentication:** **Settings → Vault Access** changes the open vault's preference after native macOS authentication. Enabled vaults require a fresh attempt on initial opening, unlocking, reopening after close, or restarting Noema; selecting the same locked folder to restore permission follows the same requirement. Existing vaults default to disabled. The preference is stored locally under the vault UUID and does not travel with the folder to another Mac. This protects casual access through Noema; editable preferences, direct filesystem access and compromised process code remain outside the boundary. Files, indexes, drafts and previews remain plaintext. Native prompt/accessibility acceptance remains [pending](validation.md#native-authentication-device-acceptance).
- **Vault menu, session locking & notices:** The vault-name menu at the bottom of the sidebar (and the **Vault** menu bar item) groups **Open Vault in Finder**, **Refresh from Files**, **Lock Vault** / **Unlock Vault** (`⌥⌘L`), **Close Vault** (`⇧⌘W`), **Trash** (with item count), recoverable drafts, vault notices, and **Open / Create Vault…**. Locking a vault flushes or journals pending edits, closes open source readers and dismisses the modal Settings sheet (including any nested sheet), detaches the search index and closes canonical SQLite storage, clears loaded notes and sources from memory, and revokes in-app session access until unlocked (application-level access revocation; Markdown or SQLite/WAL and source files remain plaintext until cryptographic vault storage is enabled). Global Settings (`⌘,`) presents as a workspace-modal sheet with sidebar categories (**Personalisation**: Appearance, Reading & Editor; **Intelligence**: Intelligence, OpenAI; **Security**: Vault Access), gating workspace commands while open and remaining accessible while locked. Error banners and vault notices can be dismissed individually or with **Dismiss All** for the current session.

### Pages
- **Browse & organize:** Select **Pages**, **Sources**, or **Knowledge** in the sidebar. The middle list stays visible while the selected page or source opens on the right. Sort Pages by update date or title from that list, and filter Pages by tag there. The sidebar keeps **Pages**, **Sources**, and **Knowledge** above a shared **Recent Items** list of up to ten successfully opened items. Choosing a recent item opens it; choosing a document from the list does not move the sidebar highlight onto Recent. Recent block entries jump to their parent page and block. History stores identifiers locally per vault and is hidden while locked. **Return to Library** (`⌘[`) clears the open document and reveals the list. Create a blank page (`⌘N`) or use **New Personal Page** for an Overview / Personal context / Connections template.
- Successful opens update persisted recency immediately. Visible Recent Items keep survivor order during the unlocked vault session, append newly encountered items, and remove evicted or unavailable entries; catalog refresh and renames do not reshuffle rows. Opening or unlocking a vault restores the latest most-recent-first order. Selection uses typed item identity, including distinct page and block entries.
- **Links & tags:** Add comma-separated topics or inline `#tags`. Type `[[` for wiki-link suggestions (`[[Pertinax|my reading]]`). Renaming a page keeps its filename stable and records the old title as an alias so existing links continue to resolve.
- **Editing lock:** Toggle **Lock Editing** via row swipe, hover/focus button, toolbar, context menu, or **Properties → Status → Editing** in the inspector. Locking prevents accidental content or reference edits without encrypting the file or changing its `updated_at` timestamp.
- **Provenance references:** Link pages and sources many-to-many under **References → Sources** for a page or **References → Referring pages** for a source. Linked items can be opened directly from the inspector even when a page is locked.

### Sources
- **Add sources (`⇧⌘I`):** Select up to 5 files at a time via **Add Source → From Files…**, paste text from the **Vault** menu, or capture up to 5 HTTP/HTTPS pages (HTML, plain text, or PDF up to 2 MB, 20-second timeout) via **Add Source → By URL…**.
- **Linked vs. imported:** File selection links external originals via read-only security-scoped bookmarks by default. Check **Import into vault** to copy files up to **2 MB (2,000,000 bytes)** into the vault. Folders and duplicate sources (matched by byte checksum or linked path) are rejected.
- **Inspect & read:** Sources appear in a sortable Finder-style table (**File Name**, **Original File Name**, **Location**, **Kind**, **Size**, **Availability**, **Captured**) with a resizable metadata and AI-summary inspector. Double-click a row to open a read-only native text reader or Quick Look preview. Context menus support vault-only **Rename** and **Delete**.
- **Check availability:** Use **Check Availability** (per source or via **Source Actions → Check Availability of All Sources**) to verify linked files, imported checksums, or URL reachability off the main actor. Unreachable URL captures are marked archived while keeping their captured bytes, title, and summary intact.

### On-device Apple Intelligence
Automatic title, classification and source processing run locally via Apple Intelligence. **Noema → Settings… → Intelligence** selects the default provider, local summary opt-in, summary placement, subordinate **Advanced** per-action overrides, and **AI Activity…**; action overrides never change background processing. **Settings → OpenAI** groups credential/model connection, content-sharing confirmation policy, and collapsed diagnostics; see the [external AI contract](contracts/external-ai.md). Local features include:
- **Automatic titles & source naming:** Untitled new pages receive a concise topic title in the detected language when you save, switch views, or quit (and on explicit `⌘S` / **Done** for reopened `Untitled` pages). Pages renamed in the background display a session blue dot. Newly added text, Markdown, HTML, and text-bearing PDF sources queue concurrent on-device title (2–6 words, max 8) and summary generation (`aiSummary`).
- **Page & source summaries:** Use **Summarize** or **Regenerate Summary** in **Insights → AI summary** on an unlocked page or source. The section retains selected-provider and consent disclosure, generation status, and saved provider/model provenance; its **Summary options** menu offers Copy, Delete (pages), cancellation and Intelligence settings. The document actions menu exposes the same summary commands when the inspector is closed. OpenAI defaults to asking before sending; Settings also offers once per unlocked vault session or no routine confirmation; an authenticated session uses compact disclosure with an expandable exact-text preview. Native page summaries require the preserved local opt-in. Page summaries pin a collapsible **AI-generated summary** banner above the editor and appear in the inspector; regeneration and summary management remain in Insights and the document menu. **Summary placement** can be set to **Editor when sidebar is closed** (default) or **Sidebar only**.
- **Generated metadata:** Summarize/Regenerate updates summary and verified LCC together in one structured inference. Properties shows classification code, local caption and provenance as read-only metadata. Existing human titles and page bodies are preserved; an unset title can be filled on initial enrichment. **Suggest Title** remains an explicit reviewed proposal. Legacy classifications remain readable until enrichment replaces them; removing a summary preserves classification. Preferences consolidate Content enrichment and Page creation, with legacy summary choices taking precedence over the retired LCC override.
- **Create pages with AI:** **Create Page with AI** offers an existing source, a topic researched with Bing (up to three readable results), or a URL fetched locally (2 MB, 20 seconds, public destinations only). Both providers produce a title, body, summary and classification together. Review the draft and title before **Publish Page**. Source relationships and verified web references are retained. URL mode can retain the capture as a source at publication; that intact source remains if the subsequent page write fails. No cloud operation starts merely by import or provider selection.

### Knowledge entity properties

In **Knowledge → Knowledge Entities**, open an entity to inspect its reusable typed
properties. Document entity rows also expose **Entity properties…** in their menu.
Search for an existing definition or create one with a scalar or entity-reference
kind and one/many cardinality. Dates accept `YYYY`, `YYYY-MM` or `YYYY-MM-DD` without
inventing a day or timezone. Empty text, zero and false are values; Remove unsets a
value while retaining the entity and reusable definition. The initial list shows
four entries; **Show all** reveals the rest.

Entity pickers search the canonical catalogue (up to 100 matches per query), with
type and UUID disambiguation. Incoming editing changes the same canonical edge as
outgoing editing. Reusable relationship definitions can set an incoming label and
suggested source/target types; those hints remain advisory. Deleted entities keep
read-only facts. Refresh after a revision conflict before retrying an edit. Native
keyboard, focus and VoiceOver acceptance still requires device review.

## Block and math editing

Select text and activate hyperlinks with ordinary clicks while reading. Press **Edit**, choose **Edit Article** in the context menu, or Option-click an unlocked article to start native block editing; edits autosave after 500 ms of inactivity. Document font family and size (`10–32 pt`, default `16 pt` for new preferences) are configurable in **Settings → Reading & Editor**. Existing saved sizes remain selected. Articles and readable Markdown, HTML and plain-text sources share these preferences; unavailable fonts retain their saved choice and use the system face. Headings, paragraph rhythm, code and semantic labels scale together within a centered reading measure capped at 680 pt. Controls, metadata and Quick Look retain native typography. See the [editorial contract](contracts/block-editor.md#editorial-typography).

- **Slash commands (`/`):** Type `/` in an empty block or after whitespace (with fuzzy matching and aliases like `/h2`, `/math`, `/ques`) to insert basic blocks (paragraphs, 3 heading levels, bullets, numbered lists, tasks, quotes, code, display math `$$`, dividers, callouts, nested toggles) or semantic blocks (**Question**, **Idea**, **Important**, **Starred**, **Definition**, **Example**, **Insight**, **Warning**, **Reference**, **Summary**).
- **Semantic blocks:** Semantic icons appear in the left margin (with optional statuses for **Question** and **Idea**); turn on **Settings → Reading & Editor → Show semantic block headings** to show labels above block text. The sidebar **Semantic Blocks** collection presents a compact two-line browser with contextual semantic-type filters and the page inspector indexes all tagged blocks across the vault for filtering and one-click jump navigation.
- **Math & TeX:** Supports inline (`$...$`, `\(...\)`) and display (`$$...$$`, `\[...\]`) math in the editor and previews. The article editor typesets equations locally with bundled KaTeX. While editing an article, click display math to reveal its LaTeX source and preview; click inline math to open its source popover (Return commits, Shift Return adds a line, Escape cancels). Configure reusable `\newcommand` macros (0–3 arguments) in **Settings → Reading & Editor → Custom Commands…** or define them inline.
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

## Portable Markdown file format

```text
My Vault/
  vault.json       # format 2; schema 8, UUID and required capabilities
  blocks.sqlite    # canonical pages, blocks, sources, knowledge and annotations
  Sources/         # immutable imported originals
  Conflicts/       # required preservation bytes
```

App-local RecoveryStore drafts remain outside the vault and may contain the only
unsaved copy. Search indexes are derived and rebuildable. All files remain plaintext.

## Local SQLite vault format

Creation initializes schema 8 directly in an owned staging root, verifies identity,
capabilities and integrity, closes the database and publishes create-only. Supported schema-6 vaults require the explicit upgrade/resume API described in the [knowledge contract](contracts/knowledge-model.md#typed-entity-properties-ent01) before typed properties can be used. No historical schema 1–5
format conversion or Markdown authority remains. Old and future formats reject without
mutation. Imported originals remain controlled immutable files; linked originals are
externally owned. SQLite metadata, page/source relationships and logical Trash use one
actor and transaction owner. Known synchronized/nonlocal roots reject; independently
local storage is required. Session locking is access control, not encryption.

`FileVaultRepository.archive(to:)` produces a version-1 native directory package with
an actor-owned SQLite backup, manifest, controlled originals and preservation files.
Each file has a byte length and SHA-256 entry. `NativeVaultArchive.restore` verifies
schema, identity, capabilities, foreign keys, page reconstruction and source checksums
before create-only publication to a new local destination. Restoration requires a
current destination-bound session lease; authentication remains the caller's admission
responsibility. Failed nonempty staging is retained. External linked originals and
application-local RecoveryStore drafts are explicitly excluded; archives capture
committed work, and must never be represented as capturing unsaved edits. These APIs
currently have no dedicated archive UI.

## Canonical fixture validation

The historical repository demo has been removed. Tests generate disposable supported-schema
vaults; no opaque generated SQLite database is committed. Run
`./scripts/validate-fixtures.sh --skip-update` for native archive integrity fixtures.

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
