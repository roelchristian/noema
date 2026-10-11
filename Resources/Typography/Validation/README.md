# Typography validation evidence

- `full-tests.log`: pre-merge typography suite, 285 tests / 32 suites, 64.784 seconds; exit 0.
- `capture-tests.log`: final pre-merge native fixture export, 6 tests / 1 suite, 27.374 seconds; exit 0.
- `source-sha256.txt`: production sources and capture fixtures used for the screenshots at typography commit `2c68a2d`. This intentionally remains unchanged after integration.
- `merged-main-tests.log`: complete suite after joining `2c68a2d` with main `d74a938`, 311 tests / 34 suites, 30.476 seconds; exit 0.
- `merged-main-source-sha256.txt`: all tracked production sources and the same capture fixtures on the integrated tree. Final merge amendment changes documentation/evidence only.

The native typography renderers and capture fixtures are unchanged by the merge. Source hashes outside those files differ because current main introduces native toolbar/workspace changes and removes the old traffic-light helper. See [the validation report](../../../UI_TYPOGRAPHY_VALIDATION.md) for scope and live-check limits.
