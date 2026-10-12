# Noema

**A personal atlas of thought.**

Noema is a native macOS personal wiki with a read-only source library, structured block and TeX math editing, optional on-device Apple Intelligence, portable plaintext storage, and provider-selected content enrichment and reviewed AI page creation.

## Build and quick start

Requires macOS 26+, Apple's Swift 6 command-line tools and internet access for the first dependency download. Full Xcode is optional; dependencies are pinned in `Package.resolved`.

```sh
./scripts/run.sh
# Or package a locally signed release:
./scripts/build.sh release
open "dist/noema.app"
# Run the native regression suite:
./scripts/test.sh
```

Open `Examples/Demo Vault` for a tour, or choose **Create a vault** and select a parent folder. Keep personal vaults outside this repository. Pages are editable Markdown; imported originals retain their bytes, and linked originals remain read-only.

Vault locking revokes access inside Noema. You can require native macOS authentication when opening or unlocking a vault, including after reopening or restarting Noema, through the creation dialog or **Settings → Vault access on this Mac**. This opt-in preference applies on this Mac and protects against casual access through Noema. Canonical files, indexes, drafts, previews and linked originals remain plaintext. Encrypted creation is disabled pending cryptographic storage. **Saved locally** confirms this Mac's save; two-Mac iCloud transport acceptance remains pending.

Selected page/source enrichment generates a summary and verified classification together; existing human titles and page bodies are preserved. **Create Page with AI** drafts from a source, researched topic or locally fetched URL with either supported provider, then asks for review before publication. Properties displays read-only classification; **Suggest Title** remains a reviewed action. Intelligence settings choose providers and OpenAI submission confirmation: Always ask (default), once per unlocked vault session, or never ask. Each request still requires authenticated, request-bound authority. Native macOS authentication permits system-password fallback; vault admission does not grant OpenAI authorization. Preferences preserve stored content and never initiate background cloud submissions. Keys stay in Keychain; cancellation cannot recall transmitted text and API use can incur charges. See the [external AI contract](docs/contracts/external-ai.md) and [pending device/provider acceptance](docs/validation.md#d02a-device-acceptance-checklist).

## Documentation

- [Development and everyday workflow](docs/development.md): build, commands, file format and local evidence retention.
- [Architecture](docs/architecture.md): components, concurrency, storage and session lifecycle.
- Contracts: [storage boundary](docs/contracts/storage-boundary.md), [vault access authentication](docs/contracts/vault-access-authentication.md), [design tokens](docs/contracts/design-tokens.md), [source scanning](docs/contracts/source-scanning.md), [block editor](docs/contracts/block-editor.md).
- [Validation](docs/validation.md): standing checks, performance expectations and unresolved acceptance.
- [Agent policy](AGENTS.md): repository and documentation discipline.
- [Brand assets](Resources/Brand/README.md): canonical identity resources and reproducible exports.
