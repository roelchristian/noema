# Canonical knowledge model

Status: approved KNOW01 contract, implemented by KNOW02/KNOW03 domain APIs and
explicit schema-4/5 staging and matching manifest/database admission. Existing
vault authority never upgrades on open. STOR02B production creation/defaults,
explicit migration and standing device/archive/crash acceptance remain separate.
The [decision](../decisions/0002-canonical-knowledge-model.md),
[storage boundary](storage-boundary.md) and [block editor](block-editor.md) govern
ownership, access, content identity and editing.

## Baseline and authority

STOR02A is merged at `a303881`. Schema 3 already has durable fresh staging and
admitted canonical repositories; it is not an unpublished schema available for
reinterpretation. `SQLiteBlockStore` owns the only canonical SQLite connection,
transactions, prepared statements and schema changes. `VaultStorageProvider` owns
construction; repository/domain APIs expose values rather than SQL. Pages/blocks
remain the sole content authority. Originals, recovery drafts and derived indexes
retain their existing owners. No knowledge JSON database, ORM or independent
connection owner is introduced.

`PersistencePayload` / `JSONValue` supply bounded optional JSON preservation.
`EntityIdentity`, `TypedEntityReference`, `InlineAnnotation` and document extension
annotations already exist. Exact UTF-16 transformations, split/merge, duplication
and stale/deleted preservation already have STOR02A tests; KNOW03 extends and
integrates those algorithms rather than replacing them with formatting runs.
These values do not yet resolve a canonical person/place/concept catalogue or own
independent question/definition records.

## Identity and domain boundaries

All identities are vault-scoped UUIDs, immutable and never reused. Type keys are
stable strings registered with versioned descriptors, not closed Swift enums or
SQL CHECK lists. Changing a type's meaning requires a new key/version. Registration
alone does not authorize writing an unknown required type implementation.

| Family | Initially supported types | Canonical fields and meaning |
| --- | --- | --- |
| Knowledge entity | `person`, `place`, `concept`, `event`, `creativeWork` | UUID, type key, canonical label, optional description, aliases, typed properties, store revision, created/modified timestamps, lifecycle. A person is a particular person; a place is a geographical/historically identifiable place; a concept is an idea, term, theory, subject or abstraction; an event is a particular occurrence or happening, without scheduling or timeline semantics. |
| Semantic object | `question`, `definition` | Independent UUID, type key, store revision, typed properties, lifecycle and timestamps. A question has optional answer text and status `unanswered` or `answered`; `answered` requires nonempty answer text. A definition has nonempty definitional text and optional term string. Both may have explicit related entity references; a definition may have one subject entity reference. |
| Annotation | Independent record | UUID, location, typed referent, designation, revision, payload, timestamps, anchor disposition and referent disposition. A location may be whole block, inline range, entity or semantic object. An annotation links a location to a referent; it owns neither. |
| Knowledge relation | Directed typed edge | UUID, registered predicate, source/target entity UUIDs, store revision, lifecycle, timestamps and optional provenance payload. Initial predicate `relatedTo` is manual/programmatic and directed; it makes no inferred factual claim. |

Labels are nonempty after whitespace trimming; retained display spelling is not
normalized. Duplicate names and aliases are valid and produce disambiguated search
results with UUID/type/label. Search matching may case-fold, but never defines
identity. Entity renaming leaves UUID, relations and occurrences unchanged.
`organisation`, `work` and `period` illustrate future registered types;
none is implemented here. Event uses the existing version-1 registry and entity
record. Fresh vaults seed its descriptor; existing schema-5 vaults register it in
the explicit entity-creation transaction, without changing schema or admission.
Opening a vault does not mutate its registry. Questions are not entity subtypes, and entities need
neither pages nor blocks. Question/definition text is object-owned content, while
an annotation quote is verification evidence and never a second block-text owner.

