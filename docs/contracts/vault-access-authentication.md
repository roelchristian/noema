# Plaintext vault access authentication

Noema can require native macOS authentication before opening or unlocking a plaintext
vault. This opt-in application preference protects against casual access through the
supported Noema workflow. It does not encrypt canonical files, SQLite/WAL data,
recovery drafts, preview copies or linked originals. It does not defend against
filesystem access, preference tampering, a debugger, a modified binary or arbitrary
malicious code in the application process.

## Preference ownership and compatibility

`VaultAccessPolicyStore` persists a Boolean and a revision identifier in app-local
UserDefaults under `noema.vault-access-authentication.v1.<vault UUID>` and its
`.revision` companion. Identity is the exact manifest UUID, not a path or vault name.
The preference applies on this Mac; it is not stored in `vault.json`, synced as part
of the portable vault or a cryptographic format flag. Missing preferences preserve
ordinary unauthenticated plaintext opening. Existing manifest/Markdown formats,
bookmarks, drafts and derived indexes remain compatible.

Production policy writes belong to `VaultSessionManager`. Both enabling and disabling
require a fresh native authentication attempt bound to the exact currently open
session. A newly created vault can opt in before its first opening: the existing
staged publisher supplies a fresh UUID, the manager registers its preference, and
the first open then authenticates. Authentication failure preserves the created
vault and preference so opening can be retried. Encryption requests remain rejected.

## Admission and lifecycle

The public production `open`, `openRepository`, `unlock` and `unlockRepository`
routes enforce the same preference. Production construction fixes
`LocalNativeAuthenticator` and the standard preference store. Alternate authenticators,
isolated preferences and closure-based loaders are internal `@testable` seams, not
public production admission paths. The lower-level plaintext repository/provider
APIs remain storage APIs; they do not claim to enforce native authentication against
arbitrary in-process callers.

Before authentication, manifest and directory safety inspection may establish vault
identity and permissions through the existing selected storage provider. Wiki/source
content, the search index and recovery drafts are not loaded or presented until
admission. While a protected open/unlock attempt is pending, the lifecycle stays
`closed` or `locked`; policy-change authentication retains its already open session.
The existing six phases are unchanged.

The manager privately owns a single attempt bound to its unique attempt UUID,
normalized root, exact vault UUID, intended action, captured lifecycle state and
generation, and preference snapshot/revision. After native success it rechecks those
bindings, caller cancellation, root normalization and the current manifest UUID.
The attempt is consumed on the manager actor. No caller-provided success Boolean,
reusable grant or fabricated approval is accepted as admission proof for a different
operation.
The admitting preference snapshot/revision is also revalidated at the final actor
commit to `open`, after asynchronous manifest loading and the final identity read.
The shared production policy mutex serializes the final snapshot comparison and
synchronous session commit with supported preference writes. Preference changes use
the same compare/write boundary. No storage I/O, await or nested policy-store call
is permitted under that mutex. Lock order is policy then session gate; gate callbacks
must never acquire the policy lock. External preference tampering is outside this
registry guarantee.

Cancellation, accepted close/lock and explicit transition cancellation invalidate pending
admission before cancelling native work. Rejected stale session-scoped rollback requests
must leave newer admission ownership intact. A new target open invalidates a prior target
attempt. Late native completion cannot resurrect admission, including when a test
authenticator ignores cancellation. Open/unlock failure retains `closed` or `locked`;
policy-change failure retains the active session and existing preference. Reopening
after close and opening after app restart require fresh authentication. Returning an
already open session for the same root does not create another content admission.

Permission recovery by reselecting the same locked folder uses the ordinary unlock
route. Unlock repository construction requires the candidate's normalized root to
match the captured locked root and its manifest UUID to match the locked identity;
a different folder with a copied UUID cannot obtain that lease. Successful admission
then uses the existing D02 generation/lease, gated repository, recovery and index
construction. Resource initialization failure rolls back only the session it owns.

Native attempt success grants no ExternalAI capability. ExternalAI still requires
its own operation purpose, precise live vault authority, credential-version checks,
expiry and explicit per-submission consent; see the [external AI contract](external-ai.md).
Storage author/reviewer tracing remains required by the
[storage boundary](storage-boundary.md#required-author-and-reviewer-disposition).
Actual Touch ID, password fallback, OS cancellation, app switching and accessibility
remain [device acceptance](../validation.md#native-authentication-device-acceptance).

Deterministic scenarios live in
[VaultAuthenticationAdmissionTests](../../Tests/VaultCoreTests/VaultAuthenticationAdmissionTests.swift)
and [VaultAuthenticationIntegrationTests](../../Tests/NoemaEditorTests/VaultAuthenticationIntegrationTests.swift).
They exercise specified interleavings and preservation checks; they do not establish
every possible task schedule or real macOS dialog behavior.
