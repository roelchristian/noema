# Canonical storage boundary contract

Canonical persistence supports format 2 with matching schema-6, schema-7, schema-8 or schema-9 declarations. This is
an intentional breaking cutover for development vaults. Format 1 and SQL schemas
1–5 are unsupported production formats and opening never upgrades or converts them.
Markdown is deliberate import/export only; Wiki files and source metadata JSON are
never independently writable authorities. Historical inventories remain in Git.

Manifest inspection reads through the selected store. Only a provider-confirmed
missing manifest in a positively empty root permits explicit async initialization.
Unavailable metadata, denied access, damaged manifests and nonempty roots never
authorize replacement identity. Unsupported declarations reject without canonical
mutation; unknown optional manifest JSON survives known-field edits.

`VaultStorageProvider` constructs the selected byte store and sole canonical
`SQLiteBlockStore`. Production construction captures an admitted session lease and
gate. Manifest UUID, database `vault_state`, the declared user_version and required
capabilities (`canonicalKnowledgeV1`, `canonicalMetadataV1`, `semanticAnnotationsV1`,
`organisationV1`) must agree before writable admission. Neither file changes authority independently.

Fresh creation uses an owned empty sibling staging root, direct schema-9 DDL in
one transaction, integrity/capability validation, checkpoint and close, then synced
manifest publication and a create-only same-parent directory move. Collisions never
merge or overwrite. Failed nonempty/unreadable staging remains preservation data;
only positively empty owned staging is disposable. SQLite locality validation is
owned by `SQLiteVaultLocality` and applies to staging, archive, restore and admission.

| Information | Canonical owner |
| --- | --- |
| Pages, blocks, metadata and page Trash | SQLiteBlockStore |
| Source metadata, page-source relationships, source Trash, tombstones and conflicts | SQLiteBlockStore |
| Entities, aliases, directed relationships, questions, definitions and annotations | SQLiteBlockStore |
| Favourites, collections, folders and membership | SQLiteBlockStore, as rows in the vault's `blocks.sqlite` |
| Imported immutable originals and in-vault preservation material | Controlled VaultContentStore bytes with checksum/size receipts |
| Linked external originals | External owner; read-only |
| Recovery drafts | App-local RecoveryStore until committed or explicitly discarded |
| Search/FTS | Rebuildable app-local projection |
| AI activity history | Existing app-local metadata history |
| AI processing work ledger | Rebuildable app-local technical scheduling metadata; never publication authority |

All controlled byte reads, writes, snapshots, directory creation, moves and deletes
use `VaultContentStore`. SQL, statements and transactions remain actor-owned;
metadata and document changes publish in one revision-checked transaction. Original
bytes publish with durable vault/source/operation-bound receipts validated again at
execution and COMMIT. There is no second SQL actor, metadata JSON catalogue or
serialized authoritative duplicate of the block tree.

### Page and block relational invariants

Source of truth is [SQLiteBlockStore](../../Sources/VaultCore/SQLiteBlockStore.swift).
The schema below describes persisted columns, not a new SQL API for consumers.

| Table / column | Representation and invariant |
| --- | --- |
| `pages.id` | `TEXT PRIMARY KEY`; page UUID validated by loading/domain paths |
| `pages.revision` | Non-null `BLOB`; opaque store-issued UUID-string bytes, not a timestamp, Markdown hash or monotonic counter |
| `pages.metadata` | Nullable `BLOB`, JSON `NoteRecord`; `savePage` stores empty `body` and `contentHash`, reconstructing them from document/revision on load. A raw `BlockStore.save` can create a page without repository metadata |
| `pages.properties` | Non-null `BLOB`, JSON `BlockDocument` with `blocks=[]`; retains document properties, recovered metadata, unsupported-version flag and original-source spelling |
| `pages.trashed` | Non-null integer default 0, `CHECK(trashed IN (0,1))` |
| `pages.trashed_at` | Nullable `REAL`, Unix seconds; NULL means absent/untrustworthy removal date. Trash changes issue a new page revision and retention identity; restore clears the date |
| `blocks.page_id`, `blocks.id` | Non-null UUID `TEXT`, composite primary key `(page_id,id)`; page FK to `pages(id) ON DELETE CASCADE` |
| `blocks.parent_id` | Nullable UUID `TEXT`; composite same-page FK `(page_id,parent_id)` to `blocks(page_id,id) DEFERRABLE INITIALLY DEFERRED`; NULL is a root block |
| `blocks.sibling_order` | Non-null integer with `CHECK(sibling_order>=0)`; array index within parent; index `block_parent_order(page_id,parent_id,sibling_order)` is an accelerator, not a uniqueness constraint |
| `blocks.kind` | Non-null `TEXT`, string-backed `BlockKind` |
| `blocks.runs`, `blocks.semantic` | Non-null JSON `BLOB`s for `[RichRun]` and `BlockMetadata`; semantic/status/checked/collapsed/language/icon and string-valued `extra` are content |
| `blocks.created_at`, `blocks.modified_at` | Non-null `REAL`, Foundation reference-date seconds, distinct from Unix `trashed_at` |
| `blocks.extensions` | Non-null JSON `BLOB` for original Markdown/signature/indentation/depth; this is a fixed Codable payload, not arbitrary unknown JSON preservation |

Direct supported-schema initialization preserves these page/block definitions with nullable
trashed_at present from the beginning. Missing/unversioned/future/older production
databases reject before WAL or schema mutation. Read reconstruction validates
contiguous sibling order, reachable acyclic parentage, unique block UUIDs and valid
documents; metadata UUID must match its owning page. SQL foreign keys alone are
insufficient. Internal disposable staging constructors remain isolated test tools.

`properties.blocks=[]` and relational rows avoid a second authoritative serialized
block tree. Original-source/recovered spellings are preservation information and do
not override the current rich runs. Incremental persistence deletes removed rows and
upserts changed rows; unchanged rows survive. Metadata and document publication use
`savePage` in one revision-checked transaction. Read transactions return coherent
metadata/document/revision even when another connection commits concurrently.
See [SQLiteBlockStoreTests](../../Tests/VaultCoreTests/SQLiteBlockStoreTests.swift)
for affected-row, rollback, coherent-snapshot, corruption, upgrade, cancellation and
WAL-backup scenarios; these tests do not establish arbitrary power-loss behavior.

### Canonical source publication

Source metadata and ordered relationships, logical source Trash, tombstones and
inline conflicts are SQLite-owned. Obsolete metadata JSON cannot override rows.
Imported originals remain controlled immutable bytes; linked originals remain
externally owned and read-only. Source publication uses adapter-minted receipts,
F_FULLFSYNC for regular payloads and directory fsync, retained Source Publications
evidence, and checksum/size revalidation at execution and COMMIT. Unknown sync
providers fail closed. Physical originals remain retained after logical purge;
live relationships restrict purge. Imported descriptors cannot change under an
existing UUID. Conflict disposition checks conflict/target revisions atomically
and never discards unique preserved payload implicitly.