Typed properties use `PersistencePayload.properties` JSON values with registry
validation for known keys. Unknown optional keys/values and direct unknown fields
round-trip at every owning record and nested anchor/reference scope. Relational
identity/revision/lifecycle fields cannot be duplicated in a payload. Existing
256 KiB per payload scope and JSON depth 32 limits apply; excess/malformed values
reject admission or mutation without truncation. Unknown required features,
payload versions, type semantics or predicate semantics deny writes.

## Logical records and integrity

Exact DDL belongs to the implementation owner within these constraints.

| Stage | Records | Required integrity |
| --- | --- | --- |
| KNOW02, schema 4 | `knowledge_entity_types`, `knowledge_entities`, `knowledge_entity_aliases`, `knowledge_relation_types`, `knowledge_relations` | Type/predicate keys FK registered descriptors; entities UUID PK; alias UUID PK and entity FK; relations UUID PK with two entity FKs and predicate FK. No unique-name/alias constraint. Retained tombstoned rows satisfy references; no cascading entity deletion. |
| KNOW03, schema 5 | `semantic_object_types`, `semantic_objects`, `semantic_object_entities`, `semantic_annotations` | Types FK registry; object UUID PK; object/entity links have explicit designation and FKs. Annotation location/referent discriminators select exactly one typed owner/target. Resolved entity/object owners and referents have FKs to their records. Live block locations validate `(pageID, blockID)` together, never a block in another page. |

`semantic_object_entities` distinguishes `relatedTo` from definition `subject`;
subject cardinality is at most one per definition. Question-to-entity query returns
explicit links and separately labelled derived occurrence associations. Document
containment, source provenance, entity relationships, object/entity links and
co-occurrence are distinct. Overlapping annotations or textual nesting never
create ownership, typed relations or object/entity links automatically.

For stale/deleted content locations, retain captured page/block UUIDs and original
anchor evidence even if block rows disappear. Nullable live location FK columns
are cleared in the same transaction; captured identity remains. Page purge must
preserve independent annotation records transactionally before removing content,
or reject under the current annotated-purge gate. Entity/object location FKs can
remain attached to retained tombstone rows.

Unresolved imports retain target kind/UUID and opaque original reference payload
with no false resolved FK. A resolved referent selects an entity/object FK matching
its captured UUID; an unresolved referent has no live FK; a tombstoned referent
resolves to a retained row. Checks plus actor validation enforce discriminator/FK
agreement. Dangling live references are errors, never implicitly fabricated
entities. Existing page/source references remain typed legacy references and are
not recast as knowledge entities.

## Revision-checked APIs

The following names and input/result shapes are the implementation handoff.
Use public AppKit-independent `Sendable` domain values and asynchronous protocols.
`SQLiteBlockStore` conforms directly or supplies an internal facade sharing its
actor/transaction; a facade cannot open a connection.

* `KnowledgeEntity`, `KnowledgeEntityType`, `KnowledgeAlias`,
  `KnowledgeRelation`, `KnowledgeRelationType` contain the fields above.
  Snapshots add opaque `BlockStoreRevision`; caller-supplied revisions are not
  persisted as authority. `KnowledgeEntityPatch` changes label/description/known
  properties without replacing unknown fields; aliases are separately identified.
* `KnowledgeStore`: `createEntity(_:expectedVaultRevision:operationID:)`,
  `loadEntity(id:)`, `searchEntities(query:limit:)`,
  `updateEntity(id:patch:expected:expectedVaultRevision:operationID:)`,
  `addAlias(entityID:alias:expected:expectedVaultRevision:operationID:)`,
  `removeAlias(entityID:aliasID:expected:expectedVaultRevision:operationID:)`,
  `createRelation(_:expectedSource:expectedTarget:expectedVaultRevision:operationID:)`,
  `queryRelations(entityID:direction:)`, `resolveEntity(id:)`, and
  `transitionEntity(id:to:expected:expectedVaultRevision:operationID:)`.
  Entity create is create-only. Alias edits advance the owning entity revision;
  relation mutation compares relation and endpoint revisions. Relation removal
  and lifecycle operations are revision-checked tombstone/restore operations.
