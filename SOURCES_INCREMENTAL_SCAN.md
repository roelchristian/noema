# SRC.P4: incremental source scan contract and validation

Base: integrated `main` at `7764d963b1fc5cd4064259c27e37467b76f7af36` (D02.7 and Sources presentation changes).

## Data flow and consumers

Previously, `FileVaultRepository.scan()` decoded each source metadata file, read the original, verified owned-original SHA-256, and extracted text on every refresh. Source imports already produced loaded records. `SQLiteSearchIndex.reconcile()` compared only metadata revisions, so changed linked text with unchanged metadata could retain old search content.

The Sources table, inspector metadata, sorting, LCC edits and context menus need metadata. Search indexing, AI summaries/naming/classification/page generation, and the selected textual preview need extracted content. `SourceReader` and explicit availability checks need original bytes and continue using the existing authorized original reader. PDF AI extraction still verifies and reads the PDF original.

## Identity, eligibility and invalidation

Each repository owns a UUID-keyed, memory-only `SourceSnapshotCache`. An entry contains the exact metadata bytes, the loaded record, its extracted-text revision and coordinated original-file change evidence. The repository is bound to its normalized root, manifest vault ID and lease/session generation. Nothing is shared between repositories, vaults or sessions.

`VaultContentStore.changeToken` is optional. Its default returns nil, which causes conservative reloads. The plaintext adapter collects device/inode, size, and nanosecond mtime/ctime inside its existing security scope and read coordination, checking path safety, read accessibility, iCloud download state and unresolved conflicts. The gated wrapper validates before and after the provider call. No original byte reads move outside the storage boundary.

Owned originals are eligible for reuse only when both metadata bytes and nonnil change tokens match. Tokens are checked again after materialization before insertion. Changed metadata, changed/replaced originals, missing or inaccessible evidence, deletion, rename/LCC edits and restore evict entries. Directory enumeration prunes deleted IDs. Linked sources reload conservatively because the selected vault store cannot attest external bookmark-backed originals.

Filesystem evidence detects ordinary changes; it is not cryptographic proof. The actual checksum is verified on materialization and forced verification. A provider returning stale evidence may permit a previously verified record to be reused until the next byte-verifying operation, which rejects corruption. Tests exercise this explicitly.

## Loading and integrity semantics

- Existing `scan()` remains a complete-content API, now incremental.
- `scanSources()` and `scan(sourceLoading: .metadataOnly)` expose metadata with `contentState == .notLoaded`; an empty string never silently means loaded content. These records show “Not verified,” rather than “Available.”
- `loadSource(id:)` discovers current metadata and loads only that source. `.loaded` includes a genuinely empty text or binary original. `.unavailable` carries no old plaintext.
- `scan(sourceLoading: .verifyOriginals)` and `loadSource(id:verifyOriginal:true)` bypass cache reuse.
- `ScanBatch.sourceVerification` explicitly distinguishes not verified, verified in this scan, reused previously verified, and externally linked content read. It is transient evidence, never written to source metadata.
- Original checksum failures remain rejected/omitted from complete scans with recovery notices. iCloud-unavailable records retain metadata but expose no content. Linked-file failures retain an unavailable metadata record. Cancellation or access rejection clears the scan cache and throws.

Cold AppModel refresh publishes metadata before full materialization. Populated sessions keep complete records until a scan commits. Selection refreshes its preview only when selected content changes, and clears sensitive inspector/preview state when content is unavailable or removed. AI page creation carries a materialized source through the existing stale-body comparison. Cold LCC and naming actions materialize/reconcile complete records instead of replacing loaded content with placeholders.

## Search reconciliation and rebuild

Source index revisions include metadata plus an extracted-text fingerprint, fixing changed linked content. Scans compute fingerprints once and reuse them. A metadata-only batch can retain an unchanged indexed record when the repository supplies a matching content revision. `sourcesRequiringContent(in:)` identifies missing/changed content, including all sources for a new index. Reconciliation refuses to overwrite source entries with `notLoaded` placeholders and removes unavailable source content from the index.

A complete/forced scan rebuilds a new index. Source metadata/original persistence formats are unchanged. Existing index records decode as loaded when the added content-state field is absent; the revision version causes a compatible local source reindex. No new plaintext cache/database is persisted.

## Session and concurrency guarantees

A small gate invalidation hook discards session-bound memory synchronously as access leaves the matching open session, without changing the D02 state machine, admission or drain rules. Cache retirement is terminal and mutex-protected, so a previously admitted operation cannot refill it during lock/close/switch. Callbacks only discard memory and never call the gate or perform I/O. Repository teardown unregisters the hook.

Cached paths still validate access; scan/lazy-load completion checks cancellation and the lease again. Existing AppModel completion tickets guard UI/index publication. Lock/unlock creates fresh repositories and leases. Ordinary reference discard is not cryptographic erasure or guaranteed memory zeroization. Already-admitted D02 operations retain their existing drain semantics.

An aborted lock conservatively leaves the old repository cache retired until repository recreation. Linked originals and providers without reliable evidence remain uncached. Coordinated attribute checks and metadata reads still occur on eligible warm scans.

## Verification

Deterministic counting-provider tests cover metadata-only zero reads, targeted loading, genuinely empty content, unchanged refresh, forced verification/availability reads, metadata/content changes, source delete/restore, nil evidence, linked source changes/failures, unavailable iCloud content, checksum failures, stale evidence, index reconciliation/rebuild, cancellation and delayed lock/unlock/close/switch. AppModel tests cover metadata selection/LCC actions, selected preview materialization, linked preview updates and removal of stale availability/inspector text. Existing D02, repository, editor, search and Sources tests remain in the full suite.

Payload-free Instruments Points of Interest: `Source Scan`, `Source Original Read`, `Source Text Extraction`, `Source Cache Reuse`. No paths, titles, UUIDs or contents are logged.

Read-count evidence for 16 synthetic text sources:

| Operation | Original reads |
| --- | ---: |
| Before: 10 ordinary scans (implementation audit) | 160 |
| After: cold complete scan | 16 |
| After: 10 eligible unchanged scans | 0 |
| After: 10 forced-verification scans | 160 |

A debug suite benchmark measured a cold scan at 0.154 s, 10 warm scans at 0.765 s, and 10 forced-verification scans at 1.566 s. The benchmark runs alongside tests; timing is synthetic data preparation, not app navigation latency or scrolling FPS. The forced path is a current-code comparison, not a measured pre-change wall-time baseline. Run `SOURCES_SCAN_BENCHMARK=1 ./scripts/test.sh --filter sixteenSourceReadCountBenchmark` to reproduce read counts and obtain local timings.

Validation: all 194 tests in 16 suites pass with the benchmark enabled. Debug app packaging/signing, strict signature verification and the storage boundary selftest are checked before PR publication. Native UI validation is omitted at the user's request.

Independent access-control reviewer: no remaining actionable findings after the cold-action, availability and selected-preview fixes. Reviewer inspected code/tests; final test/build execution is performed by the implementation owner.
