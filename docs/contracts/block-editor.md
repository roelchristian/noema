# Block editor architecture and storage contract

## Storage decision and implementation gate (EDT.BLK01)

**Status: implemented page persistence, durability and interchange (EDT.BLK09–14).**
Markdown format 1 remains supported. Format 2 selects an actor-owned
`SQLiteBlockStore` through repository construction. The page-only implementation
below replaces the earlier proposed combined page/source database contract;
source originals and source metadata retain their existing adapter-owned layout.
The storage review procedure in
[storage-boundary.md](storage-boundary.md#required-author-and-reviewer-disposition)
continues to apply to changed construction and canonical I/O.

### Permanent layer separation

| Layer | Owner and responsibility |
| --- | --- |
| Interactive session | `EditorSession` owns the active value document, vault/page/session identity, revision, selection, changed IDs and mutation history. `BlockEditorCoordinator` bridges native composition, text storage and undo to that session; it does not own a second editable document. The view binds a `BlockDocument` and publishes revisioned `EditorSession.DocumentSnapshot` values. AppModel rejects stale page/vault/session identities, session generations and revisions, then autosaves the captured document through the repository to SQLite without a Markdown/envelope round trip. Save/navigation flush native composition synchronously; ordinary publication yields on the main actor without a timed debounce or codec task. Recovery drafts carry the structured document, while legacy string drafts remain readable. AppKit presentation is never an independent content authority. Invalid or ineffective `BlockMutation` commands leave the complete document unchanged and produce no undo, dirty notification or serialization. |
| Canonical domain document | `BlockDocument`, `EditorBlock`, rich runs and `BlockMutation` stay in `VaultCore`. Ordered children, stable UUIDs, source spellings and metadata are content; caret/layout/undo are session state. Storage must not replace this domain foundation with SQL rows exposed to the editor. |
| Persistence adapter | AppKit-independent [BlockStore](../../Sources/VaultCore/BlockStore.swift) loads a document snapshot and performs create-only or revision-checked save/delete by page UUID. One mode is selected per vault. Revisions are opaque, scoped to vault/page/mode and checked inside the commit window. Asynchronous protocol operations execute on the owning store actor; no transaction across protocol calls is implied. |
| Export | `BlockDocumentCodec` produces readable Markdown and its lossless envelope. Markdown, HTML and other exports are projections of a committed snapshot or an explicitly selected draft. Export never becomes an autosave channel or silently changes vault mode. |

Page title, aliases, timestamps, lock state, classifications and source relationships
remain repository-owned metadata. Saving a document preserves them. Compound metadata/document updates use `SQLiteBlockStore.savePage` in one
transaction; sequential `BlockStore` calls do not establish that guarantee.

### One authority per vault

Format 2 with explicit schema 6 is the only production authority. `blocks.sqlite`
contains pages, blocks, page/source metadata, relationships, knowledge and semantic
records. Identity and required capabilities agree with `vault.json` before admission.
Historical Markdown and schema-1–4 vaults reject without mutation. Missing/damaged
SQLite never falls back to Wiki Markdown. Import/export remains deliberate interchange.

SQLite transactions commit a complete page document and its revision together;
revisions are not exported text hashes. The adapter must retain stable IDs, order,
parentage, inline styles, original Markdown spellings, recovered envelope payloads
and metadata. Page metadata and document properties are compact JSON blobs; blocks retain
parent UUID, sibling order, kind, rich runs, semantic/extension metadata and timestamps
in individual rows. These rows reconstruct the single canonical `BlockDocument`.
Ordinary updates compare rows and write only affected blocks.
Search/embeddings remain derived and rebuildable, distinct from this canonical DB.

### Local-only SQLite and byte ownership

SQLite mode rejects iCloud ubiquity containers, cloud/file-provider roots, network
volumes and locations whose local status cannot be established. Storage selection
must validate the root before opening the DB and revalidate on reopen; a bookmark
or `localOnly` flag alone is insufficient. It must not put SQLite/WAL/SHM into
iCloud Drive, Dropbox or another file synchronizer, and cannot claim synchronization
by copying a live database. Known provider roots and nonlocal/unknown volumes are
rejected; arbitrary third-party synchronization folders cannot be identified from
filesystem attributes alone and must be excluded by the caller. A local save means
local commit, not transport delivery.
Offline closed-vault backup/transfer uses a consistent SQLite backup snapshot and
all owned source blobs, never a database-only copy while WAL may contain commits.

Imported source originals remain immutable checksum-validated blobs at the existing
contained `Sources/<UUID>/` locations, accessed through `VaultContentStore`.
Source metadata, summaries and page-source relationships are SQLite-owned. Receipt-bound
publication, checksum, Trash and bookmark rules remain mandatory. Linked originals
stay externally owned and read-only; unavailable sources retain UUID references.

The canonical SQLite connection belongs to `SQLiteBlockStore`, selected by
`FileVaultRepository` from the admitted manifest, never to editor/AppModel/export code.
`VaultContentStore` continues to own manifest and blob bytes, staging and backup
publication; it cannot emulate SQLite commits by reading/replacing live DB bytes.
DB/WAL/SHM access needs a narrowly owned, reviewed canonical SQLite boundary and
the reviewed guard exception inventory. Existing app-local search/activity SQLite
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

String-backed `BlockKind` preserves unknown kind strings; semantic/status strings
and `BlockMetadata.extra` preserve supported string values. Unknown kinds use a
fallback presentation without discarding their runs, descendants or metadata.
STOR02A adds bounded typed optional JSON and direct unknown-field preservation
at document, block, metadata, run/style and page-metadata scopes, as described
below. Unsupported required semantics still reject writable admission; preserving
a value does not authorize interpreting or editing its required semantics. Current unsupported envelope versions set `unsupportedVersion`,
retain `originalSource`, and block ordinary mutations/import/save; unsupported
SQLite schema versions reject open. No general preservation-only SQLite reader is
implemented.

### Supported document round-trip invariants

`BlockDocument` remains the AppKit-independent content value, reconstructed from
one authority. For valid supported values, `SQLiteBlockStore.save` followed by
`load` must equal the input document, including:

- Every block UUID, kind string, ordered parent/child tree and rich run sequence;
  each run's exact text and supported inline style/link/math properties.
- Entire `BlockMetadata`: semantic/status, checked/collapsed, language/icon and
  `extra` string map; created/modified timestamps and original Markdown spelling,
  signature, indentation and depth.
- Document properties: trailing newline, recovered metadata, unsupported-version
  state and original source, when present and valid for the selected operation.
  Writable saves reject `unsupportedVersion` rather than clearing it.

`pages.properties` encodes the document with `blocks = []`; the `blocks` rows
alone own its tree. `semantic` is the full metadata JSON blob, not only a semantic
label; `extensions` stores the four original-spelling fields. This division is
not two complete authoritative documents. Future opaque payloads must use the
same per-document/per-row ownership and incremental changed-row comparison.
Repository `savePage` publishes page metadata and document together. Plain
`BlockStore.save` preserves existing page metadata; it does not invent it.
Repository `loadPage` creates portable body text from the snapshot, clears the
supported document's import-only `originalSource` in that projection, and exposes
the opaque revision as content-hash evidence. Therefore portable `NoteRecord`
body equality is distinct from exact `BlockStore` document equality.

A supported Noema envelope has version 1, a checksum of readable Markdown and a
valid nonempty tree of unique block IDs. `decode(encode(document))` preserves
supported content; encoding clears import-only `originalSource` once an envelope
is required. Untouched plain imports retain their original bytes when their
source signatures and spelling still match. A supported Noema page export/import
preserves page and block identities, known metadata and recovered payloads through
`NoteCodec` plus this envelope. Readable export intentionally loses identities and
editor metadata and must report its warning. A checksum mismatch gives edited
readable text precedence and retains the stale encoded payload for recovery; it
cannot promise prior block identity retention for text reparsed without a valid
envelope. Unsupported required metadata must not be promoted to an editable save.

`EditorSession` carries one mutable document, selection and local mutation
revision; its identity and reload generation scope asynchronous snapshots.
Only the current unpublished revision is accepted. This local counter is **not**
a `BlockStoreRevision`; the repository/save path retains captured canonical
concurrency evidence. Native undo restores content/selection at a new local
revision. Effective structural mutations clear import-only source state; invalid
or no-op commands preserve the complete value and create no dirty change.
Movement/reparenting keeps UUIDs; duplicate creates fresh subtree UUIDs. Splitting
keeps the original block ID on the prefix and allocates the suffix ID; merging
into a previous paragraph keeps that survivor's ID and moves descendants.
STOR02A exact text-edit and annotated split paths enforce grapheme boundaries;
general native editing still needs KNOW03 compound annotation/session integration.

Existing evidence is in [BlockDocumentTests](../../Tests/VaultCoreTests/BlockDocumentTests.swift),
[EditorSessionTests](../../Tests/VaultCoreTests/EditorSessionTests.swift),
[SQLiteBlockStoreTests](../../Tests/VaultCoreTests/SQLiteBlockStoreTests.swift) and
[SQLiteRepositoryTests](../../Tests/VaultCoreTests/SQLiteRepositoryTests.swift).
STOR02A preservation coverage additionally lives in `PersistencePayloadTests`,
`NoteRecordPersistenceTests` and `AnnotationPersistenceTests`; unknown required
semantics and unsupported wrappers remain nonwritable.

### Future payload compatibility gate (STOR.02)

Before new writable payloads ship, define a versioned JSON extension object at
each owning document, block, run/style and page-metadata scope. Known fields have
one typed authority; unrecognized optional extension keys retain their JSON values
opaquely in that scope, including objects/arrays, without promotion to known
fields. Re-encoding may canonicalize JSON spelling but must preserve values and
identity associations. Enforce documented payload size/depth limits on admission;
excess or malformed content rejects writable open and retains original bytes.
Do not truncate an extension to satisfy a limit.

A payload version and required-feature list must distinguish optional preserved
data from semantics required to edit safely. Unknown required features,
unsupported writable payload/database versions, and unpreservable unknown fields
reject writes before mutation/publication. Supported optional extensions survive
unchanged load/save/export/import, including edits to other known fields and
incremental updates; collisions with known fields reject rather than overwrite.
A preservation-only read exposes original bytes plus an explicit nonwritable
capability. Decoding successfully, rendering a fallback or retaining a recovery
copy never grants save authority. Older clients must be excluded by the durable
manifest/schema capability gate before they can destructively rewrite newer
payloads. No duplicate serialized block-content store is added for this purpose.

### Persistence extension foundation (STOR02A)

`PersistencePayload` carries version 1, required features and typed optional JSON
properties at document, block, metadata, run/style and page-metadata scopes.
Unrecognized direct fields also round-trip at these scopes. Admission bounds each
optional scope to 256 KiB and nesting depth 32; collisions and unknown required
features reject. Schema 2 rejects new versioned extension writes; explicit schema 3
validates supported block kinds and payload semantics before publication. Unknown
kinds remain preservation values and cannot obtain schema-3 write authority.

`TypedEntityReference` identifies origin/target by typed UUID. Document extension
annotations use stable IDs and version-1 UTF-16 half-open grapheme-boundary targets,
quoted text, context and revision digest. Bare replacements conservatively retain
anchors as stale, missing blocks as deleted; exact unchanged text retains anchors.
This foundation has no annotation UI or canonical knowledge target resolver.
`BlockDocument.replaceText` and `BlockMutation` already transform exact edits,
split/merge and duplicates with preservation evidence. KNOW03 must connect those
algorithms to independent semantic records and transactional editor persistence;
callers retain unresolved records. The transformation rules below remain binding.

### Deferred inline annotation contract

The [canonical knowledge contract](knowledge-model.md) adds independent entity
and semantic-object targets, whole-block/entity/object locations and schema-5
relational annotation authority. It supersedes the earlier proposed extension-only
record layout after an explicit identity-preserving transfer. Existing schema-3
extension records retain their meaning; offsets, dispositions and transformation
rules below remain binding.

Annotations are semantic records separate from formatting runs. Splitting/coalescing
runs for style changes must not create, destroy or rename an annotation. The minimal
future versioned document extension contains records with `id` (annotation UUID),
`pageID`, `blockID`, typed designation string, optional stable `targetEntityID`,
opaque optional payload, created/modified metadata, expected canonical page revision
and a target object. No annotation table or tagging UI is introduced by STOR.01.
A future relational mapping must preserve these identities and targeting semantics
without cascading away unresolved preservation records.

Target version 1 addresses a single block's concatenated run text with a UTF-16
half-open range, start/end insertion affinity, exact quoted text, bounded surrounding
context and a digest of the exact referenced text/revision. Persist an explicit
`resolved`, `stale` or `deleted` disposition. Identity persists when position changes.
Offsets must be in bounds and on extended-grapheme boundaries; reject boundaries
inside a surrogate pair, combining sequence or emoji sequence. Preserve original
Unicode sequences; no implicit NFC/NFD normalization is allowed. An explicit
normalization operation must transform anchors in the same document mutation or
mark them stale. Reattachment based only on matching words or approximate offsets
is prohibited; ambiguity requires explicit user disposition.

Overlaps are allowed as independent records, including identical ranges and
crossing ranges; designation rules may reject a prohibited combination explicitly.
They neither alter rich-run style authority nor imply a semantic priority. Initial
range affinity excludes text inserted exactly at either edge (start moves after
insertion, end stays before it). Edits strictly before the range shift it by their
UTF-16 delta; edits after it preserve it. Interior insertions extend it only when
recorded by the same revision-checked edit transformation. A replacement/deletion
intersecting its original selected text marks it stale unless an explicit semantic
operation supplies a verified replacement target. A bare whole-block replacement
cannot infer survival from similar text.

| Mutation | Required future annotation disposition |
| --- | --- |
| Sibling move, indent/outdent, kind/style change | Keep annotation/page/block identity and range when exact text is unchanged. |
| Split | Keep annotation ID and map to prefix/suffix owner and offset when wholly contained; a range crossing the split becomes stale with preserved original target until an explicit versioned multi-span operation resolves it. |
| Merge | Keep annotation IDs; anchors from the removed block map to the survivor with the exact pre-merge UTF-16 prefix offset and updated revision. Any ambiguous target remains stale. |
| Duplicate subtree/page | Allocate fresh annotation and copied block/page IDs; keep optional entity targets only where the designation permits it, and retain provenance to the originals. |
| Delete block/page | Retain annotation identity and original target as deleted preservation metadata; do not attach it to a replacement block or discard it through a foreign-key cascade. Undo restores the matching identity/target. |

Document text/structure and annotation transformations publish in one page transaction
under expected canonical revision and current session authority. Undo/redo restores
both in the same session mutation. Updating position requires new consistency evidence;
a revision mismatch preserves the old record and rejects publication. A stale anchor
is visible preservation state, never a silently resolved reference.

STOR.02 / P0 must implement payload/capability gates before expanded authority; its
P1 integration must preserve the existing editor/repository seam and compound page
revision semantics. STOR.03 / P0 must exercise existing v1/v2 compatibility and
Noema archive restoration with unknown optional/required payloads and stable IDs;
P1 adds adversarial interruption and stale-anchor acceptance. Annotation consumers
and their storage schema remain deferred until a separately reviewed feature.

### Breaking production cutover

STOR02B–STOR03 retires historical format conversion and upgrades. Unsupported vaults
are preserved and rejected. New production vaults initialize schema 6 directly;
archive restoration validates the same schema and never merges occupied identities.

## Explicit Markdown interchange (EDT.BLK13)

`FileVaultRepository.exportMarkdown` and `exportVaultMarkdown` export committed
live pages. Noema exports contain frontmatter and a versioned document envelope,
including for originally plain Markdown, preserving page/block IDs, semantics,
unknown frontmatter and recovered metadata. Readable exports omit that envelope
and frontmatter and always report a loss warning. Unsupported source spelling
remains available in the document model and lossless envelope.

`importMarkdown` is an explicit operation. Create-only import retains recognised
identities and rejects occupied page IDs/titles. Replacement requires a captured
canonical `NoteRecord` revision, rejects mismatched declared identities and locked
pages, and uses the ordinary repository conflict check. Externally edited readable
text invalidates its old envelope checksum; the explicit import retains that stale
payload for recovery while importing the changed text. SQLite mode never observes
an exported Wiki file as a second content authority.

Whole-vault Markdown export is a live-page interchange bundle; sources, trash,
recovery drafts and manifest policy require a complete backup. SQLite page export
reads one database snapshot. Markdown mode retains its existing per-file
coordination and has no cross-file transaction. A quiescent whole-vault packaging
and restore workflow remains acceptance work; a database snapshot alone is not a
whole-vault backup. Multi-device database replication is deferred.

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

For explicit Markdown interchange, exported pages contain frontmatter plus Markdown. On an editor mutation, the body gains a trailing HTML comment (`noema:document`) containing base64-encoded JSON. The envelope has its own version (1), a SHA-256 of the readable Markdown, and a complete block tree: stable UUIDs, string-backed structure kinds, rich runs, independent semantic designation, optional status/language/icon/extension metadata, timestamps, and children. Array order is position. No sidecar or index becomes canonical, and coordinated writes/conflicts/recovery operate on the complete body atomically.

Opening plain Markdown does not rewrite it. Untouched imported block spellings survive saves, including unsupported tables, HTML, and images. Legacy `noema:block` markers import their IDs/tags. Changed blocks produce readable Markdown plus the lossless JSON envelope. Standard Markdown readers ignore the comment and retain a useful textual document, though callout/toggle semantics, underline/highlight, and statuses require noema for full presentation. Returning to the previous application is possible by retaining the file and editing the readable body; old versions do not understand the new metadata.

On reload, metadata is used only when its checksum matches the readable body and UUIDs are unique. An external Markdown edit wins over stale metadata; the old encoded payload is retained as `recoveredMetadata` in subsequent saves, so its formatting/tree can be recovered rather than silently overwriting the external edit. A recognized future envelope version opens read-only. Malformed/unrecognized content is retained literally. Removing the metadata comment deliberately yields a conventional Markdown page, losing editor-only metadata; keep a file copy first if that metadata matters.

The editable document is the active value model in `EditorSession`, synchronized with native attributed text storage through the coordinator. Ordinary typing captures only the affected block and publishes identity-scoped, versioned snapshots for asynchronous Markdown encoding. Stale revisions and snapshots from another vault/page/session are rejected; explicit save/navigation boundaries flush pending edits. Text storage is its presentation, not a second independent draft or persistence channel. Collapsed descendants stay in the model. Structural commands share `BlockMutation`, and commands register reversible document-and-selection snapshots with the same native undo manager as typing. One text view preserves native cross-block selection and navigation and avoids thousands of focus-owning fields.

Sidebar and quick-open navigation synchronously flush native publication and capture an
immutable page UUID, canonical revision, editor revision, metadata and semantic draft
before presenting the destination. AppModel serializes background saves through the
admitted repository and app-local RecoveryStore. Rapid revisits restore pending drafts;
only an acknowledged predecessor from the same captured base can advance their revision.
External revisions still conflict. Failures remain associated with the originating page
and recovery entry. Lock, close and vault switching drain queued work; failed in-memory
drafts must be recovered, explicitly discarded or journaled before forced close.
Page editing-lock metadata writes reconcile canonical document and annotation evidence
without creating a new editor mutation. See the optimistic navigation and page editing
lock workflow tests in `Tests/NoemaEditorTests`.

Unlocked writable pages are continuously editable after their identity-matched semantic
session establishes revision authority. `AppModel.canEditPage` admits native editing and
formatting; unavailable vaults, lifecycle/modal restrictions, locked pages, unsupported
documents and unready semantic sessions remain non-editable. Sources stay read-only.
There is no Edit/Done transition or Option-click editing gesture. Ordinary clicks place
the caret and preserve native selection; Command-click and the accessible **Open Link**
context action follow wiki, block and external links. Internal block links use the same
optimistic navigation capture as sidebar selection. Opening a page does not take focus
from navigation controls. Save acknowledgements retain the active selection and undo.
Escape dismisses transient slash/wiki suggestions without finishing editing, saving or
clearing selection. Marked-text composition reserves native candidate navigation and
commitment keys before structural commands. Clicking outside does not end editing.

Keyboard behavior: Return splits; empty list Return exits; structural Backspace converts to paragraph before merging; Tab/Shift Tab indent/outdent; Shift Return inserts a code newline; Command A selects the current block in editable pages and the entire document in read-only text; Command Option A and **Select Entire Document** explicitly select the document. Command Option Up/Down moves a subtree among siblings. Command Shift Return toggles a task. Slash commands and context actions use the same mutations. Content-relative drag handles share the native block layout geometry. Handle interactions preserve the text caret, native drag sessions target sibling reordering, and viewport-edge scrolling and cancellation clear transient drop state. Pointer completion and layout transitions still require device acceptance; see the standing validation gaps. Indent/outdent explicitly changes parentage.

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
text, complete selected ranges, caret, editability, native undo/redo and scroll
where layout permits; natural reflow may change a glyph's screen position. A font
refresh neither reloads the draft nor registers a content edit.
