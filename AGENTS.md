# Noema Agent Policy

Before starting work, read `AGENTS.local.md` if it exists and follow its
local setup-specific rules.

## Authoritative documentation

- `README.md` is the human entry point.
- `docs/architecture.md` describes current architecture.
- `docs/contracts/` contains durable technical invariants.
- `docs/development.md` gives reproducible procedures and local retention rules.
- `docs/validation.md` records current baselines, limitations and acceptance work.
- Source and tests remain authoritative when documentation disagrees with them.
- Reconcile discrepancies explicitly rather than silently changing a contract.

## Documentation discipline

- Do not create root milestone/task reports, implementation journals or validation Markdown.
- Create a permanent document only for a lasting contract, decision or procedure
  not reasonably covered by an existing authoritative document.
- Update existing documents in place; replace superseded statements.
- Do not append execution chronology to permanent documentation.
- Keep research, handoffs, logs and intermediate notes in `.local/agent-runs/`.
- Do not commit generated screenshots, raw logs, transcripts or intermediate reports.
- Link to contracts and tests instead of duplicating their contents.
- Durable decisions belong in `docs/decisions/`; history stays in Git history.
- Run `python3 scripts/check-repository-hygiene.py --selftest` before completion.
- Path/artifact rules are hard failures; document-size limits are warnings.
- Never shorten safety contracts or suppress failure evidence to meet a size limit.

## Validation policy

- Execute appropriate tests and report actual outcomes; never claim unrun tests passed.
- Record commands, pass/fail/not-run, environment, limitations and manual checks in the PR.
- Normally keep the PR validation record within 15 lines, excluding necessary failure detail.
- Do not append routine passing test runs to `docs/validation.md`.
- Change that document only for a material baseline, procedure, limitation or acceptance change.
- Retain full diagnostics locally under the cleanup policy in `docs/development.md`.
- Attach screenshots needed for human review to the PR or designated review artifact.
- A permanent generated fixture needs explicit review and an exact path/reason in
  `scripts/repository-hygiene-fixtures.json`; extension or size alone never justifies deletion.
- Preserve standing device, accessibility and crash-durability acceptance gaps.

## Local evidence lifecycle

- Use `.local/agent-runs/<run-id>/`, with a simple run ID rather than an arbitrary path.
- Mark running work `.active`; use `.pinned` for evidence requiring longer retention.
- Mark finished work `.complete`, including failures; failures also use `.failed`.
- Remove `.active` only after execution has stopped.
- Cleanup requires `.complete`, defaults to seven days and protects active/pinned runs.
- Use `./scripts/cleanup-local-evidence.sh --older-than 7d --dry-run --protect-active`
  to inspect eligible runs before manual cleanup.
- `--force` bypasses age only; it does not override protection or completion requirements.
- Successful test/build wrappers clean aged completed local evidence.
- Put private local instructions in ignored `AGENTS.local.md`.

## Safety and repository boundaries

- Preserve test fixtures, canonical resources and architectural enforcement checks.
- Storage changes require the author and reviewer procedure in
  `docs/contracts/storage-boundary.md`; scanner success alone does not satisfy review.
- Do not broaden I/O exceptions without reviewed ownership and target routing.
- Never delete user vault data or files outside the managed evidence directory.
- Preserve active and pinned runs and failure diagnostics until retention expires.
- Recovery drafts are preservation data, not disposable evidence or cache.
- Application session locking is not encryption; local save is not iCloud delivery.
- Keep independent changes reviewable; do not mix housekeeping with runtime refactors.

## Completion

- Update only relevant authoritative documents.
- Provide a succinct PR summary and actual validation record.
- Do not create a separate completion report unless explicitly requested.
- Leave no untracked evidence outside approved local directories.
