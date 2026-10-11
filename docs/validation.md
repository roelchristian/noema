# Validation

This is the standing validation contract, not an execution journal. Update a baseline,
procedure, limitation or acceptance status in place. Routine commands/outcomes belong
in the PR; full logs and screenshots belong in ignored `.local/agent-runs/`.

Reference environment: Apple Silicon, macOS 27.0, Swift 6.2.4, macOS SDK 26.2.
Prior native runs establish the domain acceptance stated below; they are not claims
that a later change has been tested. Rerun the relevant commands for each PR.

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

Build/test wrappers enforce storage routing. CI also runs hygiene and maintenance
regressions. Storage review is separately required by the
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
Opt-in fixture capture procedures are in [development](development.md#typography-capture-fixtures).
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
- Native block pointer drag/drop acceptance remains incomplete: keyboard/menu
  reordering and undo are tested, but live pointer attempts did not complete a drop.
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

<a id="d02a-device-acceptance-checklist"></a>

### External AI device/provider acceptance

All items are **pending**; this checklist is a device/provider release gate, not an automated pass record.

1. Launch the signed development bundle. Save/replace/remove a test key without a vault open; restart and verify status without prefilling the field. Inspect preferences, a test vault and application diagnostics for absence of the key. Verify Keychain access follows the intended signing identity without a sharing entitlement.
2. Open a test vault and confirm a page summary disclosure. Exercise Touch ID success, cancellation/failure and permitted password fallback. Confirm a second explicitly approved page/source summary reuses authentication while ordinary editing/status reads do not renew expiry.
3. During a pending authentication prompt and active request, lock/close/switch the vault, replace/remove the key, sleep/wake and lock/unlock the macOS screen session. Verify requests cancel and the next summary needs fresh authentication; aborted vault lock still requires it. Test shortened injected deadlines for expiry and a real idle/absolute session boundary as appropriate.
4. With a disposable provider key and nonsensitive content, confirm page/source summaries and connection validation work, provider/model labels and generation metadata persist after reopening, local Apple Intelligence title/LCC/source processing still works independently, and provider failures leave canonical content intact. Change/delete content or its prior summary, switch selection and cancel while a response is delayed; verify stale results do not publish.
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
| Recovery isolation | [RecoveryStoreIsolationTests](../Tests/VaultCoreTests/RecoveryStoreIsolationTests.swift), [AppModelRecoveryIsolationTests](../Tests/NoemaEditorTests/AppModelRecoveryIsolationTests.swift) | Valid peers recover across lock/unlock/reopen while unreadable, damaged or identity-mismatched bytes stay visible/preserved. Same-page saves archive damaged entries; decoded deletion refuses them. Directory-wide errors fail explicitly. |
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
| Move / [TrashAdapterTests](../Tests/VaultCoreTests/TrashAdapterTests.swift): `failedTrashPreservesCurrentBytes(mode:)`, `legacyFailedMoveAndCollisionKeepBothVersions` | Failed/colliding moves preserve source and occupied destination bytes; failed legacy migration retains original, retry preserves both versions. |
| Snapshot / [VaultContentStoreTests](../Tests/VaultCoreTests/VaultContentStoreTests.swift), TrashAdapterTests `restoreAndDeleteRejectChangesInsideAdapter(deleting:)`, SourceAdapterTests `metadataRacePreservesExternalChange(deleted:)` | Create-only/stale replacement, move/delete and flat-directory checks preserve current bytes. External metadata changes survive rejection; deleted files stay absent. |
| Partial deletion / TrashAdapterTests `partialFilesystemDeletionReportsFailureAndPreservesRemainingRecoverableOriginal` | Empty Trash reports injected failure after metadata deletion; surviving original remains exact on reopen. Damaged record cannot restore; retention preserves bytes and metadata needs repair. |
| Recovery / [WikiPageAdapterTests](../Tests/VaultCoreTests/WikiPageAdapterTests.swift): `racePreservesCanonicalAndRecoveryDraft(deleted:)`, VaultSaveQuiescenceTests | External canonical edits/deletions remain; conflicts and reopened journals retain exact draft identity/body. Durable saves finish, cancelled pre-commit work preserves canonical bytes and recovery content. |

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
  and [InspectorLinksPerformanceTests](../Tests/NoemaEditorTests/InspectorLinksPerformanceTests.swift)
  cover cache invalidation and resolution; native/typing telemetry stays separate.
- [BrandPaletteTests](../Tests/NoemaBrandTests/BrandPaletteTests.swift) and [ThemeTests](../Tests/NoemaBrandTests/ThemeTests.swift) checks palette
  contrast/identity in light, dark and increased contrast. Five themes and
  accent-only/full-palette choices remain supported; branding assets are permanent.

## Performance expectations

```sh
VAULT_BENCHMARK=1 ./scripts/test.sh --filter benchmarkFiveThousandEntries
SOURCES_BENCHMARK=1 ./scripts/test.sh --filter benchmarkSixteenSourceRowsAndUnchangedUpdates
SOURCES_SCAN_BENCHMARK=1 ./scripts/test.sh --filter sixteenSourceReadCountBenchmark
./scripts/test.sh --filter benchmarkActualLinksPresentationPathWithFiveThousandPages
```

- 5,000-entry service benchmark targets cached loading below 2 s and search p95
  below 150 ms. Historical scan/index timings are not app launch/render latency.
- A 1,000-block render/capture/serialize/reload pipeline is a service workload,
  not sustained interactive typing frame-rate acceptance.
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
Fixture source: [DesignTokenValidationTests](../Tests/NoemaEditorTests/DesignTokenValidationTests.swift).
Before application source: `0046a9e`; current native-toolbar application source:
`40acf50` (integrated in main `d74a938`). Historical UI.TK06 comparison used `8ebe0b9`.
The baseline archive receives only the shared test fixture with
`NOEMA_LEGACY_TOKEN_FIXTURE`;
application sources are unchanged. Machine: macOS 27.0 (26A428), arm64, Swift 6.2.4.

```sh
validation/ui-design-tokens/capture.sh token-review after
BASELINE_REF=0046a9e validation/ui-design-tokens/capture.sh token-review baseline
python3 validation/ui-design-tokens/select-evidence.py --run-id token-review
```

Both matrices remain local; selection/manifest output remains in the managed run.
Attach selected review captures to the PR when needed. No capture/report is canonical
source or a permanent golden fixture. Reproduction retains commit/fixture provenance.

- Baseline renders 17 states × System/Midnight Iris × light/dark × standard/
  increased contrast = 136 PNGs. Current capture adds 720×540 native-minimum workspace
  and 680×480 compact-welcome fixtures across eight modes, producing 152 PNGs.
  Isolated pane preferences avoid reading/writing real workspace state.
  Ordinary runs render five inspector tabs
  at 280 points in eight modes without writing images. Bitmap/dimension checks
  reject blank rasters; fixed outer bounds do not prove descendants fit or actions work.
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

The [external AI contract](contracts/external-ai.md) defines the in-process boundary and residual risks. Credential, authorization, gateway and actual URLSession adversarial suites use synthetic keys and intercepted/mock transport. AI provider and cloud integration tests cover exact action-bound consent, title/LCC review, artifact provenance, conditional publication, debounced manual classification preservation, stale sessions/content, independent summaries and source selection/scope changes away and back; canceled-worker assertions await task completion. LCC suggestion validation covers the supported class/subclass vocabulary, not numeric schedule accuracy. These scenarios do not establish hardware authentication, signed-Keychain access, real system-event delivery, live-provider behavior or native suggestion-sheet interaction. The device/provider checklist above remains pending.
