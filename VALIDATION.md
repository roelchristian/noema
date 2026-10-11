# Validation

Environment: Apple Silicon Mac, macOS 27.0; Swift 6.2.4; macOS SDK 26.2.

> **Workflow note:** Keep this file concise. Update existing domain baselines or active milestone sections in place when refining a feature, reference the standing limitations below instead of repeating sandbox/environment boilerplate, and prune older milestone entries into the domain baselines once a series is signed off. Full historical micro-entries remain in git history.

---

## Standing Limitations & Outstanding Acceptance Checks

### Not yet verified

- **Two-Mac iCloud sync:** Two-Mac iCloud Drive transport, offline concurrent edits, cloud-only placeholders, and real `NSFileVersion` cloud conflicts. Automated stale-file conflict and hydration-error tests pass on a single machine, but cross-device sync reliability remains unverified until the procedure below passes.
- **Accessibility & VoiceOver matrix:** System accessibility preference combinations (Reduce Transparency, Reduce Motion, Increase Contrast) and a full end-to-end VoiceOver navigation pass across all five themes (`System`, `Midnight Iris`, `Forest`, `Amber`, `Rose`) in both Light and Dark appearances.
- **Native block drag-and-drop (Block Editor Deliverable 18):** The drag handle, scoped pasteboard, insertion drawing, and shared reorder/undo commands are implemented and keyboard/menu reordering passes automated undo/redo coverage, but live pointer drag attempts did not complete a drop.
- **End-to-end launch & typing telemetry:** Formal cached app launch-to-render timing and sustained long-document typing frame-rate benchmarks (the 5,000-entry benchmark measures repository/index service loading, and the 1,000-block benchmark measures the render/capture/serialization pipeline).
- **Deferred manual UI checks:** Several recent UI refinements (vault setup sheet layout, editor font switching, custom TeX commands modal, fixed 660×560 About window, sidebar lock icon transitions, and theme dropdown hover previews) were verified via automated tests and debug builds while interactive UI checks were skipped at user request or blocked by Computer Use app approval.

### Two-Mac acceptance procedure

1. Open the same iCloud Drive vault on two Macs signed into the same account. Wait for files to download.
2. Create a page on Mac A; confirm its body, tags, links, and identity appear on Mac B.
3. Edit different pages offline on both Macs. Reconnect and confirm both edits arrive without data loss.
4. Edit the same page offline on both Macs. Reconnect; confirm conflict files/recovery controls preserve both texts. Recover a draft as a new page and inspect the disk version.
5. Import a source on Mac A and compare its checksum/bytes on Mac B. Test a cloud-only note/source and download/unavailable notices.
6. Rename a page, check its old-title links, then move it to trash. Confirm changes arrive on the other Mac and restore its Markdown file from `Removed Pages`.

### Standing build & test environment notes

- **Sandbox vs. native macOS services:** Running `./scripts/test.sh` or `./scripts/build.sh` inside a restricted automation sandbox can block `NSFileCoordinator` (`NSCocoaErrorDomain Code 512`), `NSPasteboard`, security-scoped bookmarks (`com.apple.security.files.bookmarks.app-scope`), and `iconutil` (`Invalid Iconset`). Rerunning with native macOS service access resolves these environmental blocks.
- **Packaging & signing:** `./scripts/build.sh` produces a local ad-hoc signed `dist/noema.app` and clean `dist/noema.zip` (not notarized). Launching an app bundle in place inside an iCloud-synced folder can attach Finder extended attributes that fail strict `codesign --verify --deep --strict`; verify signatures against a freshly packaged bundle or an archive extracted outside iCloud.
- **Layered icons:** Command-line builds ship the flattened `.icns` Dock icon; SVG foreground/background layers are exported for Icon Composer (`Resources/Brand/README.md`).

---

## Active Milestone Log

### D02.1–D02.4.1 vault lifecycle audit, session state machine, access gate & lock admission barrier — 2026-10-11