Pending downloads have no canonical row or managed original. Completion must match
the prepared logical file URL and import/link ownership. Download cancellation revokes its
single-completion authority, rechecked around receipt verification and before SQL
COMMIT; a rejected commit retains any already published original and receipt.
URL availability checks never replace captured bytes. Interrupted-import cleanup removes only an exactly
snapshotted empty directory; nonempty or unexpected staging reports a preservation
error through quiescence. Failed publication retains unreferenced originals and
receipts for recovery.

Source listing enumerates canonical SQLite identities. Metadata-only discovery
checks imported change tokens without reading original bodies; linked originals
remain uncached and are read only by content consumers. Full scans retain the
session cache for unchanged imported originals and supply transient original-byte
fingerprints to reader reconciliation, including binary linked originals. Refresh
closes removed, unavailable or changed previews without extra original reads;
explicitly reopening a preview revalidates its original before reusing the window.
Preview snapshots remain disposable, separately owned copies rather than authority.

Manual source metadata changes compare the supplied metadata with the current
canonical row and commit against its captured source revision. Explicit and
automatic AI publication use a `SourceSummarySnapshot` with its original bytes,
change token and canonical revision; a metadata change and reversal still rejects
the older result. Automatic source processing publishes title, summary and any
previously unset LCC together, with on-device provenance, while retaining existing
classification. Provider preference changes never regenerate stored artifacts.

Manifest requires explicit supported schemaVersion=6, 7, 8 or 9, blocks.sqlite, localOnly=true and the
complete capability set. Missing, contradictory, malformed or unknown required
features and UUID disagreement reject before writable access. Preservation
inspection never authorizes saving or reimporting Markdown over canonical records.

### Canonical logical records and preservation invariants

Schema 5 retains the page/block columns and revision semantics above and implements
the following logical records. Exact persisted DDL is authoritative in
`SQLiteBlockStore`.
Use versioned authoritative payloads plus explicit relational metadata, with no
second authoritative copy of fields promoted to relationships or lifecycle columns.

| Record | Required keys, authority and integrity |
| --- | --- |
| `vault_state` | Singleton; vault UUID, `canonicalMetadataV1`, supported payload versions, opaque vault-metadata revision and bounded optional extension payload; UUID/capability agree with manifest |
| `sources` | Stable source UUID PK; opaque revision; versioned metadata payload excluding relational/lifecycle fields; imported, linked or unavailable identity-only ownership kind (original metadata must establish imported/linked ownership); optional controlled blob path/checksum/size or linked bookmark/reference; active/trashed state and nullable removal date. Imported bytes must match checksum/size before references publish; linked bytes remain externally owned |
| `page_sources` | Composite PK `(page_id,source_id)` and FKs to pages/sources; an explicit contiguous order preserves the supported source UUID sequence during migration and `NoteRecord` reconstruction. This becomes the sole source-link authority; `NoteRecord.sourceIDs` is reconstructed, not independently written |
| `tombstones` | Stable entity UUID plus typed kind PK; last revision, deletion time and disposition. Logical deletion preserves page/source rows and references; purge writes the tombstone and removes or dispositions relationships in the same transaction. IDs are never reused |
| `conflicts` | Stable conflict UUID PK; typed target UUID, captured/base revision, versioned preserved payload or checksum-verified controlled payload reference, creation time, disposition and opaque record revision. Disposition never deletes unique bytes implicitly; a target may be tombstoned |

Keep page Trash authority in `pages.trashed/trashed_at`; source Trash is in `sources`.
Do not add a competing generic Trash copy. Source FK deletion is RESTRICT until the
compound operation handles links; page-link deletion may CASCADE on an authorized
page purge. Logical Trash retains links, content and unavailable-source identity.
Unavailable source identities carry no invented blob/checksum/bookmark; preserve
order and missing/tombstoned state.
New live relationship targets must exist; preserved conflict/tombstone target IDs may refer to removed
entities and must be validated by typed disposition rules rather than a misleading
unconditional live-row FK. Retention grace dates migrate without inventing a deletion
time. Unsupported file-only Trash never authorizes a canonical import or overwrite.

Semantic designations/status/provenance remain block/source payload content.
STOR.01 deferred the entity catalogue; [KNOW01](knowledge-model.md) now specifies
its distinct schema-4 foundation and supersedes that deferral only for the approved
Person, Place, Concept, Event, Question and Definition domain scope. No runtime schema
change, ontology, canonical FTS, embeddings or inference is authorized by KNOW01.
STOR02A preserves bounded optional JSON in supported domain scopes and rejects
unknown SQL wrapper keys and unsupported required features. String-valued `extra`
and string-backed kinds alone are insufficient preservation guarantees.

### Knowledge ownership and independent acceptance (KNOW01)

