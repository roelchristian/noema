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
