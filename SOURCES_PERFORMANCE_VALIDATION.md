# Sources performance remediation

## Scope

SRC.P1/P2/P3/P5/P6 change only UI presentation and tests. `AppModel.swift` changes only the source `LibraryRow` excerpt initializer. Vault sessions, access gates, storage, encryption readiness, scanning, and formats are unchanged.

The excerpt audit found `LibraryRow.excerpt` used by page rows; global source-search results use source title/filename, and source previews use the existing reader/detail paths. Source metadata rows now carry no decoded excerpt. Legacy sources without persisted size still use the existing UTF-8 byte-count fallback, without parsing content.

`SourcesTablePresentation` retains body-free metadata inputs and formatted rows. It rebuilds only changed rows and sorts only when metadata or the native comparator changes. `SourcesStatusPresentation` retains stable per-ID observable status objects; title and availability properties update independently. Departing cells' retained status objects have their labels cleared too.

The native SwiftUI `Table` is mounted only while Sources is visible. The former hidden table required table evaluation, sorting, and metadata/status lookups while Pages was visible; there was no measured net benefit supporting retention. Cached metadata, comparator order, and UUID selection remain in the workspace across tab switches. Root/session resets clear sensitive metadata and selection.

## Automated checks

- `./scripts/test.sh`: **181 tests across 15 suites passed**, including source metadata/status regressions, navigation, session/access-gate, stale-completion, quiescence, storage, editor, and brand tests.
- `./scripts/build.sh debug`: native compilation, bundle packaging, ad-hoc signing, and archive creation.
- `codesign --verify --deep --strict dist/noema.app`.
- `python3 scripts/check-storage-boundary.py --selftest`: all 11 cases pass; boundary guard passes.
- `git diff --check`.

Older article-navigation/edit-lock fixtures now open real temporary vault sessions. Production closed-session guards remain unchanged. Tests that manipulate the process-global `SourceReader` are grouped under one serialized suite so another fixture cannot close a preview under test; unrelated tests still run in parallel.

## Repeatable measurement

Run `SOURCES_BENCHMARK=1 ./scripts/test.sh --filter benchmarkSixteenSourceRowsAndUnchangedUpdates`.

One debug run on this development Mac, using 16 synthetic text sources of 133,200 bytes each:

| Operation | Duration |
| --- | ---: |
| Former excerpt decode/join work alone | 6.670 s |
| Metadata-only `LibraryRow` construction | 28.752 ms |
| Initial table metadata formatting and sorting | 11.791 ms |
| 1,000 unchanged metadata synchronizations | 11.089 ms total |

Exactly 16 table rows were constructed across initial preparation and the 1,000 unchanged updates. These are synthetic data-preparation measurements, with debug/cold-start costs, not scrolling FPS, input latency percentiles, or a full legacy/new rendering comparison.

## Native interaction check

A separately signed QA bundle with its own application identity opened a disposable 16-source vault. Verified native table accessibility label and seven columns, mouse selection, arrow-key selection with inspector updates, horizontal scrolling, primary-action previews, context-menu actions, availability checking, rename/title re-sorting, full-text source search, refresh, and selection/sort restoration after Pages/Sources switches. Locking removed table/inspector content; unlocking restored the renamed row without stale selection.

AI menu actions and their original disabled conditions are preserved. Real AI generation and every inspector mutation were not rerun as part of this presentation-only change.

## Instruments and remaining limits

Record Points of Interest for subsystem `app.noema`. Intervals: `Source Row Construction`, `Source Table Sort`, `SourceStatusUpdate`. Events: `SidebarScopeChange`, `SourcesTableAppear`, `SourcesTableDisappear`, `SourceSelection`. No payload includes source titles, paths, bodies, or other vault content.

Native scrolling appeared responsive during the interaction check, but no Instruments trace, scrolling FPS, or comparative mounting-duration profile was collected. Conditional remounting can reset native scroll position and user-adjusted column widths; original min/ideal column sizing, UUID selection, and comparator order are preserved. SwiftUI/AppKit can still reevaluate or repaint views during selection/layout; this work removes eager decoding, repeated formatting/sorting, and broad status observations from the table data path. Initial vault scanning/indexing and preview decoding remain outside this remediation.

The branch is based on current remote `main`. D02.7 is not integrated there yet. Per the user's direction, post-D02.7 rebase and lifecycle revalidation remain pending integration.
