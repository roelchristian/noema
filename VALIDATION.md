# Validation — 10 October 2026

Environment: Apple Silicon Mac, macOS 27.0; Swift 6.2.4; macOS SDK 26.2.

## Automated

- Release regression suite passed: 13 functional checks, plus the optional benchmark entry (not executed without `VAULT_BENCHMARK=1`).
- Covered semantic YAML preservation, exact source bytes/checksums, malformed data, code-excluded wiki links/tags, title aliases, duplicate identity quarantine, external moves, stale edits/deletions, recoverable trash, disk-save failures, draft reopening, search, backlinks, rebuilding indexes, incomplete sources, and vaults inside hidden parent folders.
- A separate release run executed the 5,000-page benchmark successfully: initial scan 13.68 s; initial index 6.01 s; cached load 43.53 ms; search p95 35.41 ms, returning all 5,000 matches across 20 searches.
- Search passed the 150 ms target; cached service loading passed the two-second target. End-to-end cached app launch timing is not formally measured.

## Native UI

Initial local checks verified creating a vault via a folder picker, creating a personal page, editing a title/body/tags, autosave, Markdown reading preview, inline tag discovery, and following an unresolved link to create a page.

The final release build verified folder switching through an attached native picker, restoring the selected vault after relaunch, pasted-source capture and a non-editable source viewer, backlinks between the Pertinax/Rome demo pages, and a live external Markdown edit appearing automatically in the reading view. The demo vault is included under `Examples`.

Packaging produces a local ad-hoc signed `.app` and an archive without extended attributes. The iCloud-backed Documents folder can attach Finder information to an app bundle after launch, which makes strict signature verification of that in-place bundle fail; the clean archive is verified after extraction outside iCloud.

## Liquid Glass and orbital identity update

- Reviewed Apple's [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and custom-view guidance. Glass remains concentrated in navigation and controls; page text, source originals, and metadata retain standard content backgrounds.
- Release compilation passed. The existing 13 functional checks passed; the optional benchmark entry returned without running the benchmark. The sandboxed test attempt could not use macOS file coordination; rerunning with access to that service passed the suite.
- Native UI checks verified the glass search field, ⌘K focus, search clearing, Edit / Read toolbar control, Markdown preview, source navigation, grouped source actions, and the non-editable original text viewer. Glass control groups rendered without overlap in the observed window.
- The orbital mark uses native SwiftUI Liquid Glass, with shared filled geometry for its SVG layer and packaged icon. Icon previews were inspected at 128 and 1024 pixels, including open ring centers and rounded orbit endpoints.
- Reduce Transparency and increased contrast have explicit opaque-logo fallbacks; native controls handle their own accessibility adaptations. System accessibility preference combinations and a full VoiceOver pass remain unverified; light/dark appearance checks are recorded below.
- This command-line build ships the updated flattened `.icns` Dock icon. SVG foreground/background layers are ready for Icon Composer; system-rendered layered icon appearances require Icon Composer and an Xcode app target, which are unavailable here. See `Resources/Brand/README.md`.

## Midnight Iris appearance update

- Added the eight supplied semantic light/dark tokens in `Sources/NoemaBrand/MidnightIris.swift`, shared by SwiftUI, native text views, and the icon generator. Text variants are derived toward the palette's primary text rather than substituting unrelated hues.
- Four new checks verify sRGB contrast calculation, AA contrast for primary/muted/accent text against both content surfaces, increased-contrast variants, and readable white/off-white labels on derived control fills. All passed along with the existing 13 functional checks (18 test entries total, including the optional benchmark that did not run).
- Native UI verified Light and Dark preferences, immediate recolouring of the existing Markdown preview, matching editor foreground/background colours, and Dark remaining selected after quitting and relaunching. System is the default and uses `preferredColorScheme(nil)` to follow macOS. Switching from Light to System restored the Mac’s current dark appearance; the preference was left on System after checks. No macOS appearance settings were changed.
- Native selection backgrounds remain platform-managed. Selected library rows use primary text for legibility; topic icons/chips use violet and relationship links use cyan. The search placeholder uses an accessible, non-interactive themed label because macOS ignored its custom native placeholder colour.
- Native controls and glass materials retain system activation, focus, hover, disabled, and accessibility behaviour. The custom orbital mark has explicit opaque fallbacks for Reduce Transparency and increased contrast. Contrast tests validate solid token surfaces; a full VoiceOver and system accessibility-preference combinations pass remains outstanding.
- Exported light/dark SVG layers and the Midnight Iris `.icns` icon share the same palette and geometry. The app currently has wiki pages, topics, sources, and backlinks; no knowledge graph renderer exists. Graph highlight/relationship roles are available for future use without adding a new graph feature during this styling change.

## Not yet verified

- Two-Mac iCloud Drive transport, offline concurrent edits, cloud-only placeholders, and real `NSFileVersion` cloud conflicts. Automated stale-file conflict tests passed, but these do not establish cross-device sync reliability.
- System accessibility preference combinations (Reduce Transparency / Reduce Motion) and full VoiceOver navigation. Standard native controls/materials are used; no custom animation or glass renderer is present.
- Formal end-to-end app launch benchmark and long-document typing performance.

## Two-Mac acceptance procedure

1. Open the same iCloud Drive vault on two Macs signed into the same account. Wait for files to download.
2. Create a page on Mac A; confirm its body, tags, links, and identity appear on Mac B.
3. Edit different pages offline on both Macs. Reconnect and confirm both edits arrive without data loss.
4. Edit the same page offline on both Macs. Reconnect; confirm conflict files/recovery controls preserve both texts. Recover a draft as a new page and inspect the disk version.
5. Import a source on Mac A and compare its checksum/bytes on Mac B. Test a cloud-only note/source and download/unavailable notices.
6. Rename a page, check its old-title links, then move it to trash. Confirm changes arrive on the other Mac and restore its Markdown file from `.Trash`.

Until this procedure passes, iCloud support is implemented but cross-device behavior remains unverified.
