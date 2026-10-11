#!/usr/bin/env python3
"""Review guard for known Swift byte-I/O APIs; not a Swift parser or sandbox."""
import collections
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
# Include calls to the generic external reader: canonical callers must use the adapter.
IO = re.compile(r"\b(?:Data|String|NSData|NSString)\s*\(\s*contentsOf(?:File)?\s*:|\.write\s*\(\s*to\s*:|\.(?:moveItem|copyItem|removeItem|createFile)\s*\(|\b(?:fm|FileManager\.default)\.createDirectory\s*\(|\b(?:FileHandle|InputStream|OutputStream)\s*\(|\bsqlite3_open(?:_v2)?\s*\(|(?<!func )\bcoordinatedRead\s*\(|\bPDFDocument\s*\(\s*url\s*:|\.previewItem\s*=")
ADAPTER = "Sources/VaultCore/PlaintextVaultContentStore.swift"

def inventory(sources):
    result = collections.Counter()
    for path, source in sources.items():
        if path == ADAPTER:
            continue
        for match in IO.finditer(source):
            start = source.rfind("\n", 0, match.start()) + 1
            end = source.find("\n", match.end())
            line = source[start:end if end >= 0 else len(source)]
            result[(path, " ".join(line.split()))] += 1
    return result

def violations(actual, allowed):
    return actual - allowed, allowed - actual

def construction_bypasses(sources):
    return [path for path, source in sources.items()
            if re.search(r"\bPlaintextVaultContentStore\s*\(", source)
            and path != "Sources/VaultCore/VaultStorageProvider.swift"]

def selftest():
    sample = {'Sources/VaultCore/NewStore.swift': 'try Data(contentsOf: url)'}
    assert violations(inventory(sample), collections.Counter())[0]
    assert inventory({ADAPTER: sample[next(iter(sample))]}) == {}
    allowed = inventory(sample)
    assert violations(inventory(sample), allowed) == ({}, {})
    assert violations(inventory({next(iter(sample)): 'try Data(\n contentsOf: url)'}), allowed)[0]
    assert violations(inventory({next(iter(sample)): sample[next(iter(sample))] + '\n' + sample[next(iter(sample))]}), allowed)[0]
    assert violations(collections.Counter(), allowed)[1]
    assert inventory({'Sources/noema/New.swift': 'FileVaultRepository.coordinatedRead(url)'})
    assert not inventory({'Sources/noema/New.swift': 'try contentStore.read(at: path)\ntry contentStore.write(data, at: path, condition: .createOnly)'})
    assert construction_bypasses({'Sources/noema/Reader.swift': 'try PlaintextVaultContentStore(root: root)'})
    assert construction_bypasses({'Sources/VaultCore/VaultCreation.swift': 'try PlaintextVaultContentStore(\nroot: root)'})
    assert not construction_bypasses({'Sources/VaultCore/VaultStorageProvider.swift': 'try PlaintextVaultContentStore(root: root)'})
    print('Storage boundary guard selftest passed (11 cases).')

def main():
    if '--selftest' in sys.argv:
        selftest()
    entries = json.loads((ROOT / 'scripts/storage-io-exceptions.json').read_text())
    allowed = collections.Counter()
    for entry in entries:
        assert entry['reason'], 'Every exception needs a reviewed ownership reason'
        allowed[(entry['path'], entry['statement'])] += entry['count']
    actual = inventory({str(p.relative_to(ROOT)): p.read_text() for p in (ROOT / 'Sources').rglob('*.swift')})
    bypasses = construction_bypasses({str(p.relative_to(ROOT)): p.read_text() for p in (ROOT / 'Sources').rglob('*.swift')})
    if bypasses:
        print("Unreviewed adapter construction: " + ", ".join(bypasses), file=sys.stderr)
        return 1
    new, stale = violations(actual, allowed)
    for kind, items in [('Unreviewed I/O', new), ('Stale exception', stale)]:
        for (path, statement), count in sorted(items.items()):
            print(f'{kind}: {path}: {statement} (x{count})', file=sys.stderr)
    if new or stale:
        print('Route canonical I/O through VaultContentStore; review exceptional ownership against STORAGE_ACCESS_AUDIT.md before changing the allowlist.', file=sys.stderr)
        return 1
    print(f'Storage boundary guard passed: {sum(actual.values())} reviewed exceptional calls; canonical byte I/O belongs in {ADAPTER}.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