- **D02.1 (Lifecycle audit):** Cataloged vault opening, creation, bookmark restoration, external watcher refreshes, termination, background task queues, UI state ownership, and paths that implicitly assume an open vault (`.build/noema-d02-1-lifecycle-audit.md`). Defined the six-state transition table, failure/rollback rules, and teardown-before-open contracts.
- **D02.2 (Session state machine):** Implemented `VaultSessionManager`, `VaultSession`, `VaultSessionState`, `VaultSessionPhase`, and `VaultSessionError` in `Sources/VaultCore/VaultSessionManager.swift`, independent of `AppModel` and SwiftUI. Enforces legal transitions across `closed`, `opening`, `open`, `locking`, `locked`, and `unlocking`, tracks vault identity and monotonic `generation`/`epoch`, coalesces duplicate requests, rejects conflicting concurrent transitions, rolls back on cancellation or failure, and publishes an `AsyncStream<VaultSessionState>` observation stream.
- **D02.3 (Repository access gate & session leases):** Added `VaultSessionLease`, `VaultAccessError`, `VaultAccessGate`, and `GatedVaultContentStore` in `Sources/VaultCore/VaultAccessGate.swift`, connected to `VaultSessionManager` and `FileVaultRepository`. Protected repository and adapter reads/writes require a valid session lease and revalidate session state, vault identity/root, and generation when I/O executes (including across async suspension points and actor queues). `FileVaultRepository.inspectManifest(at:contentStore:storageProvider:)` keeps `vault.json` inspection outside the protected content API for opening/unlocking. Simulated locking and leases enforce in-process lifecycle isolation only, not cryptographic protection.
- **D02.4.1 (Operation admission & lock barrier):** Added `VaultLockAdmissionBarrier`, `VaultAdmittedOperation`, `VaultOperationRegistration`, `VaultOperationDisposition`, `VaultOperationRegistrySnapshot`, and `VaultOperationAdmissionError` in `Sources/VaultCore/VaultAccessGate.swift` and integrated barrier draining into `VaultSessionManager.lock(teardown:)`. Transitioning `open → locking` atomically rejects new protected operations while tracking previously admitted operations, allowing task-local scoped admitted operations to finish draining before entering `locked`, coalescing concurrent lock attempts, rolling back cleanly on cancellation, and releasing abandoned registrations on `deinit` without leaks or deadlocks.
- **Validation:** `./scripts/test.sh --filter VaultSessionManagerTests` (6 tests) and `./scripts/test.sh --filter VaultAccessGateTests` (6 acceptance suites covering locked reads/writes, stale session tokens after unlock/switch, queued/suspended operations crossing lock boundaries, wrong-vault access, manifest inspection while locked, atomic lock-barrier admission/draining across concurrent locks, and cancellation/abandoned-registration recovery) passed, alongside `scripts/check-storage-boundary.py --selftest` and `./scripts/agent-supervisor.py selftest`.
- **Remaining:** `AppModel` and `ContentView` wiring to `VaultSessionManager`, `VaultAccessGate`, and `VaultLockAdmissionBarrier` (plus gating `SQLiteSearchIndex`, `RecoveryStore`, `VaultWatcher`, and external linked-source helpers) is deferred to subsequent D02 tasks.

### D01.R2 consolidated storage construction — 2026-10-11

- `VaultStorageProvider` selects the repository-owned `VaultContentStore` once per opened root. Readers, availability checks, and PDF summary extraction require the selected store. Staged creation uses the same provider with its temporary root; final open selects a store for the published root. Imported Quick Look receives disposable validated byte snapshots, cleaned on close/error/vault switching. Plaintext v1 bytes and linked bookmarks remain unchanged.
- Full native regression suite passed all 139 tests across six suites (`.build/d01r2-completion-regression.log`), including instrumented selection/consumer/staging and injected PDF summary coverage. Debug compilation, packaging, signing, and archive creation passed (`.build/d01r2-completion-build.log`), along with all 11 `scripts/check-storage-boundary.py --selftest` cases and `./scripts/agent-supervisor.py selftest`.
- Native checks in a separately signed app copy and disposable vault confirmed vault opening, imported UTF-8 text reading, PDF Quick Look rendering of disposable snapshots, reader closing, and PDF availability checking. Preview copies are plaintext temporary files; interrupted-process cleanup/confidentiality policy remains future work for encryption.

### D01.2–D01.6 storage boundary & adapter migration sign-off — 2026-10-11

- **D01.2–D01.5 (Adapter & I/O migration):** Introduced `VaultContentStore` and the plaintext content adapter with create-only/expected-byte atomic writes, snapshot-checked file/flat-directory moves and deletes, and path-traversal/symlink guards. Migrated wiki page I/O (`D01.3`), source original/metadata/staging/trash I/O (`D01.4`), and manifest/setup, page trash/restore/permanent deletion, legacy `.Trash` migration, and trash retention ledger I/O (`D01.5`) through `VaultContentStore`. `RecoveryStore` and `SQLiteSearchIndex` were audited and intentionally kept as actor-owned app-local stores.
- **D01.6 (Boundary enforcement):** Recorded canonical adapter routes and permitted exceptional I/O in `STORAGE_ACCESS_AUDIT.md`, closed `AppModel`'s imported PDF summary read bypass via checksum-checked `readSourceOriginal`, and added the lexical boundary guard (`scripts/check-storage-boundary.py`) to both `./scripts/build.sh` and `./scripts/test.sh`. Passed all 137 regression tests and full debug packaging.

---

## Consolidated Domain Baselines

### 1. Core Storage, Trash, Recovery & Performance (`VaultCore`)

