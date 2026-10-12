# Canonical knowledge identities and semantic annotations (KNOW01)

Status: approved architectural contract with independent disposition. No runtime,
production schema change, data migration or new I/O exception is enacted here.

## Context

STOR02A merged at `a303881` implements fresh schema-3 canonical staging and
repository admission, bounded opaque payloads and document-extension annotation
transforms. Schema 3 is durably persisted even though wider production acceptance
remains incomplete. The STOR.01 decision to defer an entity catalogue scoped that
stage; KNOW01 now supplies its explicit consumer, domain boundaries and versioned
handoff rather than silently changing schema 3 or treating page titles as entities.

## Decision

Adopt the [knowledge model contract](../contracts/knowledge-model.md) as the
KNOW02/03 interface and lifecycle authority. Canonical entities initially comprise
registered string types `person`, `place`, `concept`; their UUIDs are independent
of spellings and pages. Distinct registered semantic objects initially comprise
`question` and `definition`. Independent annotations connect whole blocks, inline
ranges, entities or semantic objects to typed referents; identical, nested and
crossing ranges are valid. Directed `relatedTo` entity relationships are explicit,
revision-checked records; co-occurrence does not imply a factual relation.

Preserve `SQLiteBlockStore` as the sole canonical actor/connection/transaction
owner, the existing domain document as content authority and the current byte,
lease, quiescence and publication boundaries. Retain knowledge/object rows as
reversible tombstones initially, with independent location and referent states.
Use existing payload/anchor mechanisms and preserve unknown optional JSON at every
scope; unknown required semantics fail closed.

KNOW02 introduces schema 4 and required `canonicalKnowledgeV1` in addition to
`canonicalMetadataV1`. KNOW03 introduces schema 5 and adds
`semanticAnnotationsV1`, because their sequential merges may durably persist
schema 4 before semantic tables exist. Preserve schema-3 singular metadata
capability; later schemas add a versioned validated required-capability set.
Manifest/database/UUID/version agreement is a writable gate. Fresh verified staging
is permitted by subsequent implementation stages; conversion requires separate
explicit verified staging, manifest-last publication and recovery evidence.
Opening never converts an existing authority. Production migration remains out of
scope. Legacy extension annotations transfer once with preserved identities and
opaque fields; no second canonical annotation collection survives that cutover.

## Alternatives and consequences

A universal page/entity table would confuse content containment with knowledge
identity. Closed three-case entity types would force identity/schema restructuring.
Rich formatting runs cannot represent independent crossing ranges safely. A second
SQLite owner would bypass existing transactional and lease protections. Expanding
persisted schema 3 or 4 in place would permit older writers to discard required
knowledge data. The additional forward schema step and conservative tombstones
cost implementation effort/storage while preserving compatibility and references.

## Gates and dispositions

KNOW01 requires independent architectural approval. KNOW02 and KNOW03 each require
an integration PR merged before the next stage starts, with the focused acceptance
matrix in the contract and the [storage review procedure](../contracts/storage-boundary.md#required-author-and-reviewer-disposition).
Knowledge persistence completion does not close production-admission, migration,
archive, native/accessibility, linked-source or crash/power-loss acceptance gaps.
AI and comprehensive tagging UI remain excluded.

Author `/root/know01_architect`: approves this architectural contract only; no
runtime/schema/data or canonical I/O access was changed in KNOW01.

Independent reviewer `/root/know01_review`: APPROVE architectural contract; no
runtime/storage I/O change in KNOW01. Separate changed-code storage reviews and
acceptance remain mandatory for KNOW02/03. Reviewed schema-4→5 capability evolution,
retained schema-3 authority, owner/referent dispositions, opaque legacy transfer
and nonpage owner revision checks; no material architectural disagreement remains.
