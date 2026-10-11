# UI.TBR08 — Native window integration validation

Branch: `dev/ui-native-toolbar`. Native-window baseline: `0046a9e`; upstream integration target: `origin/main` at `a45ffc6`. Validation date: 12 October 2026 (Asia/Manila). This report separates source review, automated regressions and interactive macOS evidence. A source assertion or passing model test does not certify an accessibility or window interaction check.

## Before and after

| Area | Baseline | Integrated behaviour |
| --- | --- | --- |
| Window chrome | Hidden main titlebar, `TrafficLightEnforcer` and content extended into the titlebar safe area. | Native titled main window with standard controls and safe-area layout. |
| Global controls | Creation, vault, navigation and inspector controls repeated in content headers. | One native toolbar; document editing controls remain with the document heading. |
| Titles | Static, hidden Noema scene title. | Welcome/application, library, page, source and lifecycle identity derived from existing metadata; vault subtitle; document identity withheld outside an available open session. |
| Pane visibility | Always-visible sidebar; transient inspector visibility. | Independent persisted sidebar/inspector intent and widths; narrow windows temporarily collapse outer panes and retain intent; search reveals the sidebar. |
| Actions | Toolbar-like controls and menu commands called model methods independently. | Global controls and menus share guarded `AppModel.performWorkspaceCommand`; lifecycle actions reserve admission before queuing. |
| Window geometry | 1280 × 820 default, 960 × 620 minimum for welcome and workspace alike. | Separate native saved welcome/workspace frames; 680 × 480 and 1280 × 820 defaults; clamping to available screens; frame changes deferred during full-screen transitions. |

`HSplitView` remains the native resizing container. `NavigationSplitView` was evaluated and rejected for this scope because the center alternates between library/table and document content, while the inspector is independently contextual. See [pane design](UI_TBR_SPLIT_PANES.md) and [architecture audit](UI_TBR_ARCHITECTURE_AUDIT.md).

## Source review

- Reviewed the integrated changes against `0046a9e`, including scene ownership, standard controls, command admission, pane preferences/native split persistence, geometry restoration and contextual identity.
- Main-window probes operate on their attached window and do not mutate whichever auxiliary window happens to be key. Source-reader, About and Settings window definitions remain outside the geometry controller.
- The native-window feature preserves storage/session interfaces and adds no storage-boundary exceptions. New title/pane/toolbar evaluation uses existing metadata and presentation state, without decoding source bodies or adding canonical byte access. The merge retains upstream D02 recovery-listing/preview-cleanup changes and their reviewed storage-boundary exceptions.
- `SourcesLibraryView`, `SourcesTablePresentation` and their metadata/status observation bridges are unchanged. The center retains the existing 520 pt Sources and 420 pt document minimums, with inherited pane layout animation disabled.
- Existing meaningful regression tests cover the new policies. UI.TBR08 adds this integration report and corrects an existing Sources test's timing assumption while retaining its assertions.
- Final independent source review has no unresolved actionable implementation findings. Required unperformed native/accessibility checks are recorded below.

Storage-boundary review: **N/A for new construction, canonical-access or I/O-exception changes relative to `origin/main` at `a45ffc6`**. Independent code inspection traced shared commands to the existing guarded `AppModel` operations; pane preferences use dedicated `UserDefaults` keys and frames use native window persistence, without introducing vault byte access or adapter construction. The incoming launch call to `SourcePreviewDirectory.application.cleanupOrphans()` remains in `AppDelegate`, using the existing bounded temporary-preview owner and retaining reader/lock/switch cleanup policy. Upstream storage construction, canonical APIs, reviewed exceptions and preview-cleanup targets are unchanged by this feature. This conclusion comes from source inspection, not just the lexical guard.

## Integration findings

