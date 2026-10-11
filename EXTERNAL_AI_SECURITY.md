# External AI security architecture — D02A.1

Noema external AI is an opt-in application security boundary. Apple Intelligence remains independent: saving, title inference, LCC classification, page creation and source processing never silently fall back to cloud inference. D02A does not encrypt the plaintext vault or provide cryptographic vault locking.

## Trust and module boundary

`noema` owns explicit UI actions, consent, selected-item snapshots and publication through existing repositories. `ExternalAI` owns typed contracts, `ExternalAICredentialBroker`, `ExternalAISessionManager`, `ExternalAIGateway` and its restricted `OpenAITransport`. It depends on `VaultCore` for the existing D02 access gate, session lease and admission/completion boundaries. Credentials remain entirely inside the security module after masked entry. General app state obtains credential status and approved summary results only.

The trusted callers are the two explicit cloud-summary UI actions and the credential settings action. Caller-provided identity or a constructed consent receipt alone does not grant authorization. Gateway validation checks the live D02 lease, an issued authorization capability, and single-use per-submission consent. There is no generic prompt, arbitrary URL, tool execution, background cloud action or whole-vault submission API.

This beta implementation shares a process with UI code. Swift access control, actors, opaque capabilities and Keychain reduce accidental disclosure and ordinary caller misuse; they cannot protect secrets from arbitrary malicious code executing in that process. Debuggers, memory dumps, compromised dependencies and deliberately misused trusted callers remain risks. Do not claim otherwise.

A future dedicated XPC service can own Keychain, authentication, capability validation and restricted transport behind these same two actions. IPC must independently validate caller identity and operation limits; merely moving an arbitrary-text summarizer to XPC does not prevent compromised authorized callers from substituting text. Higher assurance requires an independently trusted content broker and authenticated vault/session authority.

## Operation inventory and exfiltration policy

| Operation | Approved source | Authority and destination | Limit and cancellation |
| --- | --- | --- | --- |
| `summarizePage` | Text snapshot of one explicitly selected page | Exact vault UUID, session UUID and generation; result returned only to that original page/request/revision | 64 KiB UTF-8 content; 8 KiB summary; 128 KiB response body; caller Task cancellation and lifecycle revocation |
| `summarizeSource` | Available extracted text snapshot of one explicitly selected source | Exact vault UUID, session UUID and generation; result returned only to that original source/request/revision | Same limits and cancellation |

Transmit only the selected text, a fixed provider-owned summarization instruction and configured model. Never transmit vault names, folder paths, UUIDs, revision IDs, file URLs, associated pages, other sources, frontmatter or unrelated metadata. Text itself may contain private information: the UI must disclose the provider and selected content before every new submission. A credential connection check may use a fixed provider metadata request with no vault content; it is not a general inference path.

Consent binds request UUID, target/action, authority, content revision and SHA-256 of the exact content snapshot. Each receipt is consumed once at the gateway; any bounded internal retry belongs to that same approved request. A changed snapshot needs fresh consent even when identifiers are accidentally reused. SHA-256 is local validation state, not transmitted or persisted provenance. Consent is evidence of trusted UI approval, not a cryptographic attestation of user interaction.

Page/source text and provider output are untrusted data. Prompt injection can ask the model to reveal content or act on instructions: fixed summarization instructions must label submitted text as data; do not expose tools, URLs or external side effects, follow output instructions, or render provider HTML unsafely. Limits and scope constrain disclosure even when the model disobeys. The summary cannot authorize another operation.

## Authorization lifecycle contract

States: unauthorized, authorizing, authorized, expired and revoked. Authentication coalesces concurrent prompts for the same precise vault authority. A cancelled, failed or outdated prompt fails closed and must not mint a capability. `LocalAuthentication` permits normal macOS authentication fallback when configured; it never replaces explicit content consent.

