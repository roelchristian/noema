Describe the problem and resulting behavior.

## Validation

- Build: PASS / FAIL / NOT RUN (command)
- Tests: PASS / FAIL / NOT RUN (command, count or suites)
- Hygiene check: PASS / FAIL (command)
- Storage boundary: N/A / Reviewed (author disposition)
- Manual UI: PASS / NOT RUN (reason)
- Environment: relevant OS/toolchain
- Open limitations: None / concise description
- Evidence: local, untracked; attach visual review artifacts when needed
- Docs changed: current contracts only / explain lasting additions

Storage construction, canonical access or I/O exceptions require the author and
reviewer to follow the [storage review procedure](../docs/contracts/storage-boundary.md#required-author-and-reviewer-disposition).
The reviewer records its own completion or explicit N/A and unresolved limits in
review; a passing scanner alone does not complete semantic review.
