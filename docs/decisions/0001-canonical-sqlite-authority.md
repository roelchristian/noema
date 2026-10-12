# Canonical SQLite authority (STOR.01)

Status: approved architectural specification with conditional implementation
handoff; author and independent dispositions are recorded below. This decision
authorizes no runtime authority transition.

## Baseline and reconciliation

Baseline: `890898fbe0d1511e64dd3e41f932be1147bb79b3`, also the connected
GitHub application's `main` when inspected on 2026-10-12. The working tree began
clean. There was no existing ADR directory. Source and tests govern discrepancies.
[BLK09–11](https://github.com/roelchristian/noema/pull/35) and
[BLK12–14](https://github.com/roelchristian/noema/pull/36) are merged. Their reported
691-test and 55-test runs are historical evidence, not tests repeated by STOR.01.
Both PRs left independent storage review and production acceptance outstanding.

| Capability / classification | Current evidence and source of truth | Disposition / owner |
| --- | --- | --- |
| SQLite pages: implemented and verified by named tests | `SQLiteBlockStore`, `SQLiteBlockStoreTests`, `SQLiteRepositoryTests`: actor connection, prepared statements, FK parentage, relational ordering, opaque revisions, atomic page/document writes, incremental changed rows | Preserve foundation; STOR.02 extends its owner |
| Durability: implemented but limited | BLK12 transaction cancellation/authority checks, WAL/FULL, backup API, checkpoint and AppModel retirement; existing cancellation/backup/lifecycle tests cover specific schedules | Preserve; STOR.03 must establish process/power-loss and disk-failure acceptance |
| Migration: implemented but limited | `SQLiteVaultMigration` and tests: verified file backup, staged page import, byte/inventory rechecks, database publication then conditional manifest cutover, receipt-based interrupted publication recovery | No conversion here; STOR.03 extends explicit migration to new authorities |
| Markdown interchange: implemented but limited | `MarkdownInteroperability`, explicit import and stable-ID export tests; readable export reports loss | Preserve BLK13 APIs; native workflow acceptance remains open |
| Source/page references: implemented but limited | `NoteRecord.sourceIDs` in SQLite page metadata; sources remain `Sources/<UUID>/metadata.json` and controlled originals | STOR.02 moves metadata/references together; present relationships have no source FK or cross-store transaction |
| General metadata authority: documented only here / missing in runtime | No schema-2 source, conflict, vault-identity or tombstone tables; file-backed source Trash/conflicts/retention remain canonical | Explicit schema/capability transition; never reinterpret schema 2 |
| Unknown fields: contradictory guarantee | `BlockStore` comment promises opaque retention; current typed Codable models preserve supported fields and declared string metadata, not arbitrary JSON keys | Contract records limit; STOR.02 supplies bounded opaque payloads and writable capability gates |
| Universal sync-root detection: missing | `requireLocalRoot` checks symlinks, ubiquity, positively local volumes and known provider/root names; arbitrary synchronisers cannot be inferred | Preserve fail-closed checks and require independent local-root choice; no live-file replication |
| Complete archive: missing | Page bundle omits source/preservation data; database backup omits file authorities and app-local drafts | Separate verifiable archive/restore contract; STOR.03 |
| SQLite unavailable / production v1-only: superseded, contradictory | Older D-series/editor/development wording conflicts with merged format-2 routing | Replace in authoritative docs; no second implementation |
| Default SQLite creation: documented only here | `VaultCreation.createNewVault` still initializes format 1 | STOR.02 explicitly changes eligible new creation; existing identities/formats unchanged |
| Encryption: missing implementation, future dependency | Authentication and session gates enforce application access only; persisted surfaces remain plaintext | E-series owns cryptography and device acceptance; never imply confidentiality from locking |
| Inline annotations: documented only here | Rich runs are formatting values, no annotation identities or anchors | Deferred extension in block contract; no tagging/entity engine |

## Decision and authority

Keep `BlockDocument` as the AppKit-independent domain model, `EditorSession` as
mutable document/selection/undo/dirty-state owner, and `SQLiteBlockStore` as the
single canonical database actor. Relational block rows are content authority;
document properties omit their blocks and page metadata omits body/revision copies.
Do not add a competing serialized authoritative document or SQL-facing UI API.

Current format 1 owns pages in Markdown. Current format 2/schema 2 owns page
metadata, block documents and page trash in `blocks.sqlite`; sources, original
bytes, source Trash, preserved conflicts and retention information retain the
selected byte adapter. Page source UUIDs live in page metadata. Search/FTS are
rebuildable app-local projections; activity is separate durable app-local metadata
history; drafts are separate preservation authority until committed/discarded.

Target expanded authority owns vault structured metadata, pages/blocks, source
metadata, page-source relationships, logical Trash/tombstones, conflict disposition,
revisions and integrity information in that same database. Imported immutable
originals remain checksum-verified controlled files; linked originals remain
externally owned and must never be written or deleted. Drafts and activity do not
become canonical vault content. Query indexes/embeddings are disposable projections.
The [storage contract](../contracts/storage-boundary.md) specifies record ownership,
schema invariants, compound APIs and recoverable byte publication.

Retain outer manifest format 2 and top-level `storageMode: sqliteBlocks`. Expanded
authority requires both schema `user_version = 3` and this durable declaration:

```json
"storage": {
  "mode": "sqliteBlocks",
  "schemaVersion": 3,
  "database": "blocks.sqlite",
  "localOnly": true,
  "requiredCapabilities": ["canonicalMetadataV1"]
}
```

The new reader must validate manifest identity/capabilities against database
`vault_state` before writable admission. Missing, contradictory or unknown required
capabilities reject; schema 2 without this declaration remains page-only. Current
`inspectManifest` rejects any nested `storage` object on format 2 before database
construction, and current stores reject schema 3. This is an equivalent durable
authority discriminator; changing outer format solely to add tables is unnecessary.
Do not ship the declaration until its schema, migration and opening checks exist.
No automatic authority-changing upgrade on open. Existing automatic schema 1→2
addition of nullable removal time remains a same-authority compatibility baseline.
Schema evolution is forward-only; downgrade means non-destructive verified restore
or export, never forcing `user_version` backward or reimporting preserved Wiki files.

New eligible local vaults should default to expanded canonical SQLite after the
STOR.02 prerequisites pass. Admit a verified local root, initialize a complete
staging vault with matching manifest/database identity and required capabilities,
validate and retire the staging connection, and publish by a create-only same-parent
move. Recheck locality at publication/open. Ineligible/unknown locations reject
SQLite creation with a clear reason; legacy Markdown creation is an explicit user
choice, never a silent fallback. Preserve nonempty/unreadable failed staging and
published vaults whose later authentication fails. Existing vaults never convert
because the default changed.

Document/SQLite/Noema interchange must retain supported stable identities,
hierarchy/order, rich runs, semantic/status/extension metadata, properties,
timestamps, source references and AI provenance. Readable Markdown intentionally
loses metadata and reports it. Unknown supported optional fields need bounded
opaque preservation; required unknown features/version mismatches deny writes.
Preservation-only access does not grant save permission. The
[block contract](../contracts/block-editor.md) defines these invariants and deferred
annotation identity/anchor/version/edit policies independently of formatting runs.

Noema archive is a separate versioned integrity-checked package containing all
canonical authorities and included original bytes, with explicit linked-original
and app-local draft boundaries. Neither a page bundle nor database snapshot is a
complete archive. Snapshot consistency, checksums, compatibility rejection and
create-only restoration are mandatory before STOR.03 acknowledges completion.

SQLite remains local-only. Verified volume state and known-root exclusion cannot
prove absence of arbitrary sync software; no live database file-copy sync. E-series
must protect database/WAL/SHM, originals/staging, manifest identity, drafts/conflicts/
Trash, indexes/embeddings, previews/temp copies, backups/archives and recovery/key
material with an explicit threat model. No encryption is activated by this decision.

## Alternatives and trade-offs

- Replacing SQLiteBlockStore with a new generic database layer would duplicate
  working revision/lease/transaction ownership without resolving a demonstrated defect.
- Keeping source metadata in JSON indefinitely avoids migration but prevents atomic
  source/page relationships and durable structured integrity across related operations.
- Reinterpreting schema 2 or adding ignorable capability fields lets old clients
  mutate authorities they do not understand; the required declaration plus schema
  version rejects those clients safely.
- Duplicating complete documents beside relational rows introduces two content
  authorities and defeats incremental updates; bounded opaque extensions retain
  future metadata without that duplication.
- Treating Markdown or a database-only snapshot as a vault archive loses unique
  source/preservation data. The separate archive requires coordination and verification.

## Dependency-ordered handoff and gates

| PR boundary / owner | Prerequisites and acceptance | Principal risk |
| --- | --- | --- |
| STOR.02 P0: version negotiation, schema and construction | Approved ADR/storage contract; manifest/schema/identity agreement and unknown-version write rejection; preserve schema-2 reads | Old client misidentifies authority; arbitrary unknown payload loss |
| STOR.02 P0: source authority transition | Negotiation first; explicit staging/migration inventory, source metadata/references/Trash/conflict transitions and revision tests | Mixed authority or references to missing bytes; never publish a half transition |
| STOR.02 P0: eligible-vault default creation | Fully supported expanded schema plus verified local staging/publication; legacy/ineligible/auth-failure tests | Partial initialization, unsafe root or implicit existing-vault conversion |
| STOR.02 P1: compound persistence/lifecycle/API integration | P0 authority model; blob stage/verify/durable publication then one metadata transaction; typed committed outcome and lease quiescence | Cancellation after commit, orphan originals, failure acknowledgement ambiguity |
| STOR.03 P0: compatibility, explicit migration, archive and restore | STOR.02 APIs; schema-2/format-1 fixtures and complete source/preservation inventory; verified create-only restoration | Duplicate authority, incomplete archive, overwriting user content |
| STOR.03 P1: adversarial and end-to-end acceptance | Above workflows; interruption/corruption/disk exhaustion/process/power-loss matrix and native acceptance | Unit tests do not establish filesystem durability or production usability |

The separately prepared STOR.02 brief was not supplied and no copy was found in
this checkout. Its conflict cross-check remains an explicit handoff prerequisite;
do not invent its requirements or claim agreement. Exact payload limits, filesystem
sync primitives, archive encoding and hardware acceptance need implementation-time
decisions/tests within the constraints above. Native accessibility, actual-provider
conflicts/hydration, two-Mac Markdown transport and crash-durability gaps remain open.

## Dispositions

Architectural author (`/root`): approves the specification only. Inspected current
construction/manifest gates, page transactions, backup/migration and lifecycle
ownership; no runtime/schema/manifest/data edits or exception expansion are authorized
by STOR.01. Future expansion must satisfy the migration and preservation gates.

Independent storage-boundary reviewer (`/root/architecture_review`): APPROVE
STOR.01 specification, CONDITIONAL handoff. Independently traced manifest/open/
provider ownership, schema-2 statements/FKs/revisions/publication/COMMIT, migration
receipts and byte revalidation, source/Trash/conflict and AI publication routing,
recovery/search/session lifecycle, and this ADR plus both revised contracts. No
material architectural disagreement remains; no runtime I/O exception is broadened.
Before STOR.02 authority/schema/migration/creation changes, cross-check its separately
prepared brief. Exact opaque limits, typed committed outcomes/idempotency records,
OS/filesystem flush evidence and migration/archive interruption acceptance remain
implementation gates. Device/accessibility, process/power-loss and transport limits
remain open. Scanner success and historical merged PRs do not substitute for this
semantic review. Detailed review evidence stays in the managed local run.
