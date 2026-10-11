Describe the problem, resulting behavior, and relevant validation.

Storage-boundary review is required for changes to runtime storage construction,
canonical access, or I/O exceptions. Mark this section N/A only when none apply.
The author and reviewer must inspect the changed code; a passing lexical guard
does not complete this review.

- [ ] Trace each changed storage target and helper call to its owner. Canonical
      vault bytes and mutations use `VaultContentStore`, including indirect or
      newly introduced Foundation/POSIX/third-party APIs.
- [ ] Verify runtime adapter construction remains in `VaultStorageProvider` and
      selected stores, roots, and session leases reach every affected consumer;
      inspect aliases, factories, and dependency injection too.
- [ ] For every exception change, explain its permitted owner and target in
      `STORAGE_ACCESS_AUDIT.md`, inspect enclosing helpers and callers, and verify
      targets stay outside canonical paths. Review unchanged allowed expressions when
      their variables, target URLs, or enclosing helper ownership change.
- [ ] Check preview/error/lock/switch lifecycle handling and preservation or
      cleanup policy where affected; do not equate cleanup with secure deletion.
- [ ] Run `python3 scripts/check-storage-boundary.py --selftest` and relevant
      adapter/lifecycle tests. Add an adversarial fixture for new guard vocabulary
      or document any remaining review-only blind spot.
- [ ] Reviewer records completion of this storage review (or an explicit N/A)
      and any unresolved limitations in the review.