* `SemanticObject`, `SemanticObjectSnapshot`, `SemanticObjectPatch`,
  `SemanticAnnotation`, `SemanticLocation`, `SemanticReferent` are schema-5 domain
  values. Location is `wholeBlock(pageID:blockID:)`,
  `inline(pageID:blockID:target:)`, `entity(id:)` or `object(id:)`.
  Referent is a typed entity/object identity plus explicit resolution state.
* `SemanticStore`: `createObject(_:expectedVaultRevision:operationID:)`,
  `loadObject(id:)`, `updateObject(id:patch:expected:expectedVaultRevision:operationID:)`,
  `transitionObject(id:to:expected:expectedVaultRevision:operationID:)`,
  `loadSemanticPage(pageID:)`, and
  `saveSemanticPage(_:condition:expectedObjectRevisions:expectedEntityRevisions:expectedVaultRevision:operationID:)`.
  `SemanticPageSnapshot` contains one document snapshot and its annotation set,
  not another persisted complete document. `SemanticPageEdit` contains changed
  document/annotations and explicit object mutations. Save checks one canonical
  page revision, affected object/annotation revisions and referenced entity
  revisions, then publishes every effect in one transaction. `BlockStore.save`
  must route through the same annotation-aware preservation path on schema 5.
* `saveAnnotation(_:condition:expectedOwnerRevision:expectedReferentRevision:expectedVaultRevision:operationID:)`
  and `transitionAnnotation(id:to:expected:expectedOwnerRevision:expectedVaultRevision:operationID:)`
  support entity/object locations without a page revision. For block/inline
  locations, use the compound page operation. Mutation compares the annotation
  revision and owner revision; if owner content changes, advance its revision too.
* Queries: `occurrences(entityID:)`, `objects(pageID:)`,
  `annotations(pageID:blockID:)`, `questions(entityID:association:)` and
  `annotationsNeedingReview()` return explicit disposition and provenance.
  Search/query results are bounded with deterministic UUID tie-breaks.

Reuse `BlockStoreWriteCondition` and opaque revision values with enforced
vault/record scoping. Every mutating operation validates expected vault revision
and advances it, including membership changes, alias/relation edits and lifecycle.
Return committed record/page revisions, vault revision and operation UUID only
after COMMIT; stale revision, identity conflict, unknown type/predicate, missing
reference, invalid range, unsupported capability/payload and lease loss are
explicit domain errors. Query references return live/tombstoned/unresolved values;
missing lookup has an explicit not-found outcome. No sequential-call transaction
is implied. Multi-record changes rollback entirely on any failed check. Reuse
operation evidence/idempotency mechanisms rather than acknowledging cancelled
writes as uncommitted after successful publication.

Leases, admission/draining, quiescence and synchronous publication checks apply
inside the owning actor transaction and immediately before COMMIT. Editor local
revision counters remain separate from canonical page concurrency tokens.

## Lifecycle, anchoring and identity-safe copying

Knowledge entity/object deletion initially means reversible tombstone transition
of the retained canonical row. Do not physical-purge these records in KNOW02/03.
Aliases, relations, annotations and object/entity links remain preserved; queries
report tombstoned endpoints and ordinary edits to tombstoned records reject until
explicit restoration. Align generic tombstone kind handling with existing
page/source tombstones without reusing their UUIDs or deletion policies.
Removing one question annotation/classification does not delete its semantic
object or nested entity annotations; object tombstoning is a separate operation.
Removing an annotation preserves its UUID, referent and evidence with explicit
deleted annotation disposition.