The [knowledge contract](knowledge-model.md) and [decision](../decisions/0002-canonical-knowledge-model.md)
define the implemented canonical schema-5 domain. Schema declarations and database
capabilities negotiate together and reject older writers before mutation. No
historical schema 1–5 conversion or downgrade facility is supported. ENT.01 adds only an explicit 6→7 upgrade, described in the [knowledge contract](knowledge-model.md#typed-entity-properties-ent01).

`VaultStorageProvider` still selects and constructs the sole `SQLiteBlockStore`.
Entity/type/alias/relation, semantic-object and annotation records belong to that
actor's connection and transactions, including explicitly approved internal helpers.
Domain protocols expose typed snapshots/errors; UI/editor consumers do not own SQL
connections, schemas or an independently writable JSON catalogue. Block text remains
in its existing canonical rows; quotes/context are bounded verification evidence.
Canonical byte publication and backup use the selected `VaultContentStore` boundary.

Author and independent reviewer must separately record the following disposition
when KNOW02/03 change runtime storage. Trace public APIs to actor, admitted root,
lease validation, expected record/collection/page revisions and pre-COMMIT checks;
inspect all helper/caller routing and SQL ownership even if the scanner passes.
Review manifest/database capability agreement, forward migration, unknown payload
preservation and tombstone handling; name tests and unresolved limitations in the
PR. KNOW01 changes specification only: runtime storage/I/O disposition is N/A,
with an independent architectural approval required before implementation.

| Gate | Focused acceptance required of the owning implementation |
| --- | --- |
| KNOW02 identity/registry | Create independent Person/Place/Concept records; equal labels and aliases remain disambiguated UUIDs; rename retains links; register a future type without reshaping identity storage; unknown required versions/features reject writes. |
| KNOW02 atomicity/lifecycle | Reopen exact supported properties/unknown optional JSON; stale entity and vault-collection revisions, lease loss and injected precommit failure publish nothing; tombstoning preserves occurrences and relation endpoints; restore retains UUID. |
| KNOW02 admission | Only matching schema 6/7/8/9 production authority is admitted; mismatch/unsupported capabilities and historical schemas reject before writable access without changing existing bytes. |
| KNOW03 authority transfer | Migrate existing extension annotations once, preserving UUIDs, opaque fields and stale/deleted state; unresolvable legacy targets remain explicit preservation data; no entity/object is invented from semantic labels, titles or matching text; no second annotation authority. |
| KNOW03 overlapping/reference states | Independent whole-block, identical, crossing and nested inline annotations coexist; deleting a Question annotation never deletes Person/Place records; anchor resolution and target tombstone/unresolved state are independently queryable. |
| KNOW03 editing/publication | Verify UTF-16/grapheme boundaries for surrogate pairs, combining marks and joined emoji; exercise edge affinity, split/merge, move/style, replacement, delete, undo/redo and duplication; failed compound edits leave content/anchors at one revision. |
| KNOW03 import/query/preservation | Reopen the Napoleonic Wars scenario; rename retains occurrences; duplicate content/annotations receive new identities with permitted canonical targets; collisions never overwrite identities; explicit relationships stay distinguishable from derived co-occurrence; purge never cascades unique preservation data. |

### Implemented semantic ownership and review handoff (KNOW03)

Fresh production staging uses schema 9; admission requires matching supported manifest/database agreement on
`canonicalKnowledgeV1`, `canonicalMetadataV1`, `semanticAnnotationsV1` and `organisationV1`.
`VaultStorageProvider` selects the admitted root and lease; `SQLiteBlockStore`
continues to own the sole canonical connection, statements and transactions.
Unknown schema/capability declarations reject before connection construction;
unsupported required registry descriptors, including nested metadata payloads,
reject before writable schema preparation. All production creation initializes schema 9 directly; historical schemas reject
without conversion.

| Semantic record | Authoritative owner and preservation |
| --- | --- |
| `semantic_object_types` | Actor-owned versioned Question/Definition registry; bounded optional descriptor JSON is retained and unknown required metadata denies admission. |
| `semantic_objects`, `semantic_object_entities` | Independent object UUID/revision/lifecycle and designated entity links; entity identities are retained across content duplication. |
| `semantic_annotations` | Independent annotation UUID/revision, typed location/referent, captured page/block identity and bounded payload; live same-page/block FKs are cleared for stale/deleted anchors while captured evidence survives. |

Compound semantic page writes compare page, annotation, affected object, referent
entity and vault revisions in one transaction. Entity/object annotation writes
also compare owner/referent revisions. Plain saves and Trash/restore rebase
resolved annotation evidence with the page revision; annotated page purge rejects
without independent preservation. Public queries are bounded, while integrity and
preservation scans cover the complete annotation authority. Document annotation
extensions are projections of canonical rows after persistence, not a second
writable catalogue. Exact structural edits and duplication preserve independent
object/annotation identities and keep unresolved/tombstoned referents explicit.

Independent KNOW03 review accepts these storage routes, revision checks, payload
admission and preservation rules for the implemented fresh schema-5 scope; no new
I/O exception or byte owner is authorized. See
[semantic boundary tests](../../Tests/VaultCoreTests/SemanticBoundaryTests.swift),
[lifecycle tests](../../Tests/VaultCoreTests/SemanticLifecycleTests.swift) and
[admission tests](../../Tests/VaultCoreTests/SemanticAdmissionTests.swift).
Future changes must repeat the separate author/reviewer procedure above, tracing
public APIs through lease/root checks and pre-COMMIT validation. Automatic
historical schema conversion is retired. Production creation is schema 9; archive,
device and crash-durability acceptance requires its own named tests and review.

Favourites, collections and folders are vault-owned rows in `blocks.sqlite`:
`organisation_containers`, `organisation_memberships` and `organisation_favourites`.
They are not a sidecar database, a filesystem directory or a knowledge-entity type.
Schema 6 fresh DDL creates them in the same transaction as the semantic tables.
Opening schema 5 does not create them and does not change `user_version`.
A container describes where an item is presented. Deleting one removes memberships
only. Page and source purge removes that item's organisational references in the
same transaction. Trashed items remain members and stay out of the listed snapshot
until restore. Archive and restore open the schema declared by that vault's manifest.

These are implementation gates, not evidence that KNOW01 executed runtime tests.
Device/accessibility and filesystem/process/power-loss acceptance remain standing
gaps; in-process tests are not evidence of actual power-loss durability. Knowledge backup/archive and future
encryption must include canonical records, unknown payloads and preserved unresolved
references; a database-only snapshot is not a complete vault archive.

### Domain APIs and commit outcomes (STOR.02 handoff)

`VaultRepository` / `FileVaultRepository` retain domain semantics, identity, conflict
policy and format coordination. `BlockStore` retains opaque snapshots and
create-only/expected-revision writes. `SQLiteBlockStore` owns connections, SQL and
transactions; consumers and `EditorSession` must never depend on table layouts.
The editor owns the mutable document, selection, undo, dirty state and captured
revision. Leases, lock admission, quiescence, stale completion and recovery remain
the existing session infrastructure.

Extend `VaultStorageProvider` with policy-selected SQLite construction bound to the
validated root/manifest/gate/lease, including explicit staging context; route repository
and explicit staging construction through that policy. Do not introduce a second storage
selector or general-purpose database abstraction. Byte-store selection remains
separate from actor-owned SQL writes; ordinary adapter replacement never writes a live DB.

Only three narrow compound persistence contracts are currently justified. Names are
provisional; STOR.02 must settle typed Swift signatures and errors before implementation:

| Proposed operation | Inputs and revision conditions | Publication/result |
| --- | --- | --- |
| `publishSourceAndPage` | Source create-only or expected source revision, verified immutable-blob receipt (or linked reference), optional page create-only/expected page revision, document and relationship set, operation UUID, current publication validation | One SQL transaction publishes source metadata, optional page/document and links; returns committed source/page snapshots and operation UUID |
| `transitionTrash` | Typed page/source identity, expected entity revision and expected affected relationship revisions, trash/restore/purge disposition and preservation receipt if needed | One SQL transaction publishes state/retention/tombstone/link changes; returns committed revisions. Physical byte cleanup follows only authorized durable disposition |
| `disposeConflict` | Conflict UUID/expected conflict revision, chosen disposition, expected target revision when publishing content, preserved payload receipt | One SQL transaction publishes target plus conflict disposition; returns committed target/conflict evidence and keeps unselected unique content recoverable |

Page-source mutations advance and compare the owning page revision; source changes
compare source revisions. Collection membership changes also compare/advance the
vault-state revision, so migration/archive captures can detect insertions and purges.
An expected relationship revision means its owning page revision, not a separate
independently writable relationship token.

Every compound operation validates revisions and the live session publication
predicate inside the actor transaction and again before COMMIT. Stale revision,
duplicate identity, unsupported capability/payload, missing/corrupt blob, lost lease,
SQL failure or precommit cancellation yields no metadata/document publication.
A successful COMMIT is the durable success boundary. Cancellation arriving afterward
must return or allow lookup of committed outcome by operation UUID; it must not
report a rollback or retry as a new create. An uncertain return preserves the draft
and reconciles against committed revision/operation evidence. The existing store
returns after COMMIT without a postcommit cancellation check; new compound APIs must
keep that distinction. Checkpoint failure aborts lock; retirement follows successful
quiescence. Never manually unlink active WAL/SHM.

### Source bytes, interruption and cleanup

Existing `stageSource` writes original plus metadata into `Sources/.import-<UUID>/`
and conditionally moves the complete directory; failures preserve staging. It does
not transact with SQLite or establish file/directory power-loss synchronization.
The expanded-authority import protocol must add recoverable publication:

1. Stage under an operation-owned UUID location through the selected byte store;
   record ownership, source identity and intended destination without persisting a session-access lease.
2. Validate regular-file containment/no symlinks, exact bytes, size, checksum and
   metadata identity; linked originals require scoped read evidence, never copying authority.
3. Flush staged payloads with an appropriate file synchronization primitive, publish
   create-only immutable bytes, and synchronize affected parent directory entries.
   STOR.02 must document supported filesystem/OS durability assumptions and test
   injected flush/rename failure; atomic rename alone is insufficient evidence.
4. Commit source/page/link metadata using the verified receipt and captured revisions.
   A reference must never acknowledge bytes whose durable publication is unproven.
5. Reconcile interruption: prepublication staging, published-but-unreferenced bytes
   and ambiguous receipts are retained preservation data. Committed references must
   be reverified; missing/corrupt bytes surface a repair issue without erasing identity.
6. Cleanup requires explicit authorization, exact owned snapshot, proven obsolete
   disposition and no live/conflict/Trash/draft reference. A prefix, age or orphan
   label alone never proves unique content disposable. Failed cleanup retains evidence.

Logical deletion commits recoverable lifecycle state before physical deletion. An
imported original is never removed while it is the only recoverable referenced copy;
linked external originals are never deleted. Conflicts, damaged drafts and interrupted or ambiguous staging retain their
existing preservation classification.

### Native archive contract (version 1)

Keep [MarkdownInteroperability](../../Sources/VaultCore/MarkdownInteroperability.swift)
for Noema/readable export and explicit create-only or revision-checked import. A live
page Markdown bundle and a SQLite backup snapshot each omit parts of the vault.
A complete archive is a separate versioned package with an independently readable
integrity manifest, vault UUID, manifest authority/capabilities, SQL/payload versions,
all active and trashed pages/blocks, source metadata and included owned originals,
page-source relationships, tombstones, conflict payloads/disposition, required
semantic metadata and provenance. Inventory every entry with relative path, type,
byte length and checksum; forbid duplicate/escaping paths and ambiguous ownership.
Declare externally linked originals individually as external/not included; never
claim them backed up merely because bookmarks were archived.

Acquire repository save/import/retention quiescence, capture one committed SQLite
backup plus an exact file inventory, and verify bytes/metadata/revision sets before
publishing archive success. Reject or retry any intervening mutation; a DB snapshot
alone cannot establish source-file consistency. Declare the separate draft boundary:
either include lease-validated recovery snapshots under a distinct preservation
namespace, or list drafts as excluded with vault identity, capture time and an explicit
warning that unsaved edits are outside archive consistency. Include unresolved unique
staging/conflicts as preservation entries, or declare their exclusion; an archive
with exclusions must not claim preservation completeness.

Verification independently checks checksums, supported versions/capabilities,
manifest/database UUID agreement, foreign keys, block reconstruction, identities and
all included blob references. Restore into a new empty local staging root, verify it,
and publish create-only; never overwrite an existing vault, silently merge identities,
reimport Markdown over DB pages or discard unsupported payloads. NativeVaultArchive implements a version-1 directory package with a SQLite backup,
manifest, controlled originals and in-vault preservation files. Unsaved app-local
RecoveryStore drafts and linked external originals are explicitly excluded. Unsupported
schemas are rejected without conversion. Restore verifies the indexed manifest's
checksum and supported schema-6/7/8/9 authority before creating or writing staging;
declared archive database construction also rejects unsupported declarations.
Capture and restore retain the operation
lease at every byte and staging SQL boundary, including after suspension; lock
revocation stops further protected writes. Every included file is checksummed,
canonical logical payloads and source references are verified, and failed nonempty
staging is preserved. Root publication is an explicitly reviewed create-only move.

### Locality and future protection

Current `requireLocalRoot` rejects non-file URLs, resolved symlink differences,
nonlocal/unverified volume state, ubiquitous ancestors and known cloud folder names
(`CloudStorage`, `Mobile Documents`, iCloud Drive, Dropbox, OneDrive, Google Drive,
Box). Published DB inspection requires a regular nonsymlink nonubiquitous file.
These metadata/name checks do not universally detect arbitrary synchronizers or
provider-managed roots with ordinary names. STOR.02 must reuse and strengthen
admission when trustworthy provider/volume evidence exists, fail closed on unavailable
locality evidence, and document the remaining discovery limit. A user-selected path
or manifest `localOnly` flag is not proof. Recheck at staging/publication/open; never
synchronize live DB/WAL/SHM through file-copy services.

The [classification policy](#classification-and-lifecycle-policy) remains the E-series
protection inventory: DB/WAL/SHM and temporary SQL data; source originals/staging;
manifest identity/metadata; drafts, conflicts and Trash; derived indexes/embeddings;
previews and temporary copies; backups/archives; recovery/key-management material.
Adapter plaintext routing alone cannot encrypt live SQLite. Key lifecycle, encrypted
SQL construction and opt-in format migration require separate reviewed design.
Native authentication/session locking grant no at-rest encryption, secure erasure
or iCloud-delivery guarantee. Device, accessibility and crash-durability acceptance
remain open under [validation](../validation.md).

## Permitted I/O exceptions

| Owner | Permitted access and limits |
| --- | --- |
| FileVaultRepository discovery | Directory enumeration, existence/permission checks, URL resource values, symlink/containment checks, `lstat`, bookmark resolution and security scope. These inspect names/attributes, not canonical bytes. iCloud hydration requests remain provider operations. |
| External source acquisition | Repository coordinatedRead/downloadCloudFile/readLinkedSource, AppModel's selected import-file read, and SourceReader's linked-file read may read user-selected external originals under existing coordination/security scopes. These helpers must never serve vault-owned canonical paths. Linked originals are never written or deleted. |
| OS conflict versions | Repository reads NSFileVersion URLs through coordinatedRead, preserves copies through the adapter, then resolves/removes OS-owned versions. Preserve all copies before resolution. Version discovery/resolution is outside the vault byte protocol. |
| VaultCreation parent operations | Create a sibling staging root, publish the entire initialized vault by a coordinated same-parent move, and clean only positively empty owned failed staging. Preserve nonempty, partially initialized, completed or unreadable staging after failure and report its location. Canonical contents inside staging still use the adapter. Never merge an occupied destination. |
| RecoveryStore | App-local directory creation, atomic draft JSON reads/writes and explicit lifecycle deletion of decoded drafts. Listing reports individual unreadable, damaged JSON or mismatched-identity entries while preserving bytes and returning valid peers. Same-page writes archive a damaged existing file before replacement; decoded-draft deletion refuses damaged entries. Drafts can be the only unsaved copy; they are preservation data, not disposable cache. Public construction requires a nonoptional gate and explicit lease (nil is rejected before directory creation); only the internal `unguardedTestingDirectory` initializer permits ungated fixtures. Every production read/write/delete revalidates the captured lease. |
| SQLiteBlockStore | Canonical format 2 page metadata and block records in the selected local vault database. Actor-owned SQLite connections, transactions and SQLite-managed journal/WAL/SHM are the page-storage exception; manifest, conversion backup/publication and source bytes use the selected `VaultContentStore`. Production construction passes the captured gate/lease. Canonical transactions use WAL with synchronous=FULL; temporary SQLite data stays in memory. Save acknowledges only a successful COMMIT, rechecking cancellation and publication authority first. Quiescence checkpoints before lock; a failed checkpoint aborts the transition. Connection retirement uses sqlite3_close after a successful lifecycle transition, including revoked leases. SQLite owns WAL/SHM cleanup and crash recovery; never unlink journals. Explicit backup reserves a new external destination and uses sqlite3_backup, including committed WAL content; failed snapshots are unacknowledged retained output. Reject cloud-backed conversion roots and never treat preserved Markdown as simultaneous page authority. |
| SQLiteSearchIndex | App-local directory creation, SQLite connection and SQLite-managed WAL/SHM. Derived data is rebuildable; connection ownership remains in the index actor. |
| SQLiteAIActivityStore | App-local `<Application Support URL>/Noema/Activity/activity.sqlite` directory creation, actor-owned SQLite connection and SQLite-managed WAL/SHM. Metadata-only operation history spans vaults and survives search-index rebuilding. Production construction uses the fixed application-support location; injected URLs are for disposable tests. It never reads or writes canonical vault bytes. |
| SQLiteAIWorkLedger | App-local `<Application Support URL>/Noema/Processing/work.sqlite` directory creation, actor-owned SQLite and SQLite-managed WAL/SHM. Schema 1 stores bounded typed work metadata and revision checkpoints only. Production uses this fixed application-support location; injected URLs are isolated test seams. It never stores documents, prompts, credentials or runtime authority, and never owns canonical bytes. Reopening recovers interrupted scheduled/running rows for fresh authorization. |
| AIActivityExportDestination | Native Save panel selects a new external JSON destination before writing. Resolve existing parent symlinks and compare directory resource identities (including case aliases), rejecting captured/current vault roots and known recovery/activity roots; use `withoutOverwriting` to refuse all existing files and concurrent replacements. No canonical mutation, directory creation or cleanup deletion. Interrupted external writes may leave a partial new export; this is not canonical publication. |
| Preferences/capabilities | UserDefaults, theme/editor/macro settings and selected-folder bookmarks use OS-managed persistence outside the portable vault. Sidebar recent access uses a versioned UserDefaults key per manifest UUID and stores at most ten typed page/source/block identifiers in MRU order, without titles, excerpts, bodies or paths. AppModel restores identifiers only after vault admission establishes the manifest identity and selected repository, resolves presentation from loaded records, and owns successful-access updates and pruning. Metadata-only source-table focus does not count as content access. Lock/close clears its in-memory history, selection and presentation; unlock/reopen restores only the admitted vault’s bounded history, while preferences remain local plaintext metadata. |
| Native preview and observation | SourceReader gives Quick Look a disposable app-local snapshot of adapter/checksum-validated imported bytes. It never gives Quick Look an imported canonical URL; linked previews retain external URLs. Reader close, errors and vault switching request snapshot removal. SourcePreviewDirectory confines copies to an application-owned temporary root; a versioned marker and kernel reader lease establish cleanup eligibility. Launch examines at most 128 immediate children and removes only owned, unlocked direct files, without recursive deletion. Filesystem failure or interrupted cleanup can leave copies for later launch attempts; this is not secure deletion. Finder reveal passes URLs to NSWorkspace. These platform services remain outside the adapter. |
| Network and fixtures | HTTP source capture/research uses existing fetchers; publication uses the adapter. Tests use disposable vaults and deliberate direct writes to simulate external edits. Development scripts, build outputs and generated brand exports are outside runtime canonical storage. |

### Derived semantic index ownership

`SQLiteEmbeddingIndex` owns only `KnowledgeVault/<vault UUID>/semantic.sqlite`
under an application-support root. Its constructor requires the admitted lease and
gate, resolves symlinks and rejects canonical-root overlap before directory creation
or SQLite open. Its private connection owns all SQL and WAL/SHM lifetime; its schema
is independent of canonical storage. No input text or execution grants are persisted.
Document replacement and generation cleanup use rollback transactions, exact generation
metadata and caller publication predicates plus live lease checks before COMMIT.
AppModel open/unlock supplies the existing application-support base and admitted
lease/gate; constructor failure is isolated from canonical opening and FTS. Close/lock
retires the actor reference. Retrieval/embedding processor callers must still provide
current revision/provider validation before automated publication is installed. Reads return revision-bearing records for canonical freshness filtering.
Corrupt or foreign databases fail closed without deletion; lexical fallback and derived
rebuild remain application integration work. No cleanup of canonical or recovery data
is permitted. Author and independent reviewer traced the new two exceptional calls
to this owner; focused rollback, lease, reopen and generation tests provide code
evidence, while production routing and crash-durability acceptance remain outstanding.

The SEM.EMB04A permit path preserves these SQL owners and storage locations. Canonical
constructors, transactions and close share a normalized-database publication domain;
only `SQLiteBlockStore` issues revision/lifecycle permits. The protected index overload
checks permit entity/revision/vault and authority lease/full generation before its
actor-owned transaction. The final synchronous derived COMMIT holds domain then authority,
with all gate/provider validators outside those locks. Session revocation invalidates
authority synchronously. Completed cloud request evidence retains issuer/session retirement
registrations through the derived COMMIT; session retirement propagates credential changes.
Application/service provider/model/credential/consent mutations synchronously retire these
same authorities before changing state. Construction and exact request approval are distinct;
no enrichment grant is used. No embedding processor is installed by this prerequisite. No filesystem or SQL-open exception is
added. External direct SQLite writers and atomic linked-file/SQLite publication remain
outside the guarantee. Failed canonical transactions conservatively retire permits.

## Enforcement and review

`python3 scripts/check-storage-boundary.py --selftest` checks every Swift file under Sources for known Foundation byte reads/writes, filesystem mutations, stream/handle creation, SQLite opens, generic coordinatedRead calls and URL-based PDF/Quick Look access. It also reviews initializer references, handle byte methods/references, additional Foundation content/replacement/link and file-attribute mutations, qualified Darwin/Glibc byte and mutation APIs, and recognizable unqualified POSIX calls. Foundation directory creation is identified by its `withIntermediateDirectories` argument so protocol directory operations remain permitted. Runtime plaintext adapter references (including type aliases and metatypes) are confined to its implementation and `VaultStorageProvider`. Test and build wrappers run the guard before Swift compilation. `scripts/storage-io-exceptions.json` records exact normalized statements, occurrence counts and ownership reasons; new or removed exceptional calls fail. Only the plaintext adapter is exempt from the byte-I/O scan. There is no automatic baseline update command.

This is a lightweight lexical code-review guard, not a Swift parser, security sandbox or proof of absence of I/O. Reviewers must inspect indirect APIs, newly introduced APIs/POSIX calls, root routing, Quick Look, metadata probes and adapter construction. Moving a permitted expression within the same file or changing its target without changing its text still requires semantic review. Unknown imported helpers and ambiguous unqualified function references can evade this vocabulary; comments and strings can also cause false positives. Every allowlist change must name an owner and exception above; canonical content must use the protocol. Tests and full build evidence are recorded in ../validation.md. No manual UI, actual provider hydration/conflict-version or two-Mac iCloud sign-off is implied.

### Required author and reviewer disposition

Changes to runtime storage construction, canonical access or I/O exceptions require both author and reviewer to inspect changed code; mark the PR storage disposition N/A only when none apply. A passing scanner does not complete this review.

- Trace each changed storage target and helper call to its owner. Canonical vault bytes and mutations use `VaultContentStore`, except actor-owned format 2 page database operations in `SQLiteBlockStore`, including indirect or newly introduced Foundation/POSIX/third-party APIs.
- Verify runtime adapter construction remains in `VaultStorageProvider` and selected stores, roots and session leases reach every affected consumer. Inspect aliases, factories and dependency injection.
- For each exception change, explain its permitted owner and target in this contract, inspect enclosing helpers/callers, and verify targets stay outside canonical paths. Review unchanged allowlisted expressions when variables, target URLs or enclosing helper ownership change.
- Inspect preview/error/lock/switch lifecycle handling and preservation/cleanup policy where affected; ordinary cleanup is not secure deletion.
- Run `python3 scripts/check-storage-boundary.py --selftest` and relevant adapter/lifecycle tests. Add an adversarial fixture for new guard vocabulary or document the remaining review-only blind spot.
- The reviewer records completion of this review (or explicit N/A) and unresolved limitations in the review; the author's PR records its own disposition.

The [adversarial fixture manifest](../../scripts/fixtures/storage-boundary/cases.json) runs through `--selftest` independently of the production exception inventory. Its cases detect wrapper-contained readers, initializer references, Foundation/POSIX APIs, indirect adapter references, exception relocation across files and duplicate counts. Explicit `review_only` cases demonstrate the remaining same-file helper/target and opaque API blind spots; their accepted scan results require semantic review and do not authorize canonical bypasses.

D01.R2 construction: VaultStorageProvider alone constructs the runtime plaintext adapter. Each repository retains one selected store, shared explicitly with reader, availability and summary consumers. Staged creation uses the same provider for its staging root; published vault open obtains a store bound to the final root. Plaintext v1 bytes and bookmarks are unchanged.

Native vault admission uses the selected `VaultStorageProvider` for pre-authentication
manifest identity/safety inspection and fresh identity checks. Existing canonical
bytes still route through `VaultContentStore`; authentication introduces no new byte
I/O exception or plaintext-adapter constructor. After admission, repository construction
uses the new D02 lease and gate before AppModel constructs app-local index/recovery
stores. The locked-folder permission-recovery route must retain the captured normalized
root and vault UUID. App-local authentication preferences belong to the existing
UserDefaults exception and never alter the portable manifest. The
[admission contract](vault-access-authentication.md) qualifies workflow enforcement
and plaintext/preference-tampering limitations separately from storage routing.

## App-local locations and lifecycle evidence (D02.REM07)

The production base comes from Foundation's user-domain `applicationSupportDirectory` URL in both `AppModel.open` and `unlockVault`. It can resolve inside the sandbox application container; `~/Library/Application Support` is an unsandboxed example. Tests can replace the base with `AppModel.localStorageRoot`. The code appends these exact components:

| Store | Runtime location | Ownership and lifecycle limit |
| --- | --- | --- |
| Search index | `<Application Support URL>/KnowledgeVault/<vault UUID>/search.sqlite`; optional SQLite-managed `search.sqlite-wal` and `search.sqlite-shm` beside it | Rebuildable data owned by the index actor. Closing/detaching the index on lock does not encrypt or securely erase database/WAL bytes. |
| AI activity history | `<Application Support URL>/Noema/Activity/activity.sqlite`, with SQLite-managed WAL/SHM | Application-level metadata owned by `SQLiteAIActivityStore`, independent of search-index rebuilding. Vault/target UUIDs remain plaintext when locked. Retention and Clear History perform ordinary row deletion, without secure-erasure guarantees. |
| AI work ledger | `<Application Support URL>/Noema/Processing/work.sqlite`, with SQLite-managed WAL/SHM | Rebuildable metadata owned by `SQLiteAIWorkLedger`: target/vault UUIDs, processor/version, opaque revisions/fingerprints, states, attempts, dates and finite reasons. Retained across lock/relaunch; no content, grant or capability. Ordinary row replacement is not secure erasure. |
| Recovery journal | `<Application Support URL>/KnowledgeVault/<vault UUID>/Drafts/<note UUID>.json` | Unsaved preservation data owned by `RecoveryStore`. Guarded construction and each operation enforce session leases; retained drafts remain plaintext on disk. |
| Imported Quick Look snapshot | Foundation's temporary-directory URL plus `noema-source-previews-v1/<UUID>/`, containing the source copy and `.noema-preview-lease` ownership marker | Validated copied bytes in 0700 directories and 0600 files. Launch cleanup removes validated orphans after the process lease ends, including after process termination; each launch is bounded to 128 children. Invalid/unmarked/extra-content/symlink entries and unproven legacy `noema-preview-<UUID>/` directories are retained. Cleanup is best effort ordinary removal, not secure erasure. Linked previews retain external originals. |

Preview retention has no age threshold: a validated snapshot is eligible for ordinary removal once its process lease is released. The launch budget counts every examined child, including active or ambiguous entries; a preserved backlog can postpone other candidates beyond that budget. Empty unmarked directories left after interrupted marker removal are preserved because they no longer establish ownership; they contain no preview payload. Cleanup does not overwrite disk blocks or claim secure erasure.

Session lease revocation and lifecycle locking restrict in-process protected access. Canonical `Wiki/`, `Sources/`, `Removed Pages/`, conflict copies, the manifest, the local stores above, and linked external originals remain readable outside that boundary. The source inventory and lexical guard establish routing and reviewed exceptions, not at-rest confidentiality or transport reliability.

The [milestone evidence matrix](../validation.md#d02-evidence-matrix) separates implementation, named automated scenarios, and pending device acceptance. In particular, [RecoveryStoreAccessTests](../../Tests/VaultCoreTests/RecoveryStoreAccessTests.swift) checks rejected construction and retained-store revocation without changing draft bytes; [VaultCleanupFailureTests](../../Tests/VaultCoreTests/VaultCleanupFailureTests.swift) checks cleanup errors with committed/recoverable content preserved. [SourceAdapterTests](../../Tests/VaultCoreTests/SourceAdapterTests.swift), [TrashAdapterTests](../../Tests/VaultCoreTests/TrashAdapterTests.swift), and [WikiPageAdapterTests](../../Tests/VaultCoreTests/WikiPageAdapterTests.swift) provide the D01.R3 failure-injection cases named in [its acceptance record](../validation.md#d01r3-evidence). Their adapter-boundary injections do not establish arbitrary filesystem/process-crash behavior. Local-save acknowledgment is separate from iCloud transport; real provider hydration/conflicts and two-Mac arrival remain pending.

## Sensitive-data surface inventory

The app-local location table above and this table are one inventory. Locations are
relative to the selected vault unless stated otherwise. A revoked session denies
protected application access; every listed persisted content surface can still leave
plaintext after locking. Filesystem, provider and OS access are separate boundaries.

| Surface and source owner | Location/content | Retention, access and disposal |
| --- | --- | --- |
| `FileVaultRepository` / selected stores authoritative content | `vault.json`; format 2 schema-6/7/8/9 `blocks.sqlite` plus SQLite-managed WAL/SHM; controlled imported `Sources/<UUID>/original.*`; titles, bodies, source paths/bookmarks, classifications, summaries, provenance, favourites, collections and folders | Retained across lock/close/switch/relaunch. Admission inspection reads manifest identity before authentication; protected content operations require the selected lease. Canonical edits/deletion use revision-checked SQLite transactions; immutable originals and preservation bytes use conditional adapter operations. |
| Repository preservation and retention | `Removed Pages/`, legacy `.Trash`, `Conflicts/`, `Trash Retention.json`; removed content, competing edits, imported originals and timestamps | Conflicts survive until explicit disposition; preserve OS conflict copies before resolving versions. Existing Trash expiry is 15 days, with undated grace and snapshot/error preservation. Linked originals are never deleted. |
| Repository import staging | `Sources/.import-<UUID>/`; original bytes and metadata before publication | Adapter-owned, lease-checked staging. Failed publication deliberately retains it. Explicit staging cleanup uses exact snapshots; no new age-based deletion policy is implied. |
| `VaultCreation` | Selected external parent `/.noema-create-<UUID>/`; partial or initialized vault | Same-parent publication refuses an occupied destination. Failure cleanup removes only positively empty owned staging; nonempty or unreadable staging is preserved with its location reported. Published vaults survive subsequent open/authentication failure. No startup sweep is implied. Contents still use the selected adapter. |
| Search, recovery, activity and imported previews | Exact app-local locations and owners in the preceding table | Search includes serialized page/source records, FTS body/title/aliases, tags and links. Recovery includes unsaved text. Activity retains technical metadata/UUIDs, never text/titles. Previews contain copied originals. These have different disposal policies and must not share a blanket cache purge. |
| `AppModel`, repository caches, editor/inspector/search and `SourceReader` | Process memory; decoded documents, original bytes, queries/hits, selections, AI proposals and auxiliary reader views | Session clearing, source-cache retirement and completion predicates restrict reuse across lock/close/switch. No disk cache is authorized by these owners. Swift object release is not secure memory erasure. |
| `ExternalAIService` / `ExternalAIDebugDiagnostics` | Process memory; latest bounded rejected provider response, potentially containing private text | Explicit debug opt-in while open only; session invalidation disables and clears it. Neither report nor enabled state belongs in preferences, logs or activity. See [diagnostic contract](external-ai.md). |
| Preferences / `TeXMacroStore` / bookmark owners | OS-managed UserDefaults; theme/editor/pane geometry, validated AI configuration/consent policy, local authentication preference, vault bookmark and user-authored TeX macros | Retained across lifecycle transitions. Presentation settings are ordinary metadata, but bookmarks, vault identifiers and macro replacement text can be sensitive; preferences are not an encrypted store. Explicit setting changes own deletion. |
| `ExternalAICredentialBroker` | OS Keychain API key; transient request Authorization header | Keychain owns persistent credentials; app state receives credential status only. Vault lock revokes submission authority without deleting the user's saved key. Keychain protection does not encrypt vault copies. |
| `OpenAITransport`, `WebSourceFetcher`, topic research | Transient request/response buffers and externally transmitted selected text, topic/URL and network metadata | Ephemeral sessions disable cache/cookie/URL credential stores. Explicit cloud action authority and bounded publication apply; transmitted bytes cannot be recalled. Provider, network and website retention are external. See [external AI contract](external-ai.md). |
| `AIActivityExportDestination` | User-selected new external JSON file; up to 1,000 metadata records without vault/target identifiers or titles | Explicit Save selection, protected-root checks and create-only write. Export survives lock/relaunch; failed writes may leave partial new files. User owns subsequent disposal. |
| Editor and summary copy / platform services | General pasteboard copied text/URLs, drag identity; linked-original Quick Look, Finder reveal and OS-managed representations | Explicit copy/export and platform presentation cross the app boundary. Lock does not recall clipboard contents or guarantee removal of OS-generated thumbnails, crash reports, swap or snapshots. No persistent content diagnostic logger is introduced by current source. |

Current plaintext retention and external/OS copies are accepted limitations, not
storage bypass authorizations. The lexical guard plus owner/target review above
remain required for any newly discovered secondary copy or I/O API. Crash-restart
and real-provider behavior retain the acceptance limits in [validation](../validation.md).

## Classification and lifecycle policy

This policy applies to the inventory above without changing plaintext v1 format,
current Trash expiry, activity retention or native admission. Identity and linkage
metadata can be sensitive even when a store is metadata-only.

| Class / mapped owners | Required lifecycle and deletion policy | E-series disposition |
| --- | --- | --- |
| Authoritative content / repository (including canonical SQLite database/WAL/SHM) and published AI artifacts | Necessary durable data. Retain on lock, close, switch and crash-restart; protected application access requires current authority. Delete only through existing explicit/retention operations with their conflict and snapshot checks. | Encrypt canonical content, SQLite database/WAL/SHM and temporary data, and sensitive metadata, including names/layout if required by the chosen threat model; preserve conditional writes, format negotiation and interrupted-publication compatibility. |
| Preservation data / recovery, conflict copies, Removed Pages and failed import staging | Potentially unique data is not disposable cache. Preserve drafts and damaged entries on failed cleanup or decoding; conflicts precede version resolution. Existing Trash expiry remains valid. A staging cleanup must establish ownership and intended cancellation; it cannot infer that all interrupted content is redundant merely from age or a prefix. | Protect drafts, archives, conflicts, staging and retention records with recoverable key availability; interrupted migration must preserve the only copy. Lock cleanup must not destroy unsaved content to hide plaintext. |
| Rebuildable derivatives / search SQLite and in-memory derived catalogs | Necessary for current search, rebuildable from accessible authoritative content. Revalidate retained actor operations and stale publications. Detach session references on lock/close/switch; SQLite owns connection/WAL/SHM disposal. Restart can reopen the matching vault index. Never unlink journals while a connection is active. | Protect database pages, FTS/serialized records, WAL/SHM and rebuild/migration intermediates, or adopt an explicit memory-only policy; revocation alone cannot protect old disk bytes. |
| Transient sensitive data / editor, source readers, preview copies, requests/results and debug report | Keep only for their owning operation/session. Revoke publication and clear presentation on lifecycle invalidation; debug mode also disables. Preview close/failure and bounded restart cleanup use ownership and process leases. Crash leftovers are ordinary-cleanup candidates only when proven disposable. | Prevent plaintext preview/export-to-platform copies unless explicitly authorized by the encrypted-vault policy. Define crash leftovers and OS-visible representations; memory release and file removal remain weaker than secure erasure. |
| Ordinary settings and technical metadata / preferences, activity and AI work ledger | Non-content geometry/theme/configuration may persist while locked. Bookmarks, identifiers, macro text and usage timing remain potentially sensitive. Activity is durable application metadata with independent configured retention, startup interrupted reconciliation and explicit Clear History. Never add raw content or authority to it. Work-ledger UUIDs, opaque revisions, fingerprints and checkpoints are sensitive derived metadata with no execution authority. | Decide protection/redaction for cross-vault UUID linkage, work-ledger revisions/fingerprints, bookmarks, user macro text and activity identifiers while retaining accepted history/settings. Do not silently purge history as a search rebuild. |
| Externally owned or disclosed data / linked files, explicit clipboard/export, websites and AI provider | Existing scopes and selected-action authority govern access. Linked originals must never be mutated/deleted. Export/copy persists outside lifecycle ownership; cancellation cannot recall sent bytes. No cleanup of external files to satisfy an internal retention policy. | Require explicit disclosure policy for plaintext export, clipboard, linked previews and provider submissions; encryption cannot promise confidentiality of copies the user/provider/OS controls. |

Close/switch must preserve pending edits through the existing save/recovery boundary
before releasing resources. Failed quiescence must not publish a successful lock.
Crash-restart does not restore session or submission authority from persisted records.
Any implementation claim needs named tests and the independent owner/target review;
lexical scan success is not proof of confidentiality, complete in-process isolation,
secure erasure, arbitrary crash durability or iCloud arrival. E-series key design,
opt-in migration and device acceptance remain future work, not D04 implementation.

## External AI publication and credential ownership

- Page/source snapshot and atomic enrichment/reviewed-page/accepted-title publication in `SummaryPublication.swift` use revision-checked `SQLiteBlockStore.savePage` with an in-transaction publication predicate for format 2 pages; Source metadata uses canonical SQLite; imported-original bytes and change tokens use the injected `VaultContentStore`. Original extraction reuses `readSourceOriginal`, retaining canonical path and checksum validation. Conditional replacement compares exact captured bytes and change tokens, preserving external content edits, independent summaries and deleted targets.
- Linked-source change tokens inspect the resolved external original's inode/device/size/mtime/ctime under its existing security scope; bytes continue through the existing coordinated external-original read. This is attribute inspection, not a new canonical byte exception. There is no transaction across external original bytes and vault metadata.
- Cloud output/provenance enters the existing block/source persistence. Canonical artifact provenance contains provider, model, generation time, independent common artifact generation UUID and optional local source-content revision; request IDs, session IDs, capabilities, consent receipts, consent digests and HTTP bodies are not persisted with artifacts. The separate AI activity history adds a logical operation UUID (the request UUID for cloud operations) for diagnostic correlation, as specified in the [activity contract](external-ai.md#activity-history); it grants no authority and retains no session/capability/consent/HTTP data. The plaintext summary itself can contain private information. Existing local summary generation clears stale cloud provenance when replacing a summary.
- API keys are confined to the ExternalAI Keychain record and transient request Authorization headers. The transport uses ephemeral sessions with no cache, cookie or URL credential store, and finite sanitized errors. External AI connection preferences persist only a validated model identifier and the finite reasoning effort selection. The separate versioned AI provider settings contain only a finite default provider and per-action overrides, never content or authority. No credential/vault-content diagnostic logging was introduced.
- Reviewed the new runtime paths and existing exception ledger. D02A requires no new canonical byte I/O exception or plaintext adapter construction. The standing regex guard detects known APIs, not malicious indirect code or every operating-system behavior; semantic review remains necessary.

Vault AI configuration uses the existing OS-managed UserDefaults preference boundary,
keyed by admitted vault UUID, with versioned nonsecret enabled/provider intent only.
It does not mutate the manifest or schema-6 declaration and is not portable to another
Mac. No content, cloud grant, credential, receipt or session capability is stored there.
The automatic page-title caller supplies a revocable predicate through the repository
save overload to the existing SQLite transaction; source processing uses its existing
conditional publication predicate. No canonical I/O exception or adapter constructor
is added. Author inspection covers those callers, predicate routing and preservation
of existing content; independent reviewer inspection and storage-boundary checks remain
required before acceptance.

Durable AI approval is owned by `ExternalAIVaultGrants` in the separate
`com.noema.external-ai.vault-grants` data-protection Keychain service, never the manifest
or UserDefaults. Root inode/device attribute inspection binds approval to the admitted
local directory; it reads no canonical content bytes and constructs no adapter. Grant
records contain identity/version/scope only, never text, API keys or runtime receipts.
`externalAI.vaultGrantRevocation.v1.all` and vault-UUID-suffixed keys in the existing
UserDefaults boundary hold denial-only UUID generations, never grants. Revocation flushes
and verifies the denial marker before attempting Keychain mutation; old grant records must
match both nonempty generations. Explicit approval initializes missing markers with fresh
UUIDs and flushes/verifies them before creating a new Keychain grant. Missing markers or
legacy empty fences never authorize a request. Markers survive Keychain failure and are
not cleared by approval. Vault configuration and runtime revocation take effect before
Keychain cleanup; cleanup failure leaves the requested local policy in force.
No new canonical content I/O or authority store is introduced by these denial markers.
Only device-only Keychain builds support these records. Author static review covers
that metadata target and the existing gateway/SQLite publication routing; independent
review, scanner selftests and signed-device checks remain unperformed in this change.

ENT.01 schema 7 additionally requires `entityPropertiesV1`. Typed definition/value tables and explicit migration remain owned by SQLiteBlockStore; manifest publication uses the selected gated VaultContentStore. Interrupted publication rejects normal admission and requires explicit resume. See the [typed property contract](knowledge-model.md#typed-entity-properties-ent01); no Page/Source column or byte ownership changes.

ENT.02 adds only the explicit supported 7→8 upgrade and `entityRelationshipsV1`; the same SQLite actor owns canonical edges and both traversal indexes. Author/reviewer trace, typed endpoint FKs, revision checks and precommit lease validation remain mandatory. See [directed property contract](knowledge-model.md#directed-entity-properties-ent02).
