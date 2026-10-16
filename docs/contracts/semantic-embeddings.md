# Semantic embedding infrastructure — SEM.EMB

## Contract checkpoint and ownership

VaultCore provides validated provider-neutral model/vector/chunk/generation contracts,
deterministic chunking, portable Float32/cosine primitives and actor-owned SQLite
persistence/retrieval. OpenAI preferences are independent of generative settings;
Current Vault reports exact descriptor/chunker compatibility from persisted generations.
AppModel constructs the semantic projection beside FTS during admitted open/unlock;
semantic failures leave canonical editing and lexical search available.

Both native sentence embeddings and a restricted OpenAI request adapter implement the
provider path. `EmbeddingWorkProcessor` registers before coordinator binding for the
selected backend. Initial inventory is a baseline, not historical admission. Native
processing uses committed snapshots; cloud incremental processing requires a separate
session-only new/changed-content disclosure, native authentication and exact-request
capabilities. Existing enrichment approval never grants embedding permission. No query
or historical submission follows model/provider selection. AI.ENR is not a dependency.
Historical admission uses explicitly captured batch membership. Persistent queue controls retain scheduling intent separately from live execution authority; integrated search remains a separate gate.

`blocks.sqlite` remains the sole canonical Page and Source authority. Embeddings
are disposable, device-local projections. The `SQLiteEmbeddingIndex` actor
owns its SQL connection and atomic document replacement in `semantic.sqlite`, beside
`search.sqlite` under the existing Application Support `KnowledgeVault/<vault UUID>`
root. Construction must use the app's admitted local-storage composition; neither a
portable vault path nor a caller-selected canonical database is an embedding path.
FTS5 remains available if the semantic projection is absent, damaged or incompatible.
The two derived-directory/SQLite-open exceptions are owned and reviewed under the
[storage boundary](storage-boundary.md#derived-semantic-index-ownership). No second
canonical writer is introduced.

VaultCore owns typed model, vector, entity, chunk, generation and provider contracts,
chunking, derived storage and retrieval. ExternalAI owns cloud credential access,
request capabilities, endpoint allowlists and transport. The application owns vault
provider selection, consent, snapshots, settings, status and hybrid search composition.
AppleSentenceEmbeddingProvider uses Natural Language sentence embeddings behind the
provider abstraction. Foundation Models is not an embedding API.

## Identity and compatibility

A model descriptor identifies provider, model, actual revision, dimensions and bounded
input/batch limits. Vectors must have the declared dimension, finite Float32 values
and a nonzero norm. `EmbeddingVectorMath.swift` encodes exactly four little-endian
bytes per component and rejects malformed BLOB lengths or invalid decoded vectors.
Cosine accumulation uses Double to retain finite extreme/subnormal Float32 inputs. Generation compatibility requires the full descriptor and chunker
version to match. Query and document vectors must belong to that same vector space;
equal dimensions alone are insufficient. OpenAI configuration `matchesSelection(of:)`
rejects a different provider, model ID or dimension; a match is only a necessary
selection check and cannot establish revision, chunker or vault compatibility. Each generation belongs to one vault UUID.
A record binds that generation to a Page or Source UUID, opaque canonical revision,
stable structural chunk identity, ordinal and input fingerprint. Fingerprints and
revisions are technical metadata, never copies of document text.

`EmbeddingChunker` accepts caller-supplied committed block/extracted-source text.
Page chunks use block UUID/segment identities and exclude complete subtrees marked
`aiGenerated`. Source chunks follow paragraph boundaries, normalize CRLF as a single
line ending and use positional paragraph/segment identities. Both preserve graphemes,
apply the descriptor UTF-8 byte bound with modest overlap, and reject an oversized
individual grapheme rather than dropping text. Providers must additionally enforce
model tokenizer limits. Retain unchanged chunks only when fingerprints and generation
match; source paragraph identities are not stable across unrelated paragraph insertion. Do not persist full source text solely
for vector storage. Atomic replacement and deletion must validate the live lease,
provider epoch, current entity revision and generation at publication. Interruption
must leave either the prior valid revision or an explicitly partial generation.
Generations may coexist for rebuilds but must never mix in one similarity ranking.

## Authority and lifecycle

Embedding document changes, historical backfill and query submission have distinct
scopes. Scope declarations and policy resolvers are contracts, not mintable external
request permission. Existing summary/enrichment grants confer no embedding authority.
ExternalAI must extend D02A with issuer-bound embedding capabilities before any cloud
provider is installed. They must bind the live vault/session lease, provider/model
configuration epoch, exact input, operation scope and, for history, durable batch ID.
Recheck authority before dispatch and after suspension, and before vector publication.
Revocation, locking, switching, cancellation and model changes reject stale work.
No fallback to a different provider is allowed.

The existing `AIProcessingCoordinator` and `SQLiteAIWorkLedger` remain the only work
scheduler and durable retry ledger. The embedding processor registers before
binding, consume post-commit events, exclude AI publications and preserve the first
inventory baseline rule. Saving canonical content must succeed independently of
embedding work. When indexes are integrated, a preference change must invalidate compatibility;
it must never admit old content. Historical indexing requires explicit Pages/Sources selection, a durable batch
identity and fresh cloud authority. Pause retains resumable work; cancellation cannot
claim an already transmitted request was unbilled.

Semantic query retrieval must use compatible generations, current live revisions and
search scope, deduplicate chunks by document and merge lexical results deterministically
with reciprocal rank fusion while preserving strong title/alias matches. Cloud queries
require separate query authority, debounce and cancellation. Quick Open remains lexical.

## Privacy and implementation gates

The semantic database is plaintext application-local derived data; session
locking is access control, not encryption. Cloud embedding submits original text and
may incur usage charges. Model selection alone is neither consent nor a cost estimate.
No embedding operation may publish titles, summaries, classifications or page bodies.

Before SEM.EMB02, apply the author and independent reviewer procedure in
[storage-boundary.md](storage-boundary.md), including all constructor/caller routing,
lease validation and pre-publication checks; scanner success alone is insufficient.
Embedding-specific D02A scopes are implemented and adversarially tested independently
of enrichment grants.
SEM.EMB04–08 require real provider/storage integration, persisted backfill/queue state,
search regression, native regression and measured large-vault performance acceptance.
Standing device, accessibility and crash-durability gaps remain unchanged.

## Provider behavior and remaining integration gates

`AppleSentenceEmbeddingProvider` confines its Natural Language model to an actor,
records actual language/model revision/dimension, and rejects unavailable language,
invalid vectors, revoked authority and cancellation. Its conservative input-v1 policy
bounds inputs to 1,024 UTF-8 bytes, 128 NLTokenizer words and 16 items per batch. The
incremental chunk admission adapter must honor both word and byte limits. Actual
system-model availability and retrieval quality remain device acceptance work.

`ExternalAIEmbeddingAuthorizer` mints opaque issuer/epoch/exact-request capabilities
only after explicit document, query or historical-batch consent and existing native
session authentication. Tokens bind ordered input digest, full model, entity revision,
batch identity and complete vault lease. Replay, scope substitution, credential change,
session revocation and issuer invalidation reject. `OpenAIEmbeddingProvider` uses only
POST `https://api.openai.com/v1/embeddings`, existing credential broker and bounded
nonredirecting transport. Dispatch serializes gate/session/issuer/credential validation;
responses validate model, count, indices, dimensions and finite nonzero vectors. One
bounded transient retry remains inside the same exact request. Publication requires a
completed response and live authority; text, consent and tokens are never persisted.
The request schema follows the [official embeddings API](https://developers.openai.com/api/reference/resources/embeddings/methods/create).

OpenAI inputs are conservatively capped at one item and 8,000 UTF-8 bytes. The recorded
revision identifies the API/input contract; provider aliases do not expose immutable
weight revisions. Numeric usage is exposed separately from vector validation; activity
history integration is pending, and requestCount represents logical attempts rather
than a provider billing guarantee. No live API-key test or cost estimate is claimed.

SEM.EMB04A provides the canonical-owned in-process publication barrier used by the
embedding processor. Every `SQLiteBlockStore` constructor resolves a shared database
domain; write transactions invalidate its opaque permits before mutation and hold that
domain through COMMIT/rollback. Issuance verifies Page/Source revision and live lifecycle
under the same domain. Failed writes and connection retirement conservatively invalidate
permits too. `EmbeddingPublicationAuthority` binds an exact generation and admitted lease;
synchronous session invalidation retires it. The permit-bearing index replacement holds
canonical-domain then authority locks through derived COMMIT. Neither lock spans an await
or invokes the access gate. Gate invalidation can wait for that short synchronous commit.
Provider/model/credential/consent changes synchronously retire that same authority through
`ExternalAIService` mutation paths and application policy retirement. Stale vault callbacks
reject before touching the active vault's authority. `EmbeddingRequestExecutor` requires an
embedding-specific exact-request approval callback and exposes completed request evidence,
without a vectors-only provider conformance. Evidence retains issuer/session cancellation
registrations through the final index actor hop; session credential retirement propagates to
the same storage barrier even after network completion. Each input request consumes fresh
consent and a fresh capability, including each selected historical chunk. This adapter never
creates document, historical or query approval, and is used by the registered incremental processor only after distinct document approval. The older predicate-only index primitive is
insufficient for processor publication. Arbitrary external SQLite writers are outside
this in-process protocol. Linked-original revalidation detects observed file changes,
but cannot make an externally mutable file atomic with SQLite publication.

The installed processor uses this barrier: an asynchronous post-commit event or revision
read followed by a separate SQLite COMMIT remains insufficient. Canonical-owned revision permits must synchronize with
canonical COMMIT and span the derived COMMIT; their constructor/helper routing needs
independent storage review. Linked source bytes also need current snapshot validation.
Deletion cleanup runs explicitly across generations, since the coordinator cancels
removed jobs without executing a processor. Startup reconciliation removes stale
projection entries without admitting historical cloud work. Hybrid search, large-vault
measurements and standing native/device acceptance remain separate gates.

## Incremental lifecycle and durable completion (SEM.EMB04)

Schema 3 of the derived semantic database atomically records document completion with
vector replacement, including empty documents. Each successful provider batch first
publishes a guarded partial checkpoint with full work revision, input fingerprint and
partial chunk count. Checkpoints permit exact chunk reuse after interruption; they do
not count as completed documents. Final publication clears the partial checkpoint. Metadata contains canonical identity,
full work revision (including Source original hash when observed), input fingerprint
and validated chunk count, never input text or capability. Exact schema-1 and schema-2 migrations
validate and preserve existing vectors/completions without inventing progress. Chunk/document/
generation removal retires completion and checkpoint evidence consistently; malformed counts or identities
fail closed. `SQLiteBlockStore` remains the sole canonical SQL owner.

The processor retains every completed cloud request validator until the guarded COMMIT,
reads reuse candidates through the indexed generation/entity prefix, reuses exact compatible
chunks while advancing revision metadata, and revalidates Source originals after inference.
Per-document inference does not decode vectors owned by unrelated documents. The cloud
processing adapter preserves cancellation, classifies bounded provider/network failures
as transient scheduler failures, and keeps expired or refused permission blocked for fresh
authority rather than recording malformed-result failures. Raw request APIs retain their
ExternalAI error contract; publication evidence still revalidates after network completion. AppModel explicitly cleans removed entities across generations
and reconciles absent/stale entries on startup without inference. Unavailable semantic
storage/provider/ledger work leaves canonical saving and lexical search available.
Compatible generation declarations persist before admission, including a pause before
the first vector. Declaration stores vector-space identity only and grants no inference,
publication or completion authority; paused job identity survives reopen and fresh
session consent remains mandatory. An unpublished compatible generation stays stable
across same-session consent rebinds. Version changes cannot revive recorded
embedding jobs. Superseded binding callbacks cannot retire the active vault's authority.

Source metadata-only startup inventory cannot certify externally mutable original bytes.
Composite-revision Source completions may therefore be conservatively retired on reopen;
this does not authorize regeneration. Partial Source checkpoints with a matching canonical
revision survive as reuse candidates; fresh original extraction and exact chunk fingerprints
remain mandatory before reuse, and retained partial rows never certify completion. Linked bytes remain non-atomic with SQLite after
final revalidation. Native regression validation requires the explicit serial Extended
procedure in the [development guide](../development.md#validation-tiers-and-test-discipline)
because concurrent editor fixtures can reset a shared math renderer. Passing functional
tests do not establish device/accessibility or crash-durability acceptance. Numeric usage activity remains later integration work; queue presentation must preserve
unknown usage and cost, and no cancellation implies zero provider usage.

## Explicit historical batch foundations (SEM.EMB05)

`SQLiteAIWorkLedger` schema 2 stores batch UUID, vault, exact selected Page/Source
scopes, complete generation/model, admission state and metadata-only inventory members.
Each member has a stable coordinator job UUID. Exact replay preserves control intent;
row/payload identity disagreement and false completion reject. Schema-1 work payloads
remain readable; optional batch/disposition fields add no text, secret or capability.
Live progress reads use non-mutating snapshots, not interrupted-work recovery reads.

`AIProcessingCoordinator.admitHistorical` is the sole historical scheduling entry point.
It persists fixed member IDs before arming work, preserves attempt counts, rejects
terminal revival and never routes a batch through a generic reprocess event. Registered
historical processors ignore ordinary commit admission. Recovered historical rows do
not arm automatically; global authority changes suspend them without silently resuming.
Pause/cancel intent and a stored batch choice remain metadata, not execution authority.

`EmbeddingHistoricalBatchApproval` is transient, native-session/capability-bound and
limited to one vault, batch, complete generation and exact Page/Source selection. It
rejects document/query substitution, stale native authority and mismatched publication
barriers. Each chunk still obtains fresh exact-request consent and transport authority.
Batch invalidation retires that batch's barrier rather than an incremental processor's
or another batch's authority. Restart cannot reconstruct approval or prompt silently.

The application historical controller persists metadata-only membership before native
approval or bounded admission. It registers one historical processor per batch and
uses durable coordinator-write notifications only to reconcile metadata and admit the
next bounded group; inference, concurrency, delays and retries remain coordinator-owned.
Recovered on-device intent may resume under a fresh lease/policy barrier. Recovered
OpenAI intent remains awaiting explicit batch disclosure and fresh native authority;
background recovery never authenticates or reconstructs approval from stored rows.
Current Vault offers exact Page/Source selection and a separate cloud acknowledgement,
plus an explicit resume disclosure with immutable batch scopes. Decline and Not Now
admit no history. Metadata counts cannot establish provider token usage or charges.

Replacement generations retain earlier vectors separately. A rebuild switches the
selected processing generation only after every captured selected member has durable
completed or skipped metadata. Failed or unfinished captured batches do not activate a
replacement. Activation selects a vector space; selected scopes and captured revisions
can provide only partial current-vault coverage. An edit after the final inventory
snapshot may leave an older-revision completion or a missing document, never a fabricated
completion for the new revision. Future semantic queries must validate each document's
current canonical revision and never treat active-generation selection as coverage. Completed
replacement selection survives restart through the ledger. Historical membership does
not absorb later revisions or extend to unselected entity kinds. External original
mutation still has the linked-file atomicity limitation described above.

Application transition/recovery suites and Source recovery tests exercise SEM.EMB05
behavior with injected providers and transport; these do not establish live-provider
acceptance. Selecting a provider/model still cannot admit existing content.


## Persistent queue controls (SEM.EMB06)

The Semantic Indexing queue reads persisted incremental work and historical batch
membership without invoking recovery or inference. Compact indicators include new and
changed work; a persisted processor pause also applies to newly admitted jobs and
survives restart. Queue rows distinguish successful completion, unchanged skips,
blocked permission, unavailable inputs, failure, interruption and cancellation.

Pause and cancellation retire pending activation identities before suspension, including
activation waiting for native authentication. A retired activation cannot install a session
or resume dispatch. Stop controls record intentional work state before retiring live request
authority. Cancellation remains requested until active tasks acknowledge; restart
finishes an outstanding cancellation without dispatch. Historical resume retains the
original Page/Source selection and generation, requires fresh cloud disclosure and
native authority, and never infers consent from persisted intent. Explicit retry is
limited to eligible failures; it preserves captured membership and cannot revive
successful or cancelled work. The existing coordinator remains the only scheduler. Concurrent historical admissions
revalidate the stable job and installed timer after persistence; a stale pause cannot
suspend a replacement binding.

The work ledger's schema 3 adds only processor pause metadata in its existing
application-local database. Controls do not delete completed vectors or canonical
content. Completed and cancelled cloud work can have incurred usage; absent provider
usage/cost evidence stays unknown. Queue behavior tests use injected providers and
transport. Native accessibility/focus, live-provider behavior, linked-original
atomicity and actual crash/power-loss acceptance remain outstanding.
