# UI.B1–UI.B3 integration verification

Validated on 12 October 2026 in the dedicated `dev/ui-branding-update` worktree,
based on published `main` commit `4b8b8ac`. The active `main` checkout was not
modified or merged; its unpublished D02 commit was excluded from the PR branch.

- `scripts/test.sh`: all 163 tests in 9 suites passed, including eight new brand
  palette tests and the existing interface theme and vault regression tests.
- `scripts/build.sh debug`: application build, asset generation, `.icns`
  packaging, signing and ZIP archive creation passed.
- `codesign --verify --deep --strict dist/noema.app`: passed.
- Storage boundary guard and `git diff --check`: passed.
- Asset reproduction: all nine artwork files and ten iconset PNGs matched
  between repeated generations. The flattened dark icon remains identical to
  the original generator's output. See [export verification](export-verification.txt).
- Production SwiftUI rendering: 50 exact pixel comparisons confirmed theme
  invariance for both appearances at 20/64/96-point glyphs and 76/116-point
  identity tiles. Both contact sheets were visually inspected. See
  [light](swiftui-light.png), [dark](swiftui-dark.png) and
  [render verification](swiftui-verification.txt).

The test suite and icon conversion used native macOS service access. A sandbox
test run stalled in file-coordination error handling while waiting for
LaunchServices; the native run completed successfully.

The visual evidence consists of isolated renders of the production `NoemaMark`,
not screenshots of running application windows. Live macOS appearance and
accessibility toggles were not exercised. Numerical tests cover normal and
increased contrast; the mark always uses opaque fills. About continues to use
the native packaged application icon. Automatic Dock appearance switching
remains outside this `.icns` packaging workflow.