Anchor disposition (`resolved`, `stale`, `deleted`) describes the location.
Referent disposition (`live`, `tombstoned`, `unresolved`) describes the linked
identity independently. A valid text anchor may refer to a tombstoned entity.
For inline locations reuse version-1 UTF-16 half-open offsets, explicit edge
affinities, exact quote, bounded 64-character prefix/suffix and revision digest.
Reject surrogate/combining/emoji interior boundaries; preserve Unicode sequences.
Whole-block location needs no offsets but retains block identity and revision.

Apply the [editor transformation matrix](block-editor.md#deferred-inline-annotation-contract):
exact before-range shifts, edge affinity, verified interior insertions, unchanged
formatting/moves, wholly contained split remaps and exact merge offsets retain
identity. Crossing splits and intersecting replacements become stale with original
evidence; removed blocks become deleted. Word matching or approximate offsets
never grant reattachment. Undo/redo restore coherent text and annotation snapshots
under a new canonical revision; failure publishes neither. Unknown fields survive
all transformations. A whole-block annotation remains resolved through supported
text edits while inline anchors follow the range rules.

Page/block duplication allocates fresh page/block/annotation IDs. Entity referents
remain the same UUIDs. Anchored semantic objects are copied to fresh object IDs
with copied-from provenance; links to the same entities remain. Nonanchored external
object references retain their object IDs. Never duplicate a canonical entity
because its occurrence was copied. Explicit identity maps cover every copied ID;
ambiguous or unsupported target/designation rules retain unresolved provenance.
Imports into an empty vault may preserve reviewed IDs; imports into an occupied
vault require create-only checks or explicit expected revisions. Conflicting
UUID/content pairs become preserved conflicts or explicit remaps, never overwrite
by label. No automatic entity/object creation from semantic strings or page text.

## Schema and capability progression

KNOW02 creates schema 4 requiring deterministic set
`["canonicalKnowledgeV1", "canonicalMetadataV1"]`. KNOW03 creates schema 5 requiring
`["canonicalKnowledgeV1", "canonicalMetadataV1", "semanticAnnotationsV1"]`.
The nested manifest `storage.schemaVersion`, `PRAGMA user_version`, vault UUID and
database required-capability set must agree before writable admission. Unknown or
missing required capabilities and unsupported payload versions deny writes before
schema changes or publication. Schemas 6, 7, 8, 9 and 10 are admitted in production; schema 7 adds `entityPropertiesV1`, schema 8 adds `entityRelationshipsV1`, schema 9 adds `entityPropertyTemplatesV1` and schema 10 adds `sourceEntityAssociationsV1`. Schema 6 keeps the schema-5 semantic tables and adds vault-owned organisation tables under `organisationV1`. Schema 5 is not upgraded on open. Historical schemas reject without mutation.

Schema 3's singular `vault_state.capability = canonicalMetadataV1` retains its
meaning. Schema 4 adds an explicitly versioned `required_capabilities` set and
keeps the legacy authority field for metadata authority; schema-4/5 readers validate
both. Sets reject duplicates and malformed values and encode sorted keys.
Capability presence denotes actually implemented preservation/writes, not a promise.
No schema-4 semantic tables or semantic feature activation is assumed by KNOW02;
KNOW03's new relational authority therefore requires schema 5.

Production initializes fresh schema 10 directly. Schema 6 remains readable/writable through its existing APIs; typed properties require the explicit revision-checked 6→7 upgrade. Opening never upgrades authority. Historical schema 1–5 upgrade routes
are retired by STOR02B–STOR03; no automatic or explicit historical migration is
supported. Internal fresh constructors provide test isolation only. Opening never
reinterprets old Wiki/source files as canonical authority.

Schema 5 transfers existing document-extension annotations once into independent
records with their original UUIDs, exact anchors/dispositions and unknown JSON.
The canonical document extension no longer stores a second annotation collection;
load/export projections may reconstruct it from committed records. Unsupported
legacy designations/targets remain explicit unresolved preservation records.
No entity UUIDs are inferred from spellings and no question objects are inferred
from `BlockMetadata.semantic`. Payload required-feature negotiation must prevent
older clients from editing a reconstructed schema-5 projection they cannot preserve.

Consistent backup includes all knowledge/semantic records in the same SQLite
snapshot plus existing owned bytes/preservation inventories. Database-only copies
remain incomplete vault archives. Future encryption must protect these records,
DB/WAL/SHM, staging, backups, exports and recovery along with existing surfaces;
session locking provides no at-rest encryption or transport delivery guarantee.

## Implementation acceptance and handoff

KNOW02 must test independent person/place/concept creation; equal labels/different
UUIDs; alias disambiguation; rename-stable relations; save/reopen; unknown required
type/payload rejection; stale writes; tombstone/restore reference retention;
injected transaction rollback; schema-3 rejection without mutation; capability
mismatch; and unchanged page/source operations. Domain agent owns models/protocols;
storage agent owns SQL/admission/transactions; fixtures agent uses agreed APIs.

KNOW03 must exercise The Napoleonic Wars page with one unanswered Question object,
Napoleon Bonaparte Person, Russia Place, whole-question block anchor and two inline
entity occurrences. Verify reopen durability, rename/move/style stability, before-
range edits, ambiguous replacement staleness, independent classification removal,
occurrence queries and compound rollback. Add overlapping/nested/identical ranges,
Unicode, affinity, split/merge, block/page deletion, undo/redo, duplication,
legacy-transfer/opaque preservation and schema-4 compatibility cases. Anchoring
agent owns edit/session algorithms; semantic agent owns model/SQL; fixtures agent
must not invent interfaces or schema. Storage-boundary author/reviewer procedure is
mandatory when these implementations change canonical access.

STOR02B receives the table families, protocols, required capabilities, revision
checks, retained tombstone/unresolved obligations and annotation authority transfer
above. Production migration/admission, native integration, real device/accessibility,
linked-source availability, process/power-loss and complete-archive acceptance
remain separate gates. No AI extraction, inference, answer generation, embeddings,
graph UI, tagging UI or additional concrete types is authorized.

## Typed entity properties (ENT.01)

`EntityPropertyDefinition` is a reusable vault-owned UUID with a normalized unique
label key, preserved display spelling, scalar kind, one/many cardinality, order,
timestamps and retirement state. `SQLiteBlockStore` owns definitions and assignments;
Pages and Sources retain their existing identities, tables and lifecycle.
`creativeWork` (Creative Work) is the sole added version-1 entity registry key.

`savePropertyDefinition` compares definition and vault revisions. Populated kinds
and cardinality cannot change implicitly. Retiring hides a definition from normal
reuse while preserving its values; existing values may remain or be removed.
There is no hard-delete API for definitions. `savePropertyValues` atomically replaces
one entity's ordered assignments, retains supplied assignment UUIDs, and compares
entity and vault revisions. Omitted assignments become unset; no placeholder row is
stored. Tombstoned entities retain facts and reject mutations. Definition UUIDs and
entity FKs are vault-local; SQL shape and cardinality constraints supplement typed
persistence validation. Operation IDs and owner revisions publish in one transaction.

Scalar kinds are text (including empty text), finite number, boolean, absolute
HTTP(S) URL with host, and Gregorian date. Dates preserve year/month/day granularity
as separate nullable integer components without an implicit timezone or invented day.
Model `validate` methods must also run after Codable decoding at persistence boundaries.
See [property tests](../../Tests/VaultCoreTests/EntityPropertySQLiteTests.swift).

`FileVaultRepository.upgradeEntityProperties` is explicit and local. Quiesce and
retire the existing repository before invoking it with the current session lease
and expected vault revision, then reopen using the returned manifest. SQLite DDL,
capabilities, schema version and vault revision commit atomically. The selected
`VaultContentStore` conditionally publishes the manifest afterward. These two
resources are not a global transaction: interrupted manifest publication leaves a
preserved DB7/manifest6 mismatch that ordinary opening rejects.
`resumeEntityPropertiesUpgrade` validates the same vault's schema-7 database and
logical integrity before retrying manifest publication. It does not recreate data.
Schemas 1–5 remain unsupported and have no upgrade route; no cloud action occurs.

## Directed entity properties (ENT.02)

Schema 8 adds `entityReference` to reusable property definitions and stores each
assertion once in `entity_property_relationships`. Stable edge UUIDs identify
(definition, source entity, target entity); uniqueness rejects duplicate facts.
Forward and inverse queries return the same canonical snapshot. Incoming editing
resolves the source/target direction inside the mutation API, never by writing a
reciprocal row. Labels use the definition's display label and optional custom inverse
label, falling back to `Incoming: <label>`. Optional source/target type-key lists
guide the inspector and show mismatches; they are advisory and never reject an
explicit assertion. Changing these hints never rewrites existing edges.

Relationship presentation is optional definition-scoped data under the
`entityPropertyPresentation` UUID map in `vault_state.extensions`, atomically saved
with the definition and vault revisions by the same SQLite actor. The whole map
shares the existing 256 KiB optional vault-metadata bound with other extension keys;
exceeding it rolls back the complete edit. Unknown fields in each presentation and
unrelated vault extensions survive known-field edits. Scalar definitions reject
relationship presentation; changing a reference definition to a scalar rejects if
unknown presentation fields would be lost. Existing schema-8 databases without presentation remain
valid, and schema 7 continues to treat this namespace as unknown optional data.
This adds no schema migration, capability, canonical edge copy or I/O exception.

`createPropertyRelationship` checks the definition, both endpoint revisions, vault
revision and operation UUID in the canonical actor transaction. One/many cardinality
limits outgoing targets per source; incoming fan-in is unrestricted. Self-links are
permitted. SQL triggers enforce kind, live endpoints, retirement and cardinality;
both traversal directions are indexed and ordered deterministically. Removal uses
the canonical edge ID and expected edge, endpoint and vault revisions from either
view. Tombstoning retains facts; no endpoint or definition purge can orphan an edge.
Renaming definitions changes presentation without changing edge identity.

The explicit `upgradeEntityRelationshipSchema` / `upgradeEntityRelationships` path
upgrades supported schema 7 to 8. A schema-6 vault first uses the existing 6→7 path.
The schema-8 transaction rebuilds only property tables to expand their kind
constraint, preserves scalar assignment/definition UUIDs and order (including facts
on tombstoned entities), installs relationship constraints, then publishes the new
capabilities and revision. Foreign keys remain enabled. Conditional manifest
publication and explicit `resumeEntityRelationshipsUpgrade` follow the same
preserved-mismatch protocol as ENT.01. Ordinary open never migrates. Schemas 1–5
remain unsupported. Page mentions and semantic annotations are not asserted edges.


## Type-aware property templates (ENT.04)

Schema 9 adds `entityPropertyTemplatesV1`. `entity_property_templates` retains one
opaque revision per configured type, including an explicitly saved empty template;
`entity_property_template_entries` references existing property-definition UUIDs in
normalized order. Only the five registered entity type keys are supported. Every
entry is an optional suggestion; no template edit assigns a value, asserts an edge,
changes an entity revision or creates an entity. Each type permits at most 16
entries, independently of the number of existing definitions, values and edges.

`loadPropertyTemplate` returns ordered definition IDs and an optional revision
(nil means never configured). `savePropertyTemplate` atomically replaces the ordered
selection after checking template/vault revisions and operation identity. Duplicate,
missing, foreign-vault and newly retired definitions reject without partial writes.
Retirement preserves stored selections and facts; previously retained retired IDs
may be reordered or removed but cannot be re-added. Active suggestions resolve the
same reusable definition UUID, so renames do not detach them. Existing optional
metadata scopes remain unchanged.

Template authority begins at schema 9. Supported older vaults keep their existing APIs;
normal open never upgrades. Explicit `upgradeEntityPropertyTemplates` performs the
8→9 transition and conditionally publishes the manifest after the database commit.
`resumeEntityPropertyTemplatesUpgrade` retries interrupted manifest publication;
a mismatched declaration rejects ordinary admission. The transition registers any
missing known type descriptors without creating entities or overwriting descriptors.
SQLite backup includes both tables and admission/archive validation checks their
foreign keys, registered types, revisions, definition ownership, order and cap.
See [template tests](../../Tests/VaultCoreTests/EntityPropertyTemplateTests.swift)
for preservation, rollback, admission, migration and archive scenarios.

The native template manager is reachable from the Knowledge Entities catalogue even
when empty and from entity property inspectors. Its type picker covers all five
registered keys. Suggestions initially show four unused active definitions, with
separate disclosure from existing values/edges; selecting one opens the existing
property editor without writing a fact. Management uses explicit saves and retains
retired rows until explicitly removed. Selection/session/request guards discard
late reads and reject stale saves on type changes, navigation, lock and vault switch.


## Explicit Source–entity associations (ENT.05)

A Source identifies preserved or linked evidence; a Knowledge Entity identifies a
thing. Their UUIDs and lifecycles remain independent. Schema 10 introduces
`sourceEntityAssociationsV1` and one canonical `source_entity_associations` row per
explicit assertion, with a stable UUID/revision/time, Source/entity RESTRICT foreign
keys and uniqueness of `(sourceID, entityID, role)`. `representsWork` targets only
the registered `creativeWork` type; `aboutEntity` accepts all five registered types.
Many Sources may identify one work, and one Source may represent several works or
concern several subjects. No inverse entity edge, automatic inference, new type,
Source replacement or Page conversion is created.

`linkSource` checks Source, entity and vault revisions plus operation identity in
the existing admitted SQLite actor transaction. It requires a nontrashed Source
and a live registered entity, validates the role and rejects duplicates. Explicit
`unlinkSourceAssociation` checks association and endpoint revisions and returns the
removed snapshot. It may remove retained links to inactive endpoints. Neither
operation changes endpoint content revisions, metadata, originals, bookmarks,
checksums, Source publication receipts, Page links or search/AI/embedding scheduling.

Both query directions return the same association identity in deterministic
creation-time/UUID order, with bounded limit/offset pagination. Pages can shift
under concurrent edits; reload after mutation. Consumers resolve endpoint lifecycle
and metadata through existing canonical snapshots without original-byte reads.
An association never means that original bytes are currently verified or available.
Source Trash/restore and entity tombstoning retain links. Source purge rejects any
retained association with an explicit unlink path before mutation; it never cascades
links or deletes preserved original bytes.

Fresh creation initializes schema 10. `upgradeSourceEntityAssociations` explicitly
moves supported schema 9 to 10; interrupted conditional manifest publication requires
`resumeSourceEntityAssociationsUpgrade`. Opening never upgrades and older supported
APIs remain available. Admission/archive validation covers roles, IDs, revisions,
finite timestamps, foreign keys and endpoint type semantics while permitting
retained inactive endpoints. SQLite backup includes the table automatically.
See [association tests](../../Tests/VaultCoreTests/SourceEntityAssociationTests.swift).

The Source inspector links existing entities with an explicit role and confirmation
of the add action; unlinking requires confirmation. Entity properties show grouped
Source links and open the existing native reader only on an explicit action. Reads
show retained inactive endpoints and metadata-only availability, never a new claim
that originals are verified. Both views page bounded results and invalidate state
on selection, session, lock and vault changes. The facade checks endpoint revisions
as well as the collection revision: Source Trash can advance only the Source
revision. No reader, availability request, scan or AI work is started by listing links.
