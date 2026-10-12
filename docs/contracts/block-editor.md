# Block editor architecture and storage contract

## Storage decision and implementation gate (EDT.BLK01)

**Status: proposed for approval before canonical storage implementation.** This
contract selects the future format and migration rules; it does not claim human
approval or enable SQLite vaults. Production still supports only plaintext
Markdown vault format 1. The new `BlockStore` declaration has no implementation or
runtime consumer. Its review and the author/reviewer procedure in
[storage-boundary.md](storage-boundary.md#required-author-and-reviewer-disposition)
must be completed before changing canonical storage, construction or I/O ownership.

### Permanent layer separation

| Layer | Owner and responsibility |
| --- | --- |
| Interactive session | `EditorSession` owns the active value document, vault/page/session identity, revision, selection, changed IDs and mutation history. `BlockEditorCoordinator` bridges native composition, text storage and undo to that session; it does not own a second editable document. AppKit presentation is never an independent content authority. Invalid or ineffective `BlockMutation` commands leave the complete document unchanged and produce no undo, dirty notification or serialization. |
| Canonical domain document | `BlockDocument`, `EditorBlock`, rich runs and `BlockMutation` stay in `VaultCore`. Ordered children, stable UUIDs, source spellings and metadata are content; caret/layout/undo are session state. Storage must not replace this domain foundation with SQL rows exposed to the editor. |
| Persistence adapter | AppKit-independent [BlockStore](../../Sources/VaultCore/BlockStore.swift) loads a document snapshot and performs create-only or revision-checked save/delete by page UUID. One mode is selected per vault. Revisions are opaque, scoped to vault/page/mode and checked inside the commit window. Synchronous operations run off the main actor; no transaction across protocol calls is implied. |
| Export | `BlockDocumentCodec` produces readable Markdown and its lossless envelope. Markdown, HTML and other exports are projections of a committed snapshot or an explicitly selected draft. Export never becomes an autosave channel or silently changes vault mode. |

Page title, aliases, timestamps, lock state, classifications and source relationships
remain repository-owned metadata. Saving a document preserves them. Future compound
metadata/document updates require a repository operation committed atomically by the
selected adapter; sequential `BlockStore` calls do not establish that guarantee.

### One authority per vault

| Mode | Manifest and authoritative content | Compatibility |
| --- | --- | --- |
| `markdown` | Existing `vault.json` format 1 (`formatVersion`, `id`); an absent storage discriminator means `markdown` only for v1. Wiki frontmatter plus Markdown, including the checksummed `noema:document` envelope, is the single page authority. Existing Sources and Removed Pages layouts remain authoritative. | Existing local/iCloud Markdown vaults open unchanged. Opening and no-op editing never migrate or rewrite them. The current `FileVaultRepository` / `VaultContentStore` route remains in use. |
| `sqliteBlocks` | Future `vault.json` format 2 explicitly declares `storage.mode = "sqliteBlocks"`, `storage.schemaVersion = 1`, `storage.database = "vault.sqlite"`, and `storage.localOnly = true`, alongside the vault UUID. `vault.sqlite` is the sole authority for page metadata, ordered block documents, source metadata/relationships, tombstones/trash and conflict records. | Opt-in local vault only; format 1 clients reject it. Wiki Markdown files are exports, never fallback content. Unknown vault format, mode or required schema version fails closed without rewriting. |

The v2 manifest is a routing/identity contract, not a second page-content store.
Only the fixed contained database path is permitted. Future SQLite schema version
is also stored in the database; disagreement with the manifest rejects writable
open. A missing/damaged DB never authorizes importing an old Wiki directory as
canonical fallback. There is no mirrored Markdown write, background two-way sync,
or mixed per-page mode. Future explicit `markdown` manifests must declare their
supported vault format; do not add fields to existing v1 manifests on open.

SQLite transactions commit a complete page document and its revision together;
revisions are not exported text hashes. The adapter must retain stable IDs, order,
parentage, inline styles, original Markdown spellings, recovered envelope payloads
and metadata. A normalized schema may add indexes, but one lossless document payload
remains authoritative per page; reconstructed SQL views must not compete with it.
Search/embeddings remain derived and rebuildable, distinct from this canonical DB.

### Local-only SQLite and byte ownership

SQLite mode rejects iCloud ubiquity containers, cloud/file-provider roots, network
volumes and locations whose local status cannot be established. Storage selection
must validate the root before opening the DB and revalidate on reopen; a bookmark
or `localOnly` flag alone is insufficient. It must not put SQLite/WAL/SHM into
iCloud Drive, Dropbox or another file synchronizer, and cannot claim synchronization
by copying a live database. A local save means local commit, not transport delivery.
Offline closed-vault backup/transfer uses a consistent SQLite backup snapshot and
all owned source blobs, never a database-only copy while WAL may contain commits.

Imported source originals remain immutable checksum-validated blobs at the existing
contained `Sources/<UUID>/` locations, accessed through `VaultContentStore`.
In SQLite mode the source metadata/summary/reference records move to the DB;
legacy source JSON is migration input or backup, never a parallel writable authority.
The DB references originals by UUID, relative path and checksum; extracted text is
derived. Publication stages and validates a create-only blob before committing its
DB reference. Failure leaves a recoverable unreferenced blob; it must not delete
the only preserved original. Cross-file/DB publication is not a SQLite transaction.
Trash retains referenced blobs; permanent deletion needs the existing snapshot,
retention and explicit-review protections. Linked originals stay externally owned,
read-only and bookmark-scoped; unavailable/deleted sources keep their UUID references.

The future canonical SQLite connection belongs to a vault-bound actor/adapter
selected by `VaultStorageProvider`, never to editor/AppModel/export code.
`VaultContentStore` continues to own manifest and blob bytes, staging and backup
publication; it cannot emulate SQLite commits by reading/replacing live DB bytes.
DB/WAL/SHM access needs a narrowly owned, reviewed canonical SQLite boundary and
guard changes before implementation. Existing app-local search/activity SQLite
exceptions grant no permission for this canonical database. Containment, symlink,
security scope and stale/conflict safeguards remain mandatory.

`BlockStore` operations must validate the captured `VaultAccessGate` lease at
execution, including after suspension and before publication. Admission/draining,
quiescence/recovery and stale-result guards apply equally to DB operations. Locking
revokes application access; it does not encrypt SQLite, WAL, source blobs or backups.
The E-series encryption design remains a separate opt-in format/key/recovery decision
under [the storage replacement contract](../architecture.md#storage-adapter-replacement-contract-d016).
SQLite is not its replacement: that design must protect canonical DB/WAL/SHM,
manifest policy, source originals, recovery drafts, indexes, previews and backups,
with explicit migration and key-loss recovery. No crypto fields or claims are added.

### Content preservation and future types

Source references retain their existing ordered page-level UUID sequence, independent
of block style or location. AI-generated page summary blocks preserve `summary`,
`extra.aiGenerated`, generation facts and provenance; source summaries remain source
metadata. Accepted generated artifacts are durable content, while their search
projections are derived. They never replace originals and remain distinguishable
from personal interpretation. Semantic designation/status remains independent of
structural kind; retain unknown semantic strings and extension metadata.

String-backed `BlockKind` permits an unknown kind to survive current decoding.
Future adapters must preserve its kind, rich runs, children, timestamps and extension
payload, with a literal/fallback presentation instead of silently coercing it to a
paragraph. Clients must retain unknown JSON fields opaquely alongside the document
or reject writes; the current Codable model alone does not preserve arbitrary future
fields. Unsupported required document/schema versions open only through a supported
read-only preservation route or fail closed. Export must retain the lossless envelope
and warn when a selected lossy format cannot represent unknown types/metadata.

### Explicit migration and rollback specification

1. Obtain contract approval and implement/review storage selection, local-root checks,
   gates, schema negotiation, backup and crash recovery before offering migration.
   Quiesce and close writes, resolve conflicts or stop, preserve recovery drafts,
   and capture checksum-verified source-vault snapshots through existing boundaries.
   A preflight snapshot is not a publication authority after asynchronous work:
   revalidate captured source revisions, root capability and session identity before
   committing or selecting the destination. External changes stop migration without
   overwriting either version; retry starts from fresh observations.
2. Create an independent local destination vault with a new vault UUID and preserved
   page/block/source UUIDs. The original v1 vault stays untouched and authoritative
   for its own identity. Keep an explicit complete v1 backup, including source blobs,
   Removed Pages, conflicts, manifests and unsupported/recovered payloads. Inventory
   app-local recovery journals separately from the portable source root, retaining
   decoded drafts and opaque damaged/mismatched bytes with their original vault/page
   relationships. A new destination vault identity must not silently relabel old
   journals. Never infer that recovery drafts or damaged content are disposable
   migration evidence; if their safe mapping is unresolved, stop migration.
3. Build the destination in sibling staging. Import documents and metadata in DB
   transactions; copy/import originals with checksum verification, preserve linked
   bookmarks and unavailable references, unknown frontmatter and retained trash.
   Refuse migration if opaque unsupported content cannot be preserved losslessly.
4. Validate counts, UUID uniqueness, document equality, source relationships, original
   checksums, metadata/trash preservation, SQLite integrity and export/reimport fidelity.
   Close/checkpoint the database and ensure no required data remains only in WAL.
   Write the final v2 manifest in staging after validation, then publish the entire
   initialized destination by a create-only same-parent move. Manifest and DB are
   published as one staged vault, never by toggling the live source manifest first.
5. Open/verify the published destination and switch the application session only after
   success. Interrupted staging/publication leaves the original unchanged and never
   selects a partial destination. Preserve failed staging diagnostics under the
   approved lifecycle policy; do not delete source data or preserved recovery drafts.
   Staging containing unique recoverable content is preservation data, not disposable
   agent evidence: the local evidence cleanup policy does not authorize its deletion.
   If publication succeeds but destination verification/open fails, retain both the
   published destination and the original, and keep the source session selected or
   return to it through the established authorized admission route.
6. Rollback reopens the untouched original; later SQLite edits require explicit export
   or reverse migration into another independent Markdown vault. Never replay them
   silently into the backup. Repeated migration refuses occupied destinations.

Approval requires reviewer disposition plus acceptance for legacy Markdown identity
and bytes, unknown blocks/metadata, conflicts and stale writes, inaccessible sources,
local-root rejection, interrupted migration/commit, backup restoration and lock/switch
interleavings. Device, accessibility, crash/power-loss and two-Mac transport acceptance
remain standing gaps in [validation](../validation.md); service tests do not close them.

## Recovery authority and current guarantees

A committed canonical page, an unsaved editor draft and a preserved conflicting
version are independent content. Capture timestamps do not grant a draft authority
to overwrite canonical bytes. Recovery into the original page uses the repository's
expected-content check; a newer external edit rejects that write and retains the
external page, recovery journal and conflict copy. Reopening does not waive this
check. Saving as a new page is an explicit separate disposition with a new identity.
Derived search data can be rebuilt and must never supersede these copies.

[RecoveryStoreIsolationTests](../../Tests/VaultCoreTests/RecoveryStoreIsolationTests.swift)
covers corrupt/mismatched peer isolation, retained bytes across session changes and
repeated stale recovery attempts across reopen. [WikiPageAdapterTests](../../Tests/VaultCoreTests/WikiPageAdapterTests.swift)
covers edits/deletions racing the adapter commit, while
[VaultSaveQuiescenceTests](../../Tests/VaultCoreTests/VaultSaveQuiescenceTests.swift)
covers durable commit draining, pre-commit journaling and failed journaling returning
the session to open. These synthetic fixtures do not establish process-crash durability.

Current recovery journals serialize operations in their actor and validate the
session lease. A valid same-page journal write replaces the previous valid draft;
deletion checks decoded identity, not an expected draft revision. Callers must retain
existing save/quiescence serialization. Compare-and-swap between independently
competing journal writers and idempotent retry of recovery-as-new-page publication
are not current guarantees; future EDT.BLK/E-series recovery design must address
these before introducing additional writers or migration replay.

## Current Markdown editor compatibility

The editor retains a single native AppKit text system and the `AppModel.body` / repository / recovery path.

Canonical pages remain frontmatter plus Markdown in vault format 1. On an editor mutation, the body gains a trailing HTML comment (`noema:document`) containing base64-encoded JSON. The envelope has its own version (1), a SHA-256 of the readable Markdown, and a complete block tree: stable UUIDs, string-backed structure kinds, rich runs, independent semantic designation, optional status/language/icon/extension metadata, timestamps, and children. Array order is position. No sidecar or index becomes canonical, and coordinated writes/conflicts/recovery operate on the complete body atomically.

Opening plain Markdown does not rewrite it. Untouched imported block spellings survive saves, including unsupported tables, HTML, and images. Legacy `noema:block` markers import their IDs/tags. Changed blocks produce readable Markdown plus the lossless JSON envelope. Standard Markdown readers ignore the comment and retain a useful textual document, though callout/toggle semantics, underline/highlight, and statuses require noema for full presentation. Returning to the previous application is possible by retaining the file and editing the readable body; old versions do not understand the new metadata.

On reload, metadata is used only when its checksum matches the readable body and UUIDs are unique. An external Markdown edit wins over stale metadata; the old encoded payload is retained as `recoveredMetadata` in subsequent saves, so its formatting/tree can be recovered rather than silently overwriting the external edit. A recognized future envelope version opens read-only. Malformed/unrecognized content is retained literally. Removing the metadata comment deliberately yields a conventional Markdown page, losing editor-only metadata; keep a file copy first if that metadata matters.

The editable document is the active value model in `EditorSession`, synchronized with native attributed text storage through the coordinator. Ordinary typing captures only the affected block and publishes identity-scoped, versioned snapshots for asynchronous Markdown encoding. Stale revisions and snapshots from another vault/page/session are rejected; explicit save/navigation boundaries flush pending edits. Text storage is its presentation, not a second independent draft or persistence channel. Collapsed descendants stay in the model. Structural commands share `BlockMutation`, and commands register reversible document-and-selection snapshots with the same native undo manager as typing. One text view preserves native cross-block selection and navigation and avoids thousands of focus-owning fields.

Reading preserves native text selection and hyperlink activation. Editing begins explicitly with **Edit**, the **Edit Article** context action or Option-click. Marked-text composition reserves native candidate navigation and commitment keys before structural commands.

Keyboard behavior: Return splits; empty list Return exits; structural Backspace converts to paragraph before merging; Tab/Shift Tab indent/outdent; Shift Return inserts a code newline; Command A selects the current block while editing and the entire document while reading; Command Option A and **Select Entire Document** explicitly select the document. Command Option Up/Down moves a subtree among siblings. Command Shift Return toggles a task. Slash commands and context actions use the same mutations. Content-relative drag handles share the native block layout geometry. Handle interactions preserve the text caret, native drag sessions target sibling reordering, and viewport-edge scrolling and cancellation clear transient drop state. Pointer completion and layout transitions still require device acceptance; see the standing validation gaps. Indent/outdent explicitly changes parentage.

Block selection is a separate set of stable UUIDs. A handle selects a block, Shift extends across adjacent visible blocks, and Command toggles membership without replacing native character selection. Selecting a parent includes its complete subtree; selected descendants of a selected ancestor are deduplicated. Batch copy, move, duplicate, delete and transformations retain document order and use one document transaction for undo. Moves retain identities and parentage; duplication generates fresh UUIDs throughout each copied subtree. Structural kind, semantic designation and status remain separate mutations. Unknown semantic designations and extension metadata survive structural transformations.

See `../validation.md` for reproducible checks and remaining native acceptance work.

## Editorial typography

`EditorTypography` owns document font resolution, semantic roles, paragraph rhythm
and reading measure. `BlockTextStorage` applies those attributes; `ArticleTextView`
uses the resolved native metrics for layout, decoration and hit targets.
`NoemaTypography` owns application controls and metadata. Document preferences do
not restyle navigation, tables, toolbars, source metadata or Quick Look.

The existing `editorFontFamily` and `editorFontSize` keys remain compatible. New
preferences default to 16 pt; existing valid saved sizes remain selected. Finite
sizes clamp to 10–32 pt; missing/nonfinite sizes use 16 pt. An unavailable family
uses the system face while retaining the saved choice. Weight resolution selects
supported medium/semibold faces before the nearest available family member.

| Role | Relative size | Face |
| --- | --- | --- |
| H1 / H2 / H3 | 1.93 / 1.53 / 1.27 | Selected family, semibold |
| Body, lists, quotes, semantic content | 1.00 | Selected family, regular |
| Supporting prose | 0.88 | Selected family, regular |
| Code and raw TeX | 0.88 | Native monospace |
| Semantic labels | 0.88 | Native interface, semibold |
| Rendered math | 1.00 | System serif, italic |

Source H4–H6 decrease monotonically from H3 toward emphasized body. Inline bold,
italic, underline, strike, highlight, code and link semantics survive restyling;
presentation traits never become new serialized content styles.

Body baseline separation targets 1.50 times body size using native font metrics,
with nonnegative leading and no forced clipping. The incoming paragraph owns each
block boundary; continued paragraphs/list text receive no additional block gap.
Parsed Markdown separator blocks retain an empty caret line with zero extra gap.
Their presentation-only separator marker persists when filled, keeping the first
typed glyph on its prior baseline. Newly created empty blocks keep the ordinary
incoming boundary. Neither case removes content or adds serialized fields.
Semantic labels reserve their native ascender/descender plus an optical gap above
the first paragraph only; initial-document reservation accounts for AppKit ignoring
`paragraphSpacingBefore`. Decorations and hit targets follow native baselines.

Reading measure estimates 75 characters from the selected font's native reference
sentence width and caps at 680 pt. The actual editor viewport determines centering,
with compact nonnegative gutters at narrow widths. This approximates a 65–80
character prose target; language, glyphs and enlarged fonts can vary. Page titles,
summary prose, native editors and readable source windows share this measure.

Math previews occupy unused space beside a single unwrapped raw-source line.
Measure the actual rendered expression using the same font and paragraph style as
drawing. Show it only when its full width and height fit within the reserved box;
expanded macros, rendered line breaks and oversized expressions retain raw source
without a cropped preview. The preview cannot extend into adjacent text or blocks.

Readable Markdown, HTML and UTF-8 sources share document roles while preserving
heading, quote, code and link semantics. Original source bytes stay immutable;
Quick Look retains ownership of PDF/media rendering. Preference refresh preserves
text, complete selected ranges, caret, editing mode, native undo/redo and scroll
where layout permits; natural reflow may change a glyph's screen position. A font
refresh neither reloads the draft nor registers a content edit.