- **Canonical format & repository invariants:** Preserves Markdown bodies, unknown YAML frontmatter, persisted UUIDs across file moves, old titles as aliases on rename, and byte-for-byte source originals verified by SHA-256 checksums. Rejects unsupported vault format versions and quarantines duplicate UUIDs.
- **Vault setup & encryption release gate:** New vaults are staged and published atomically via a 540pt setup sheet (`My Knowledge Vault` default name, parent folder picker, explicit plaintext confirmation). Encrypted vault creation is visibly disabled (*Coming soon*) and rejected at UI, `AppModel`, and repository boundaries until cryptographic storage is implemented.
- **Combined Trash & 15-day retention:** Recoverable pages (`Removed Pages`, migrated automatically from legacy `.Trash` folders to avoid external sync deletion) and trashed sources (metadata + imported originals) share a unified Trash view accessed from the bottom sidebar vault menu. Supports snapshot-checked Restore, named-item Permanent Delete, and Empty Trash, plus automatic 15-day cleanup on open/refresh (with a 15-day grace period for undated legacy items and protection for damaged/conflicted records).
- **Performance benchmarks:**
  - `VAULT_BENCHMARK=1 ./scripts/test.sh --filter benchmarkFiveThousandEntries`: 5,000-entry initial scan 13.72 s, initial index 5.73 s, cached load 54.50 ms (< 2 s target), search p95 34.89 ms (< 150 ms target).
  - 1,000-block render/capture/serialization/reload pipeline: 115 ms.

### 2. Block Editor, Semantic Blocks & Math/TeX

- **Block editor & slash menu:** Supports paragraph, headings, lists, tasks, quote, code, divider, callout, and collapsible toggles in a lossless versioned block envelope (`BLOCK_EDITOR.md`), plus 10 semantic block tags with independent statuses, optional inline semantic headings (**Settings → Block display**), and a non-activating `NSPanel` slash command palette (240pt wide, vertical-only placement).
- **Math & custom TeX macros:** Supports inline (`$...$`, `\(...\)`) and display (`$$...$$`, `\[...\]`, `/math`) math rendering via `TeXMath`, plus persisted user macros (`\newcommand` with 0–3 arguments) managed in **Settings → Math & TeX → View or Edit Custom Commands…** (`CustomTeXCommandsModal` and `TeXMacroStore`).
- **Typography & editing lock:** Default body text is 15pt (14pt in source/plain readers), configurable in **Settings → Editor** (font family and 10–32pt size). Locked pages show a leading sidebar lock control with hover/focus/VoiceOver support, preserve timestamps on lock-only toggles, and show an inline unlock reminder when clicked in read mode.

### 3. Sources, URL Captures & On-Device AI

- **Imported, linked & URL sources:** **Add Source** defaults to security-scoped read-only file linking with an opt-in vault import checkbox (2 MB import limit; max 5 files per picker batch; duplicate checksum/path prevention). **Add Sources by URL** fetches 1–5 HTTP(S) URLs (HTML, plain text, PDF up to 2 MB) with byte-for-byte preservation. Markdown/text/HTML open in native read-only `NSTextView` windows; PDFs and binary formats open in `QLPreviewView`. Availability checks run on a serial background queue and record archived status for unreachable URLs.
- **On-device Apple Intelligence:**
  - **Summaries:** Opt-in page and source summaries (`OnDeviceSummary`), displayed in a full-width frosted banner (with scroll collapse, 3-line preview disclosure, and **Settings → Apple Intelligence** placement preference) and in the right-hand Inspector.
  - **Automatic & queued topic naming:** Unnamed pages and newly added sources infer concise 2–6 word topic titles (max 8 words, language-preserving) in the background; background page renames show an unread blue dot in the sidebar.
  - **AI page creation:** Supports creating editable wiki pages from a source (persisting the initial source reference UUID) or from a topic via public Bing RSS web research (summarizing up to 3 readable results with citations and attribution).

### 4. Navigation, Global Search, Inspector & Theme Identity

- **Workspace & Inspector:** Three-pane layout with sidebar, wider list/table pane (385pt ideal width for lists), and main reader/editor alongside a unified, resizable 340pt **Inspector** (Properties, bidirectional Page/Source References with inline removal confirmation, Semantic Blocks with one-click block jump, and AI Summary).
- **Global search & semantic block browser:** Sidebar search queries pages, sources, and semantic blocks concurrently off the main actor and groups results in `Pages`, `Sources`, `Semantic Blocks` order. Dedicated **Semantic Blocks** sidebar collection lists and filters all user-tagged semantic blocks across the vault (excluding AI-generated summaries).
- **Themes, Liquid Glass & Brand:** Defaults to **Midnight Iris** (full palette) on fresh installs, with **System**, **Forest**, **Amber**, and **Rose** palettes, full-palette vs. accent-only mode, and live `NSPopUpButton` swatch hover previews. Contrast checks (`NoemaBrandTests`) enforce AA legibility in Light, Dark, and Increased Contrast modes. **About Noema** uses a fixed 660×560 themed window with the shared `OrbitGeometry` Liquid Glass mark.