An authorized capability is opaque, binds vault UUID + D02 session UUID + UInt64 generation and the broker's credential-version UUID, and is validated against its issuing manager's live registry. Comparing a folder path or vault UUID alone is insufficient. Each open/unlock produces a distinct D02 session authority. Only authorized external-AI activity updates the idle timestamp. Default idle expiry is 30 minutes; absolute expiry is four hours from authentication. Custom policy may shorten, never extend, these limits. Ordinary editing, mouse activity and status reads do not renew authorization. Check time on every use, independently of timer delivery.

| Event | Required transition/effect |
| --- | --- |
| First deliberate summary without a valid capability | Authorizing; authenticate; authorize only if the original open authority remains current |
| Subsequent explicitly approved summary within lifetime | Reuse authorization; consume a fresh consent receipt |
| Idle/absolute timeout | Expired; reject further dispatch and publication, cancel outstanding requests |
| Vault locking, closing, switching, or any non-open phase | Revoke immediately; cancel operations; require new authorization even if locking later aborts |
| Sleep, macOS session lock, app termination | Revoke and cancel; next use authenticates again |
| Credential replacement, removal, local expiry or access revocation | Change credential-version UUID, revoke cached capabilities, cancel requests |

Local beta credential expiry may be an optional 30-day policy. It is not actual OpenAI key expiry or a provider spending limit. Provider-side spending limits, key expiry and revocation belong to the issuer.

The broker stores secrets only in a dedicated Keychain item, restricted to the application's signing identity/designated security component without unnecessary sharing entitlements. It must not return raw key strings through public APIs. Session authorization must not accidentally read a biometric-gated Keychain item afresh and reprompt on every summary: coordinate access through the broker's authenticated capability. Store/replacement/removal completes only after invalidating earlier credential authority.

## Dispatch, transport and publication

Gateway order: validate action and payload; match live gate/session authority; authenticate if needed; validate capability and credential version; validate and consume explicit consent; admit/register cancellable operation; recheck authority/cancellation at the transport dispatch boundary. Admission must be closed as soon as vault locking starts, including during an authentication await. There must be no stale authorization window between checking state and initiating I/O.

OpenAI requests use only the configured HTTPS OpenAI endpoint with a restricted Responses request shape and `store: false`. Reject cross-host redirects and unexpected response types/statuses; bound bytes while streaming, not only after allocating an unlimited response. Use a 60-second timeout and at most one bounded retry for transient failures, checking cancellation, session, consent operation identity and capability again before any retry. Never retry authentication or permanent request failures automatically. Inject mock transport for tests; tests must not need a real key or live network.

Return an immutable result retaining request UUID, target, content revision and authority. Before publication, verify cancellation, current issued capability, live D02 lease/generation, still-existing target, original selection/request identity, exact captured content/revision, and unchanged prior summary. Persist through existing page/source repository mechanisms only when all checks still hold. Independent local summary edits cannot be overwritten. Treat provider text as plain summary content, with validated provenance (provider, model, generation timestamp). Never persist session/capability/consent objects or request content as diagnostics.

Cancellation prevents subsequent dispatch and stale publication. It cannot recall data already delivered to OpenAI; retries can repeat transmission and provider billing. Already sent data remains governed by provider policy. `store: false` disables response persistence according to the [OpenAI Responses documentation](https://developers.openai.com/api/docs/guides/migrate-to-responses); it is not a promise of zero provider retention.

## Diagnostic and validation policy

Errors are a finite typed set with fixed user-facing descriptions. Underlying Keychain/LA errors, request/response bodies, Authorization headers, raw provider error strings, input and output text must not enter logs, crash diagnostics, preferences, journals or public errors. Request/result debug representations redact text. Reflection/memory access to live objects still falls within the documented in-process limitation.

Contract tests cover exact consent snapshots, precise authority identity, UTF-8 limits, bounded summaries, sanitized diagnostic representations and policy ceilings. Broker/session/gateway tests must additionally cover Keychain failures/replacement, authentication coalescing/cancellation, lock races, expiry, sleep/session events, redirect rejection, bounded responses, retries and stale publication. Existing storage guard and native tests remain release gates. Device validation must exercise biometric success, cancellation and permitted macOS fallback; test doubles cannot establish those platform guarantees.
