# Validation

This is the standing validation contract, not an execution journal. Update a baseline,
procedure, limitation or acceptance status in place. Routine commands/outcomes belong
in the PR; full logs and screenshots belong in ignored `.local/agent-runs/`.

Reference environment: Apple Silicon, macOS 27.0, Swift 6.2.4, macOS SDK 26.2.
Prior native runs establish the domain acceptance stated below; they are not claims
that a later change has been tested. Rerun the relevant commands for each PR.

## STOR02B–STOR03 acceptance scope

The production baseline is format 2, directly initialized schema 5. Historical
Markdown/schema-1–4 vaults are intentionally unsupported. The repository demo and its
content-only checks are retired; canonical fixtures are generated in temporary roots.
Native archive APIs include committed SQLite and controlled originals/preservation,
with RecoveryStore drafts and linked originals explicitly excluded. Independent
storage review and integrated test results must be recorded in the PR; implementation
alone is not acceptance. Standing device/accessibility, process-termination, power-loss,
filesystem-failure and linked-source acceptance gaps remain open.

## Reproducible checks

Run from the repository root:

```sh
python3 scripts/check-repository-hygiene.py --selftest
python3 scripts/check-storage-boundary.py --selftest
./scripts/test.sh --skip-update
./scripts/build.sh debug
codesign --verify --deep --strict dist/noema.app
git diff --check
```