- Independent review identified a narrow locked-window layout risk when four actions are visible. The integration uses a horizontal/vertical `ViewThatFits` fallback. It also applies shared command availability to the sidebar footer's Trash, recovery and notices buttons.
- Initial native launch reached the welcome screen, but opening the demo vault raised an AppKit exception from the split persistence probe's holding-priority configuration. AppKit prohibits direct holding-priority mutation when an `NSSplitViewController` owns the split. The integration preserves the controller's policy and delegate; post-fix native workspace reopening succeeded. A regression test configures a real controller-backed split and verifies delegate/priority preservation and stored width restoration.
- The first full suite exposed six assertion failures in the existing Sources unavailable-content test, which passed when run alone. A concurrent watcher refresh can make `await model.refresh()` coalesce a later pass instead of waiting for publication. The test now awaits the expected unavailable/removed content predicates before mutating its fixture again, preserving every original assertion and the production refresh contract. The final full suite passes.
- `origin/main` advanced to `a45ffc6` during implementation, adding isolated damaged-recovery listing and protected source-preview cleanup. The merge preserves native toolbar/header ownership alongside upstream damaged-entry presentation and preview lifecycle behaviour. Sources navigation conflicts contained equivalent refresh waits; the stronger publication predicates are retained. Recovery availability must include damaged entries even when there are no valid drafts. The merged full suite and storage-boundary guard pass, including a new damaged-only recovery command/lock/unlock regression.

## Automated regression results

Before merging `a45ffc6`, the full run passed **258 tests across 26 suites in 23.844 seconds**, with the Sources benchmark enabled. Output was recorded at `/private/tmp/noema-tbr-complete-tests.log` during this session. The final merged branch passes **273 tests across 29 suites in 68.324 seconds**. Its benchmark-enabled output is recorded at `/private/tmp/noema-tbr-rebased-tests.log`.

| Check | Coverage | Result |
| --- | --- | --- |
| `SOURCES_BENCHMARK=1 zsh scripts/test.sh` | Complete VaultCore, NoemaBrand and NoemaEditor suites, including D01 storage and D02 lifecycle admission/draining/cancellation/stale-result coverage. | Merged pass: 273 tests / 29 suites |
| `python3 scripts/check-storage-boundary.py --selftest` | Canonical I/O ownership and reviewed exceptional access, plus guard fixtures. | Merged pass: 11 regression + 18 adversarial cases; 40 reviewed exceptions |
| Sources benchmark in full run | Sixteen 133,200-byte source fixtures, metadata-only rows and 1,000 unchanged presentation synchronizations; benchmark is disabled without `SOURCES_BENCHMARK=1`. | Merged pass: 16 constructed rows; no rebuilds for unchanged synchronizations |
| `git diff --check` | Patch whitespace validation. | Merged pass |

New regression coverage is in `WindowGeometryTests`, `WorkspaceCommandTests`, `WorkspacePaneStateTests` and `WorkspaceWindowTitleTests`. It checks separate profiles, full-screen deferred presentation policy, offscreen/disconnected screen clamping, every lifecycle phase, stale manager/lease admission, duplicate lifecycle reservation, independent persisted pane intent, width thresholds, invalid preferences, controller-owned native split configuration, selection-derived titles and withholding private document identity during revocation. It does not simulate native full-screen, divider dragging, VoiceOver announcements or actual keyboard focus.

The pre-merge benchmark measured 8.832 s for the legacy excerpt decode comparison, 8.883 ms for metadata row creation, 6.258 ms for initial table preparation, and 12.995 ms for 1,000 unchanged synchronizations. The merged rerun measured 41.825 s, 24.376 ms, 15.996 ms and 24.041 ms respectively. These are measurements from these runs, not a comparison of application frame rates or a release performance threshold.

## Native macOS verification matrix

Interactive validation uses a separate QA application identity and isolated test vault IDs/local state. Initial launch checks used a copied `Examples/Demo Vault`; published screenshots use a synthetic **Toolbar QA Vault** with two fixture pages. Baseline statements above come from source review; no baseline runtime screenshots are claimed.

The interactive results/screenshots below were captured at native-window integration `73e37d0`, before the upstream D02 merge. Resolved-source review confirms the native layout/action ownership remains intact; it does not substitute for a fresh merged-build interaction check.

Light capture uses `NSRequiresAquaSystemAppearance=true` in the temporary QA bundle, followed by re-signing/relaunching that bundle. Global appearance preferences were not changed. Native checks combine interactive actions and macOS accessibility-tree observations; accessibility-tree evidence is not a VoiceOver test.

