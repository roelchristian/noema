# Canonical storage boundary sign-off

Date: 2026-10-11 (Asia/Manila). D01.6 follows the inventory in `.build/noema-storage-audit-20261011-01a12a5a.md` and the D01.2–D01.5 migrations. This audits the current working tree, including the existing D01.5 integration. The original inventory predates these migrations and its line numbers no longer describe current access.

Canonical byte reads, writes, snapshots, directory creation, moves and deletes use `VaultContentStore`: `vault.json`, Wiki Markdown, source originals and metadata, import staging, Removed Pages and legacy `.Trash` migration, Conflicts copies, and `Trash Retention.json`. `PlaintextVaultContentStore` is the sole runtime implementation. The final sweep found and closed the imported PDF summary-loading bypass in AppModel; it now uses `readSourceOriginal`, including path validation and checksum enforcement. Text summaries already use scanned source bodies. No format/version, encryption, database migration or UI changes are introduced.

## Permitted I/O exceptions

| Owner | Permitted access and limits |
| --- | --- |
| FileVaultRepository discovery | Directory enumeration, existence/permission checks, URL resource values, symlink/containment checks, `lstat`, bookmark resolution and security scope. These inspect names/attributes, not canonical bytes. iCloud hydration requests remain provider operations. |
| External source acquisition | Repository coordinatedRead/downloadCloudFile/readLinkedSource, AppModel's selected import-file read, and SourceReader's linked-file read may read user-selected external originals under existing coordination/security scopes. These helpers must never serve vault-owned canonical paths. Linked originals are never written or deleted. |
| OS conflict versions | Repository reads NSFileVersion URLs through coordinatedRead, preserves copies through the adapter, then resolves/removes OS-owned versions. Preserve all copies before resolution. Version discovery/resolution is outside the vault byte protocol. |
| VaultCreation parent operations | Create a sibling staging root, publish the entire initialized vault by a coordinated same-parent move, and clean failed staging. Canonical contents inside staging still use the adapter. Never merge an occupied destination. |
| RecoveryStore | App-local directory creation, atomic draft JSON reads/writes and explicit lifecycle deletion. Drafts can be the only unsaved copy; they are preservation data, not disposable cache. |
| SQLiteSearchIndex | App-local directory creation, SQLite connection and SQLite-managed WAL/SHM. Derived data is rebuildable; connection ownership remains in the index actor. |
| Preferences/capabilities | UserDefaults, theme/editor/macro settings and selected-folder bookmarks use OS-managed persistence outside the portable vault. |
| Native preview and observation | SourceReader gives Quick Look a source URL after adapter/checksum validation for imported originals. Quick Look can independently reread that URL; this is an explicit canonical read exception and is not a coherent snapshot guarantee. VaultWatcher registers file presenters/FSEvents; Finder reveal passes URLs to NSWorkspace. These platform services remain outside the adapter. |
| Network and fixtures | HTTP source capture/research uses existing fetchers; publication uses the adapter. Tests use disposable vaults and deliberate direct writes to simulate external edits. Development scripts, build outputs and generated brand exports are outside runtime canonical storage. |

## Enforcement and review

`python3 scripts/check-storage-boundary.py --selftest` checks every Swift file under Sources for known Foundation byte reads/writes, filesystem mutations, stream/handle creation, SQLite opens, generic coordinatedRead calls and URL-based PDF/Quick Look access. Test and build wrappers run the guard before Swift compilation. `scripts/storage-io-exceptions.json` records exact normalized statements, occurrence counts and ownership reasons; new or removed exceptional calls fail. Only the plaintext adapter is exempt from this scan. There is no automatic baseline update command.

This is a lightweight lexical code-review guard, not a Swift parser, security sandbox or proof of absence of I/O. Reviewers must inspect indirect APIs, newly introduced APIs/POSIX calls, root routing, Quick Look, metadata probes and adapter construction. Moving a permitted expression or changing its target without changing its text still requires semantic review. Every allowlist change must name an owner and exception above; canonical content must use the protocol. Tests and full build evidence are recorded in VALIDATION.md. No manual UI, actual provider hydration/conflict-version or two-Mac iCloud sign-off is implied.