Build/test wrappers enforce storage routing. This checkout has no configured GitHub
Actions workflows; local validation must run explicitly, and remote CI execution
must not be assumed. Storage review is separately required by the
[storage contract](contracts/storage-boundary.md#required-author-and-reviewer-disposition).
Never treat a lexical scan as a semantic boundary proof.

The native suite uses temporary vaults, failure injection and editor fixtures.
The latest recorded lifecycle/recovery/preview baseline passed 247 tests in 27
suites; the earlier token full-suite run passed 244 tests in 26 suites after UI.TK06.
The upstream native-toolbar/token integration passed 284 tests in 31 suites, including
its opt-in 152-image captures. These counts describe scoped runs, not a fixed test
count or fresh evidence for a subsequent maintenance merge.
Source presence, compilation, automated passing results and device acceptance are
separate kinds of evidence. Superseded commands/timings remain in Git history.

## Editorial acceptance

[Editorial typography](contracts/block-editor.md#editorial-typography) uses native
layout tests for minimum/default/enlarged sizes, available/missing families,
light/dark fixtures, wide/narrow measures, headings, blank separators, lists,
semantic reservation and complete math-preview fit. Source-byte and serialization
checks establish presentation-only changes. Native preference-refresh tests cover
selected ranges, caret, viewport and undo/redo without registering a content edit.
Routine inspector layout validation uses eight representatives covering every page/source
tab, minimum/ideal/maximum widths and standard/increased-contrast appearances.
Routine typography integration uses eight font/size/measure/appearance representatives
(16 editor layouts including heading modes; 24 source layouts including Markdown,
HTML and plain text). The original 64 inspector and 72 editor/108 source combinations
remain in `InspectorLayoutMatrixTests` and `TypographyLayoutMatrixTests`, compiled
only in the opt-in `NoemaVisualValidationTests` target. Existing raster matrices remain
there as well. These representatives retain source-byte, serialization and selection
assertions; specialized coverage is still required when changing layout boundaries.
Benchmarks are physically isolated in the opt-in `NoemaPerformanceTests` target.
Opt-in fixture capture procedures are in [development](development.md#explicit-visual-validation).
Live VoiceOver, keyboard focus, OS Reduce Motion/contrast combinations and manual
window/sidebar/inspector resizing remain outstanding; raster fixtures do not certify
them. Long-document fixture coverage does not establish sustained typing/frame timing.

## Standing environment limits

- Restricted automation can block `NSFileCoordinator` (Cocoa error 512), pasteboard,
  security-scoped bookmarks and `iconutil`. Native macOS service access is required
  to distinguish environmental failures from product failures.
- Build packaging is ad-hoc signing, not notarization. Finder/iCloud extended
  attributes can invalidate strict signature verification after launch; check a
  fresh package or an archive extracted outside iCloud.
- Command-line packaging uses the flattened `.icns` icon; layered SVG exports are
  reproducible inputs for Icon Composer. See [brand resources](../Resources/Brand/README.md).
- Tests cover specified schedules and injected failures. They do not establish
  exhaustive timing, process-crash/power-loss durability or arbitrary uncoordinated
  filesystem behavior. Separate adapter calls are not a transaction.
- **Saved locally** acknowledges this Mac's save, without confirming iCloud upload
  or arrival on another device.

## Outstanding acceptance

- Two-Mac iCloud transport, offline concurrent edits, cloud-only placeholders,
  actual provider hydration and real `NSFileVersion` conflicts remain pending.
- End-to-end VoiceOver and OS Reduce Transparency/Reduce Motion/Increase Contrast
  combinations across all five themes (System, Midnight Iris, Forest, Amber, Rose)
  in Light and Dark remain pending.
- Native input device acceptance remains pending: real CJK candidate windows, accented dead keys, emoji input, dictation, read-mode drag selection/hyperlink activation and clipboard interoperability across applications. Synthetic `NSTextInputClient` composition and UTF-16 replacement tests do not certify OS input services.
- Native block pointer sibling reordering completed in the isolated macOS 27.0
  acceptance app on 2026-10-12: dragging Alpha below Gamma changed the page from
  Alpha/Beta/Gamma to Beta/Gamma/Alpha, subsequently displayed in the library.
  Handle selection and editor focus were observed. Live cancellation, insertion
  indicators, edge autoscrolling, multi-block dragging and pane/font/window
  transitions remain pending. Automated UUID/undo and geometry checks in
  [BlockInteractionTests](../Tests/NoemaEditorTests/BlockInteractionTests.swift) and
  [BlockGutterTests](../Tests/NoemaEditorTests/BlockGutterTests.swift) do not close
  those remaining device checks.
- Formal cached launch-to-render timing and sustained long-document typing/frame
  telemetry remain pending. Service and serialization timings are not these metrics.
- Deferred UI checks include vault setup sheet layout, editor font switching,
  custom TeX modal, fixed 660×560 About window, sidebar lock transitions and theme
  dropdown hover previews; builds/tests do not certify these live interactions.
- Native Sources scrolling FPS, comparative mount duration and Instruments traces
  remain uncollected. Final column sizing-state binding was built/tested, with
  additional live checks deferred. Conditional remounting may reset scroll position.
- Cryptographic storage, key/recovery design, encrypted draft/index/preview policy
  and device acceptance remain prerequisites. Encrypted vault creation is disabled.

### Native authentication device acceptance

All items are **pending**. Deterministic context tests establish attempt ownership,
finite error classification and cancellation/late-callback behavior, not actual
macOS prompt behavior. Exercise Touch ID where available, system-password fallback,
user/system cancellation, unavailable authentication, app switching during a prompt,
keyboard navigation and VoiceOver in the signed development bundle. Verify repeated
operations create independent prompts and a cancelled attempt cannot complete a
later operation. Automated success does not close these device/accessibility gaps.
For an authentication-enabled plaintext vault, verify first open, explicit unlock,
close/reopen, app restart and same-folder permission recovery each authenticate before
showing content. Cancel each operation and retry; check that changing either direction
of the access preference authenticates, and a cancelled first open preserves the newly
created vault. Unprotected legacy vaults should keep their ordinary open behavior.

<a id="d02a-device-acceptance-checklist"></a>

### External AI device/provider acceptance

All items are **pending**; this checklist is a device/provider release gate, not an automated pass record.

1. Launch the signed development bundle. Save/replace/remove a test key without a vault open; restart and verify status without prefilling the field. Inspect preferences, a test vault and application diagnostics for absence of the key. Verify Keychain access follows the intended signing identity without a sharing entitlement.
2. Open a test vault and confirm a page summary disclosure. Exercise Touch ID success, cancellation/failure and permitted password fallback. Confirm a second explicit page/source enrichment reuses authentication while ordinary editing/status reads do not renew expiry.
3. During a pending authentication prompt and active request, lock/close/switch the vault, replace/remove the key, sleep/wake and lock/unlock the macOS screen session. Verify requests cancel and the next summary needs fresh authentication; aborted vault lock still requires it. Test shortened injected deadlines for expiry and a real idle/absolute session boundary as appropriate.
4. With a disposable provider key and nonsensitive content, exercise Always ask, once per unlocked vault session (including lock/switch/relaunch reset), and Never ask without bypassing authentication. Confirm page/source enrichment, source/topic/URL draft review and connection validation work, provider/model labels and generation metadata persist after reopening, local Apple Intelligence title/LCC/source processing still works independently, and provider failures leave canonical content intact. Change/delete content or its prior summary, switch selection and cancel while a response is delayed; verify stale results do not publish.
5. Review provider account expiry/spending limits and data-retention policy. Verify the disclosure communicates outbound text, possible billing/retry transmission, and the inability to recall already-sent text. Keep the in-process and plaintext-vault limitations visible.

### Two-Mac acceptance procedure

1. Open the same iCloud vault on two Macs signed into the same account; download files.
2. Create on Mac A and verify body, tags, links and identity on Mac B.
3. Edit different pages offline; reconnect and verify both changes without loss.
4. Edit the same page offline; reconnect and verify both texts survive in conflict
   copies/recovery controls. Recover one draft as a page and inspect the disk version.
5. Import a source; compare checksums/bytes on the other Mac. Exercise cloud-only
   notes/sources and hydration/unavailable notices.
6. Rename a page and verify old-title links, trash transport and Markdown restoration
   from `Removed Pages` on the other Mac.

<a id="d02-evidence-matrix"></a>

## Storage and lifecycle acceptance

The [architecture](architecture.md) and [storage boundary](contracts/storage-boundary.md)
contain current requirements. The named suites below establish only their stated
scenarios. Earlier D01.R2, D01.R3 and D02.REM05 acceptance is retained by scope.

| Domain | Named automated coverage | Accepted behavior and remaining limits |
| --- | --- | --- |
| Storage selection | [StorageProviderTests](../Tests/VaultCoreTests/StorageProviderTests.swift) | One repository-selected store reaches consumers; staging and published roots select independently. Actual provider transport remains pending. |
| State transitions | [VaultSessionManagerTests](../Tests/VaultCoreTests/VaultSessionManagerTests.swift) | Six states, typed rejection, coalesced close success/failure, cancellation and ownership-safe rollback; named interleavings only. |
| Protected access | [VaultAccessGateTests](../Tests/VaultCoreTests/VaultAccessGateTests.swift), [RecoveryStoreAccessTests](../Tests/VaultCoreTests/RecoveryStoreAccessTests.swift) | Queued/suspended, revoked and wrong-vault leases are rejected when I/O executes. Invalid recovery construction rejects before directory creation and leaves bytes unchanged. |
| Save quiescence | [VaultSaveQuiescenceTests](../Tests/VaultCoreTests/VaultSaveQuiescenceTests.swift), [VaultCleanupFailureTests](../Tests/VaultCoreTests/VaultCleanupFailureTests.swift) | Admission drains; pre-commit cancellation journals edits; durable windows finish and retain commit recognition. Cleanup/recovery failure aborts locking and preserves committed/recoverable content. Cooperative cancellation only. |
| Stale results | [StaleCompletionRaceTests](../Tests/NoemaEditorTests/StaleCompletionRaceTests.swift) | Session/epoch/token/entity/content checks reject delayed search, preview, source, indexing and AI publication across lock/close/switch. No exhaustive schedule guarantee. |
| AppModel integration | [AppModelSessionIntegrationTests](../Tests/NoemaEditorTests/AppModelSessionIntegrationTests.swift) | Purges loaded content, retains failed-close resources, preflights destination, rejects overlapping actions and reconciles rollback with central state. Deferred native/device acceptance stays open. |
| Recovery isolation | [RecoveryStoreIsolationTests](../Tests/VaultCoreTests/RecoveryStoreIsolationTests.swift), [AppModelSessionIntegrationTests](../Tests/NoemaEditorTests/AppModelSessionIntegrationTests.swift) | Valid peers recover across lock/unlock/reopen while unreadable, damaged or identity-mismatched bytes stay visible/preserved. Same-page saves archive damaged entries; decoded deletion refuses them. Directory-wide errors fail explicitly. |
| Preview cleanup | [SourcePreviewDirectoryTests](../Tests/VaultCoreTests/SourcePreviewDirectoryTests.swift) | Sequential/concurrent creation, leases, child-process termination, orphan retry/bounded passes, unrelated/legacy entries, malformed markers, extra contents, symlinks and private permissions. Best effort ordinary removal, not secure deletion. |
| Lexical guard | [adversarial fixtures](../scripts/fixtures/storage-boundary/cases.json) | Eleven guard regressions and 18 adversarial fixtures; reviewed statement ownership/counts enforced. Review-only cases retain same-file target/helper and opaque-API blind spots. |
| Encryption release gate | [VaultCreationTests](../Tests/VaultCoreTests/VaultCreationTests.swift) | Encrypted requests reject before writes. This tests rejection, not encryption. |

App-local search SQLite/WAL/SHM and recovery `Drafts/<note UUID>.json` use Foundation's
runtime Application Support base plus `KnowledgeVault/<vault UUID>/`; tests may
substitute `localStorageRoot`. Neither the sandbox placement nor session locking
changes their plaintext nature. Recovery drafts can be the only unsaved copy.

Imported Quick Look uses validated copied bytes in `noema-source-previews-v1/<UUID>/`
under the temporary-directory URL with an ownership marker and kernel lease. Launch
examines at most 128 immediate children and removes only proven unlocked owned files.
Active, invalid/unmarked/extra-content/symlink and unproven legacy entries remain.
Backlog can postpone other candidates; failures retry later. There is no age rule or
secure erase guarantee. This runtime cleanup is distinct from agent-evidence retention.

<a id="d02-rem05-evidence"></a>

### Rollback and reconstruction race baseline

D02.REM05 acceptance covers the five scenarios below, including both locked/reopened
original-read variants. Explicit signals establish ordering; timeouts bound deadlocks.
The accepted upstream native run passed 215 tests in 21 suites. Existing cancellation,
recovery, stale-result and initialization rollback tests remain relevant alongside them.

| Named test | Integrity and lifecycle acceptance |
| --- | --- |
| [LifecycleRollbackRaceTests](../Tests/VaultCoreTests/LifecycleRollbackRaceTests.swift): `cancelledLockDuringAdmittedPreCommitSavePreservesCanonicalBytesDraftAndReleasesRegistrations` | Cancellation restores the original open session/barrier. Canonical bytes are identical and the journal retains the unsaved body; typed save cancellation drains contexts/registrations/waiters. Subsequent lock reports the preserved draft. |
| Same suite: `failedRecoveryAfterAdmittedSaveCancellationRollsBackAndRetriesRetainedDirtySnapshot` | Journal failure aborts locking, preserving canonical/blocker bytes and dirty snapshot without claiming it journaled. Retry after repair recovers exact draft identity/title/body/tags; registrations drain. |
| [LifecycleReconstructionRaceTests](../Tests/NoemaEditorTests/LifecycleReconstructionRaceTests.swift): `delayedCommittedIndexResultCannotPublishIntoReopenedSession` | Old durable index completion is rejected after generation advances; reopened rows and note identity/body stay unchanged, canonical bytes identical, registrations/waiters zero. |
| Same suite: `delayedOriginalReadCannotPresentReaderAfterLockOrUnlock(reopen:)` | Suspended original read rejects with `VaultAccessError` after revocation in locked and reopened states, presents no window, keeps source bytes unchanged and drains registrations/waiters. |
| Same suite: `failedUnlockAfterCentralOpenRollsBackWithoutLosingDirtyRecoveryDraft` | Injected reconstruction failure returns coherent locked/empty presentation with error; canonical/draft JSON bytes stay identical. Retry recovers exact draft identity/title/body/tags and original canonical body. |

<a id="d01r3-evidence"></a>
<a id="d01r2-evidence"></a>

### Adapter failure and content preservation baseline

D01.R3 is accepted for these adapter-boundary injections and integrity assertions.
They do not inject real atomic-write syscalls, power loss or process termination.
D01.R2 native checks exercised vault opening, UTF-8 readers, PDF copied-byte Quick Look,
reader closing and availability; this does not sign off interrupted cleanup confidentiality.

| Domain and named suite | Integrity assertions |
| --- | --- |
| Publication / [SourceAdapterTests](../Tests/VaultCoreTests/SourceAdapterTests.swift): `failedPublicationRetainsStagingAndURLStatusPreservesOriginal` | No incomplete source publishes; staging retains exact original and checksum/size metadata; URL failures retain captured bytes on reopen. |
| Staging / same suite: `failedSourceStagingNeverPublishesIncompleteContentAndRetainsWrittenBytes(filename:)` | Original/metadata write failures preserve prior source snapshots; metadata failure retains staged original; original failure leaves empty stage. Retry/reopen recover full input without changing failed-stage bytes. |
| Move / [TrashAdapterTests](../Tests/VaultCoreTests/TrashAdapterTests.swift): `canonicalTrashRestoreAndPermanentDeletionPreserveIdentityAndRejectStaleRevision` | Canonical revision checks reject stale Trash actions; restore preserves page identity and content. Legacy filesystem Trash migration is retired. |
| Snapshot / [VaultContentStoreTests](../Tests/VaultCoreTests/VaultContentStoreTests.swift), TrashAdapterTests `restoreAndDeleteRejectChangesInsideAdapter(deleting:)`, SourceAdapterTests `metadataRacePreservesExternalChange(deleted:)` | Create-only/stale replacement, move/delete and flat-directory checks preserve current bytes. External metadata changes survive rejection; deleted files stay absent. |
| Partial deletion / TrashAdapterTests `partialFilesystemDeletionReportsFailureAndPreservesRemainingRecoverableOriginal` | Empty Trash reports injected failure after metadata deletion; surviving original remains exact on reopen. Damaged record cannot restore; retention preserves bytes and metadata needs repair. |
| Recovery / [WikiPageAdapterTests](../Tests/VaultCoreTests/WikiPageAdapterTests.swift): `racePreservesCanonicalAndRecoveryDraft(deleted:)`, VaultSaveQuiescenceTests | External canonical edits/deletions remain; conflicts and reopened journals retain exact draft identity/body. Durable saves finish, cancelled pre-commit work preserves canonical bytes and recovery content. |

## Sensitive-data persistence acceptance (D04)

The [classified surface inventory and lifecycle policy](contracts/storage-boundary.md)
accounts for canonical content, preservation copies, app-local derivatives, transient
presentation, diagnostics, preferences, exported metadata and external ownership.
Plaintext v1 remains supported; this acceptance does not establish encryption.

| Boundary | Automated evidence and disposition |
| --- | --- |
| Search actor admission and retained references | [VaultTests](../Tests/VaultCoreTests/VaultTests.swift) checks construction without a required lease before local bytes are created and rejects stale actor access after lock and reopening. SQLite owns WAL/SHM; existing plaintext files remain. |
| Recovery, staging, trash and previews | [RecoveryStoreIsolationTests](../Tests/VaultCoreTests/RecoveryStoreIsolationTests.swift), [SourceAdapterTests](../Tests/VaultCoreTests/SourceAdapterTests.swift), [TrashAdapterTests](../Tests/VaultCoreTests/TrashAdapterTests.swift), and [SourcePreviewDirectoryTests](../Tests/VaultCoreTests/SourcePreviewDirectoryTests.swift) cover damaged/foreign entries, preservation on injected failure and owned preview cleanup. [VaultCleanupFailureTests](../Tests/VaultCoreTests/VaultCleanupFailureTests.swift) and [VaultSaveQuiescenceTests](../Tests/VaultCoreTests/VaultSaveQuiescenceTests.swift) retain failed/unknown import staging across lock and reopening; only tracked cancellation permits disposal. Unique drafts and conflicted copies must remain recoverable. |
| AI persistence and disclosure | [ExternalAIAdversarialTests](../Tests/ExternalAITests/ExternalAIAdversarialTests.swift), [AIActivityPrivacyTests](../Tests/NoemaEditorTests/AIActivityPrivacyTests.swift), and [AIActivityTests](../Tests/VaultCoreTests/AIActivityTests.swift) enforce request/publication authority, metadata-only history and separate retention. Already transmitted content remains externally owned. |
| Presentation and diagnostics | [ExternalAISettingsTests](../Tests/NoemaEditorTests/ExternalAISettingsTests.swift) and [LifecycleReconstructionRaceTests](../Tests/NoemaEditorTests/LifecycleReconstructionRaceTests.swift) cover session invalidation. Text, HTML and Quick Look readers revalidate authority after caller predicates and the final asynchronous snapshot step before presentation. Debug reports are bounded, opt-in and session-only. |

E-series must protect every classified plaintext copy, including SQLite/WAL/SHM,
preservation drafts, retained activity identities, staging and previews, before claiming
encrypted-vault confidentiality. Ordinary deletion and Swift object release do not
prove secure erasure. Standing native authentication, accessibility, provider/iCloud
and process-crash durability checks above remain pending; deterministic failure
injection does not close those acceptance gaps. PRs record actual command outcomes.

## Current product baselines

- Vault format v1 preserves Markdown, unknown frontmatter, stable persisted UUIDs,
  title aliases and imported SHA-256 checked original bytes. Unsupported formats
  reject; duplicate IDs are quarantined. Vault creation stages before publication.
- Unified Trash uses `Removed Pages`, snapshot-checked restore/delete and a 15-day
  ledger; undated entries receive a full grace period. Damaged/conflicted records
  remain preserved; linked external originals are never removed.
- Block editor preserves readable Markdown plus a versioned checksum-bound JSON
  envelope. External text wins over stale envelopes; future versions are read-only.
  Semantic tags, structural undo/reorder and TeX macros (0–3 arguments) are tested.
- Sources enforce 2 MB imports/URL captures, at most five inputs, checksum/path
  duplicates, read-only bookmarks, authorized previews and session-safe availability.
  On-device AI publishes only against unchanged captured content/session identity.
- Inspector links/references/tags/properties/insights preserve context, selections
  and session invalidation. [InspectorRedesignTests](../Tests/NoemaEditorTests/InspectorRedesignTests.swift)
  and [InspectorLinksTests](../Tests/NoemaEditorTests/InspectorLinksTests.swift)
  cover cache invalidation and resolution; native/typing telemetry stays separate.
- [BrandPaletteTests](../Tests/NoemaBrandTests/BrandPaletteTests.swift) and [ThemeTests](../Tests/NoemaBrandTests/ThemeTests.swift) checks palette
  contrast/identity in light, dark and increased contrast. Five themes and
  accent-only/full-palette choices remain supported; branding assets are permanent.

## Performance expectations

```sh
./scripts/performance.sh --skip-update
```

The single opt-in performance suite selects the `benchmark` workloads and
enables them with `NOEMA_PERFORMANCE_TESTS=1`. Routine tests report these workloads
as skipped. Small functional tests retain cache-reuse, read-count and indexing
assertions without timing measurements or historical before/after comparisons.

- 5,000-entry service benchmark targets cached loading below 2 s and search p95
  below 150 ms. Historical scan/index timings are not app launch/render latency.
- The existing 1,000-block fixture was measured on 2026-10-12 on Apple Silicon,
  macOS 27.0 (26A428), Swift 6.2.4, debug SwiftPM. Three independent process
  samples gave median (range): render: 109.56 ms (91.16–190.65); capture: 42.00 ms (30.91–59.30); encode: 34.98 ms (23.40–40.69); decode: 51.12 ms (40.30–100.06).
  Reproduce after building with `./scripts/test.sh --skip-build --skip-update --filter editorLongDocumentRenderAndReload`.
  Host load was uncontrolled; initial samples overlapped the editor test rerun.
  These service measurements cover attributed-string rendering/capture and codec
  encode/decode. They exclude text-view layout, keyboard events, undo, autosave
  and filesystem delivery, and do not establish live typing frame-rate acceptance.
- EDT.BLK14 extends [RichArticleTests](../Tests/NoemaEditorTests/RichArticleTests.swift)
  with opt-in 100/1,000/5,000-block comparisons on identical fixtures: full rendering
  versus incremental content application, index construction/selection, sibling
  reorder/model application, capture and Markdown codec round-trip. The comparison
  validates identical attributed results and stable block identities; timings are
  observations, with no hardware-independent pass threshold. Use three independent
  process samples per revision on the same idle Mac, same build configuration and
  fixture, retaining commit/OS/Swift provenance in local evidence. This is a service
  comparison, not complete before/after editor acceptance.
- Group 5 release acceptance remains pending for actual keyboard-to-display typing,
  pointer drag/autoscroll, sustained scrolling, document opening including native
  layout, peak/resident memory and canonical database write counts/latency. Collect
  matching Instruments traces at all three sizes before and after integration;
  synthetic service timings cannot certify these metrics. Required native checks
  remain those above, including VoiceOver, themes/contrast, reduced motion, input
  methods, read/edit transitions and lock/unlock/reopen. No compatibility branch
  should be removed until legacy Markdown preservation tests pass.
- Sixteen synthetic source rows construct metadata without eager excerpt decoding.
  Unchanged synchronization must not rebuild/reformat/sort rows; the benchmark
  asserts exactly 16 row constructions across initial setup and 1,000 updates.
- Eligible owned-source scans read 16 originals cold, zero across ten unchanged
  warm scans, and 160 across ten forced-verification scans. Metadata-only paths
  read zero originals; linked/unreliable-evidence paths remain conservative.
- Links presentation with 5,000 pages and 12/60 links asserts one lookup build and
  one target resolution across 200 warm evaluations, rather than a timing threshold.
- Instruments `app.noema` points: `Source Row Construction`, `Source Table Sort`,
  `SourceStatusUpdate`, `SidebarScopeChange`, `SourcesTableAppear/Disappear`,
  `SourceSelection`, `Source Scan`, `Source Original Read`, `Source Text Extraction`,
  `Source Cache Reuse`. Never log titles, paths, UUIDs or content payloads.

## Design token acceptance

The [design contract](contracts/design-tokens.md) retains semantic APIs, approved
component exceptions, native control ownership and visual acceptance requirements.
Capture source: [DesignTokenCaptureTests](../Tests/NoemaVisualValidationTests/DesignTokenCaptureTests.swift),
excluded from the default test graph. Routine bounds coverage lives in
[InspectorRedesignTests](../Tests/NoemaEditorTests/InspectorRedesignTests.swift).
Historical before application source: `0046a9e`; reviewed native-toolbar source:
`40acf50` (integrated in main `d74a938`). Historical UI.TK06 comparison used `8ebe0b9`.
Historical fixture source and reviewed findings remain available in Git history;
New captures use current sources without pre-token compatibility branches.
The historical review used macOS 27.0 (26A428), arm64, Swift 6.2.4.

```sh
validation/ui-design-tokens/capture.sh token-review baseline
# After the proposed visual change:
validation/ui-design-tokens/capture.sh token-review after
python3 validation/ui-design-tokens/select-evidence.py --run-id token-review
```

Captures and selection/manifest output remain in the managed run.
Attach selected review captures to the PR when needed. No capture/report is canonical
source or a permanent golden fixture. Reproduction retains commit/fixture provenance.

- Historical baseline rendered 17 states × System/Midnight Iris × light/dark × standard/
  increased contrast = 136 PNGs. The former current matrix added 720×540 native-minimum workspace
  and 680×480 compact-welcome fixtures across eight modes, producing 152 PNGs.
  Isolated pane preferences avoid reading/writing real workspace state.
  Current opt-in capture exhausts applicable page/source inspector tabs
  at minimum/ideal/maximum widths across both themes, schemes and contrast levels
  alongside 12 workspace/control states (288 PNGs per phase).
  Routine layout coverage uses standard light/dark at all three widths and
  representative Midnight Iris high contrast at minimum width (64 cases), checking
  tab applicability and upper/lower host bounds without image operations. Opt-in
  bitmap/dimension checks reject blank rasters; fixed outer bounds do not prove
  descendants fit or actions work.
- Offscreen `NSHostingView`/borderless-window snapshots omit live titlebar, desktop
  glass composition, menus, alerts and presented sheets. Creation shows content,
  not live sheet presentation. Historical hidden-titlebar roots added 32 safe-area
  points (960×620 → 960×652); current native-toolbar content does not inherit that
  fixed expansion. Fixture assertions use observed host bounds/safe-area insets.
  Historical 960×620 comparison is distinct from current 720×540 workspace minimum
  and 680×480 welcome default. Hosted scrollable descendants can extend below viewport;
  no hosted capture certifies live outer-window, toolbar or traffic-light behavior.
- Theme/high-contrast appearance are injected, not actual OS accessibility toggles.
  Reduce Motion is not injected; disabled capture animation stabilizes static images.
  Both revisions bypass `.systemNoemaTheme()`, so captures do not validate production
  preference invalidation or global foreground-override removal. Source tests do.
- Reviewed chrome has consistent geometry, visible inactive selection, readable
  metadata and stronger increased-contrast boundaries; tested palette text meets
  7:1 and separators 3:1. System accent is one machine's accent, not all choices.
- Minimum All Pages titles truncate earlier due to date/lock targets; full title
  remains in label/tooltip, with actual VoiceOver pending. Inspector Properties
  at 280 points wraps timestamps and retains visible labels/actions in reviewed rasters.
- Offscreen light glass symbols appear white/absent and locked dark labels appear
  black against dark backing in both revisions. Live windows must distinguish
  composition limits from defects; neither a regression nor a fix is established.
- Live keyboard/VoiceOver, OS Reduce Motion timing, real split-pane resizing,
  native glass controls, alerts, menus, presented sheets and appearance transitions
  remain incomplete except the scoped native window checks below. Static screenshot
  success does not close this acceptance gate.


## Native window acceptance

[WindowGeometryTests](../Tests/NoemaEditorTests/WindowGeometryTests.swift),
[WorkspaceCommandTests](../Tests/NoemaEditorTests/WorkspaceCommandTests.swift),
[WorkspacePaneStateTests](../Tests/NoemaEditorTests/WorkspacePaneStateTests.swift) and
[WorkspaceWindowTitleTests](../Tests/NoemaEditorTests/WorkspaceWindowTitleTests.swift)
cover separate profiles, deferred full-screen policy, display clamping, every lifecycle
phase, admission/duplicate reservation, damaged-only recovery command availability,
independent pane intent/width thresholds, controller-owned split configuration and
identity withholding. Model/source tests do not simulate native focus, divider dragging,
full-screen transitions or VoiceOver announcements.

Upstream UI.TBR08 used a separate QA app identity and synthetic Toolbar QA Vault.
Keyboard/lifecycle checks were performed at `73e37d0`; final token-merged live light/
dark captures rechecked pane/toolbar clearance and contextual identity, without
claiming fresh reruns of every earlier interaction. Light was forced in the temporary
QA bundle, re-signed/relaunched; global preferences were unchanged. Accessibility-tree
observations are not VoiceOver. Screenshots are disposable review evidence; upstream
Git history retains provenance, and new captures remain local/PR attachments.

| Native check | Scoped standing result and remaining acceptance |
| --- | --- |
| Light/dark workspace | Synthetic page toolbar/title/three-pane clearance reviewed in final merged build. |
| Welcome and relaunch | 680×480 welcome observed; restored workspace frame and 265 pt sidebar verified. Inspector widths/manual divider edits remain unverified. |
| Search/sidebar/inspector shortcuts | Earlier ⇧⌘F/⌘P sidebar focus acceptance is superseded by UI.SR toolbar search/Quick Open. Live toolbar focus, result traversal, dismissal/restoration and narrow-window presentation remain pending; UI validation/screenshots were explicitly excluded from UI.SR implementation. Standing ⌃⌘S sidebar/⌥⌘I inspector checks retain their prior scope. |
| Lifecycle identity | ⌥⌘L locks to Vault Locked, Unlock returns to Pages, ⇧⌘W closes to compact welcome without previous document identity. Source/other-library contexts pending. |
| Standard controls/long title | Native controls exposed once; full long title retained in accessibility tree. Complete close/minimize/zoom/activation cycle and small-width truncation remain pending. |
| Full screen | Enter/exit and lock/unlock exercised without crash/overlap; exit restoration observed. Full resize/pane-toggle/frame-corruption matrix pending. |
| Pane minimum/dividers | Native minimum-size collapse/restoration, manual divider dragging and divider-width relaunch persistence pending. |
| Sources and auxiliary windows | Native Sources selection/inspector/resizing and About/Settings/source-reader focus isolation pending. Existing source navigation/presentation regressions pass. |
| Accessibility | Actual Reduce Motion, Increase Contrast in both appearances, VoiceOver pane/control announcements and Full Keyboard Access traversal remain pending. |

Remaining partial/pending rows prevent a complete platform/accessibility acceptance
claim. Native controls retain system styling; model pass results alone do not resolve
old offscreen glass ambiguity or validate live menu/alert/sheet presentation.

## External AI acceptance

The [external AI contract](contracts/external-ai.md) defines the in-process boundary and residual risks. Credential, authorization, gateway and actual URLSession adversarial suites use synthetic keys and intercepted/mock transport. AI integration tests cover strict one-inference enrichment/composition, request-mode consent, title preservation/collisions, typed classification/provenance, legacy decoding, conditional writes, unavailable classification, stale leases/edits, cancellation and source relationships. Consent policy tests cover explicit-action dispatch and real vault lock/unlock grant resets. Classification tests validate the finite exact locally verified schedule headings plus supported outlines; they do not establish full LCC coverage. URL policy tests reject private/reserved destinations and unsafe redirects, while DNS rebinding remains a documented transport limitation. These scenarios do not establish hardware authentication, signed-Keychain access, system-event delivery, live-provider/native-model behavior or interactive sheet acceptance. Standing device, accessibility and crash-durability gates remain pending; see the device/provider checklist above.

## SQLite storage acceptance

At baseline `890898fbe0d1511e64dd3e41f932be1147bb79b3`, EDT.BLK09–14 implement
local format-2 pages rather than a hypothetical SQLite design. The following named
fixtures establish scenario coverage; this standing inventory does not claim a fresh
run or repeat prior PR validation. Actual STOR.01 commands/outcomes belong in its PR.

| Implemented guarantee | Regression evidence | Remaining limit |
| --- | --- | --- |
| Relational document reconstruction, incremental writes and schema rejection | [SQLiteBlockStoreTests](../Tests/VaultCoreTests/SQLiteBlockStoreTests.swift): `sqliteBlocksReconstructAndWriteOnlyAffectedRows`, `sqliteBlocksRollbackAndRejectFutureSchema`, `sqliteTrashCyclesResetRetentionIdentity` | Arbitrary future JSON fields are not losslessly retained; current schema has page-only authority. |
| Atomic metadata/document publication, revisions and session authority | Same suite: `sqlitePagePublicationValidationRollsBackMetadataAndBlocks`, `sqliteConnectionsRejectStaleWritesAndReadCoherentPageSnapshots`, `sqliteBlocksRejectRevokedSessionWithoutMutatingPage`, `sqliteCancelledPublicationPreservesLastAcknowledgedRevision` | These transactions do not span separately file-backed source originals/metadata or external files. |
| WAL-inclusive backup and retirement | Same suite: `sqliteWALBackupIncludesAcknowledgedRevisionAndRejectsOverwrite`; repository checkpoint/close lifecycle | SQLite backup is database-only; synthetic cancellation/faults do not prove process-crash or power-loss durability. |
| Explicit conversion with verified backup and conditional manifest-last cutover | [VaultCreationTests](../Tests/VaultCoreTests/VaultCreationTests.swift): original/backup preservation, interrupted publication retry, source/manifest changes, occupied/symlink/missing database and known cloud-root rejection | Filesystem rename/atomic write alone does not establish power-loss durability or universal third-party synchronizer detection. |
| Format-aware page operations and explicit Markdown interchange | [SQLiteRepositoryTests](../Tests/VaultCoreTests/SQLiteRepositoryTests.swift): `explicitMarkdownRoundTripPreservesIDsAndMetadata`, `externalMarkdownRequiresExplicitRevisionCheckedImport` | Native interoperability UI, complete archive/restoration and multi-device SQLite replication remain unavailable. |

STOR.01 changes documentation and approves future requirements only. Schema-3
source/preservation authority, eligible-local SQLite default creation and complete
archive/restore are not implemented or accepted by this review. Device/accessibility,
actual crash/power-loss, native editor performance and real-provider/two-Mac Markdown
transport acceptance remain open; SQLite live databases must never use file-copy sync.
Session locking/native authentication provide no encryption.

## D05 compatibility and preservation acceptance

Production supports plaintext Markdown format 1 and explicitly converted local SQLite page format 2 (database schema 2). This matrix names automated
scenarios; source coverage does not establish a fresh passing run. PR validation
records actual execution and the independent storage review.

| Guarantee | Exact regression evidence / disposition |
| --- | --- |
| Legacy canonical bytes, identity and opaque optional YAML | `VaultTests.legacyManifestAndCanonicalBytesSurviveOpeningAndScanning`; `WikiPageAdapterTests.legacyProvenanceIsAbsentAndUnknownFrontmatterSurvives`; `BlockDocumentTests.blockNoOpCommandsPreserveOriginalMarkdownAndIdentity` |
| Unknown format, mode or required schema rejects before mutation | `VaultTests.unsupportedStorageDeclarationsRejectWithoutMutating`, `futureVaultVersionsRejectWithoutMutation`; unsupported declarations fail closed before database construction; encryption is unavailable |
| Future required document features preserve original source read-only | `BlockDocumentTests.blockFutureFormatAndMalformedDataRemainRecoverable` |
| Creation collision, partial initialization and cleanup | `VaultCreationTests.creationPublicationCollisionPreservesInitializedStagingAndOccupiedDestination`, `failedInitializationRemovesOnlyEmptyOwnedStaging`: preserve nonempty staging; reject occupied retry before staging |
| Unavailable, denied, damaged or missing manifest never authorizes accidental creation | `VaultTests.unavailableManifestAndPermissionFailureRemainDistinctWithoutInitialization` (open/preflight, create false/true), `damagedManifestRejectionPreservesBytesAndCanRetryAfterRepair`, `missingManifestInNonemptyRootCannotBeInitialized` |
| Created vault survives first native authentication cancellation | `VaultAuthenticationIntegrationTests.optedInCreatePersistsRequirementBeforePromptAndCancellationKeepsCreatedBytes` |
| Derived index failure preserves canonical bytes and permits lifecycle retry | `AppModelSessionIntegrationTests.failedDerivedIndexInitializationPreservesCanonicalBytesAndRetriesLifecycle` (open/unlock) |
| Failed transitions, stale callbacks and quiescence respect central state | `VaultSessionManagerTests.failedOpeningUnlockingLockingAndClosingRecoverDeterministically`, `rollbackRequestsCannotMutateASupersedingSession`; `VaultSaveQuiescenceTests.unrecoverableQuiescenceFailureReportsErrorAndAvoidsFalselyPublishingLocked` |
| Admitted commit windows and unsaved recovery survive lock failure | `VaultSaveQuiescenceTests.inFlightSavesEnteringCommitWindowCompleteAndRemainRecognizedWhilePreCommitSavesPreserveRecoveryDraft`; `VaultCleanupFailureTests.committedSaveReportsRecoveryCleanupFailureAndAbortsLockWithoutLosingCommit` |
| Damaged recovery peers, identity isolation and repeated stale recovery | `RecoveryStoreIsolationTests.oneCorruptEntryDoesNotBlockSeveralValidDraftsAndOriginalBytesSurviveReopening`, `identityMismatchAndUnreadableEntryAreReportedWithoutBlockingPeers`, `repeatedStaleRecoveryAttemptsPreserveExternalCanonicalAndJournalBytes`; `VaultAccessGateTests.wrongVaultAccessIsRejectedAcrossRepositoriesStoresAndLeases` |
| External edits, source publication and unavailable-source retry | `WikiPageAdapterTests.racePreservesCanonicalAndRecoveryDraft`; `SourceAdapterTests.metadataRacePreservesExternalChange`, `failedPublicationRetainsStagingAndURLStatusPreservesOriginal`, `availabilityChecksRetainBrokenLinkedSourcesAndRecover` |
| Migration authority, recovery inventory and rollback prerequisites | [Block storage implementation gate](contracts/block-editor.md#storage-decision-and-implementation-gate-edtblk01) and [recovery limits](contracts/block-editor.md#recovery-authority-and-current-guarantees); explicit page conversion is implemented, expanded canonical authority and complete archive/restore remain STOR.02–03 work, E-series owns encryption |

D06 still requires real-provider/iCloud, native-authentication, accessibility and
actual process-crash/power-loss acceptance. Synthetic fixtures do not close these
gaps or establish protection against arbitrary external writers between an empty
staging observation and recursive cleanup. Nonempty retained staging is preservation
data; repeated user-directed failures may retain multiple copies requiring explicit
review, with no automatic purge. Recovery journals lack revision checks between
competing valid writers; recovery-as-new-page retry is not currently idempotent.
Unknown source JSON fields have no lossless rewrite guarantee; future required
metadata needs a compatibility gate before mutation. Derived index failure does
not establish canonical corruption. CI remains disabled.