| Check | Procedure / pass condition | Performed result |
| --- | --- | --- |
| Light appearance | Open fixture workspace; check toolbar clearance/alignment and sidebar/editor/inspector safe areas. | Pass: reviewed synthetic page screenshot; toolbar/title and three panes aligned |
| Dark appearance | Repeat workspace check in dark appearance; retain a screenshot of the same context. | Pass: reviewed synthetic page screenshot; toolbar/title and three panes aligned |
| Welcome sizing | Cold launch with no QA bookmark; compact welcome fits around 680 × 480 content points. | Pass: observed 680 × 480 pt welcome and Noema native identity |
| Standard controls / activation | Close/minimize/zoom and activate/deactivate main window; controls remain native with no duplication. | Partial: native accessibility tree exposes standard close/full-screen/minimize controls exactly once; complete control/activation cycle pending |
| Library/document identity | Select libraries, open a page and primary source, return to library; title/subtitle follow identity without moving the content heading. | Partial: Pages/vault subtitle and Native Toolbar page identity/content heading verified; source/other library UI contexts pending |
| Long identity | Open/rename a long page title at a small width; native title truncates without toolbar overlap or document layout instability. | Partial: native accessibility tree retains full long page title; small-width truncation pending |
| Sidebar/search keyboard | Hide sidebar; use ⇧⌘F / ⌘P; sidebar mounts and existing field receives focus. ⌃⌘S toggles sidebar. | Pass: both search shortcuts reveal hidden sidebar and focus Search; sidebar shortcut toggles visibility |
| Inspector keyboard | Use ⌥⌘I; effective shown/hidden state updates; unavailable context disables the action. | Pass: shortcut hides/shows inspector; action disabled on library context |
| Minimum window | Resize to workspace minimum; outer panes collapse while document/Sources center remains usable; enlarge and requested panes return. | Pending |
| Divider persistence | Drag each divider, close/relaunch QA app, reopen vault; stored widths and independent visibility restore. | Pending: native divider dragging not exercised |
| Relaunch restoration | Quit/relaunch QA app; reopen restored workspace and compare its frame/sidebar width. | Pass: workspace frame and 265 pt sidebar restored; inspector width/manual divider changes not verified |
| Full screen | Enter/exit full screen, resize/toggle panes, lock/unlock while full screen; no traffic-light overlap or saved-frame corruption. | Partial: ⌃⌘F enters/exits without crash or toolbar overlap; full-screen lock/unlock exercised and frame restoration observed after exit. Resize/frame-corruption matrix pending |
| Lifecycle UI | Lock, unlock and close through shared actions; private document identity disappears outside open workspace. | Pass: ⌥⌘L locks page with Vault Locked/vault subtitle; Unlock button returns to Pages; ⇧⌘W closes vault to compact Noema welcome with Create/Open buttons and no prior document identity |
| Sources native table | Exercise Sources selection, inspector and resizing in the native workspace. | Pending interactively; existing navigation/presentation/performance suites pass |
| Auxiliary windows | Focus About/Settings/source reader; main title/frame probes do not change auxiliary chrome or geometry. | Pending |
| Reduced motion | Enable system Reduce Motion; resize/toggle/navigation remain stable without unexpected animated document/table relayout. | Pending |
| Increased contrast | Enable Increase Contrast; toolbar icons/focus/disabled states and native boundaries remain legible in both appearances. | Pending |
| VoiceOver | Enable VoiceOver; traverse toolbar and panes; actionable labels, availability and effective pane values announced; search focus reaches the field. | Pending |
| Keyboard traversal | Enable Full Keyboard Access as appropriate; traverse toolbar, menus, panes and dialogs; no focus trap after collapse/remount. | Pending |

## Evidence and remaining acceptance

[Light workspace screenshot](screenshots/UI_TBR_light_workspace.png) and [dark workspace screenshot](screenshots/UI_TBR_dark_workspace.png) show the same synthetic page, native toolbar/title/subtitle and three panes. The purple pill at the left of the titlebar is the macOS screen-capture indicator. Standard window-control behaviour is assessed separately from these screenshots.

The native implementation has no unresolved source-review finding; merged-branch automated validation is pending. UI.TBR08 accessibility/platform acceptance remains incomplete: the pending and partial rows above require the remaining native window, Sources UI and accessibility checks before the PR is promoted as fully verified.
