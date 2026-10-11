# Storage-boundary adversarial fixtures

These Swift snippets are scanner inputs, not compiled runtime code. Run them with
`python3 scripts/check-storage-boundary.py --selftest`; the same command also checks
the current runtime inventory. `cases.json` specifies exact new/stale I/O counts
and adapter-reference findings independently of the production exception file.

The fixtures exercise helper-contained byte reads, initializer references,
additional Foundation/POSIX APIs (including handle byte methods/references and
FileManager attribute mutation), adapter aliases, and exception misuse by path,
count, target, and enclosing helper. They include accepted adapter/protocol paths
to distinguish intended routing from flagged direct access.

`review_only` cases deliberately record lexical blind spots: an existing allowed
statement can be retargeted or moved to a different helper in the same file; an
opaque imported helper or ambiguous unqualified function reference can conceal
I/O. Their passing scanner result is evidence of a limitation, not authorization
to use the code. Review the PR storage checklist and trace targets/callees even
when the guard passes. Extending the API vocabulary does not make the guard a
Swift parser or data-flow analyzer.
