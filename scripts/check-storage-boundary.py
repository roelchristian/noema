#!/usr/bin/env python3
"""Review guard for known Swift byte-I/O APIs; not a Swift parser or sandbox."""
import collections
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
# Include method references as well as calls: assigning a known reader to a helper
# must not evade review. These names are intentionally conservative, not exhaustive.
IO = re.compile(r"""
    \b(?:Data|String|NSData|NSString)\s*(?:\.\s*init\s*)?\(\s*contentsOf(?:File)?\s*:
    |\.\s*write\s*\(\s*to(?:File)?\s*:
    |\.\s*write\s*\(\s*contentsOf\s*:
    |\.\s*read\s*\(\s*upToCount\s*:
    |\.\s*(?:moveItem|copyItem|removeItem|createFile|contents|replaceItemAt|linkItem|createSymbolicLink)\s*\(
    |\.\s*setAttributes\s*\(\s*[^\n]*?,\s*ofItemAtPath\s*:
    |\.\s*createDirectory\s*\(\s*at:\s*(?:[^(){};]|\([^(){};]*\))*?,\s*withIntermediateDirectories\s*:
    |\b(?:FileHandle|InputStream|OutputStream)\s*(?:\.\s*(?:init|forReading|forWriting|forUpdating)\s*)?\(
    |\.\s*(?:readToEnd|readDataToEndOfFile|readData|truncate|truncateFile)\s*\(
    |\bsqlite3_open(?:_v2)?\s*\(
    |(?<!func\s)\bcoordinatedRead\s*\(
    |\bPDFDocument\s*(?:\.\s*init\s*)?\(\s*url\s*:
    |\.\s*previewItem\s*=
    |\b(?:Darwin|Glibc)\s*\.\s*(?:open|openat|creat|read|write|pread|pwrite|fopen|freopen|fread|fwrite|mmap|unlink|unlinkat|rename|renameat|mkdir|mkdirat|rmdir|link|symlink|truncate|ftruncate)\b
    |(?<![.\w])(?:openat|creat|pread|pwrite|fopen|freopen|fread|fwrite|mmap|unlink|unlinkat|renameat|mkdir|mkdirat|rmdir|symlink|ftruncate)\s*\(
    |(?<![.\w])rename\s*\(\s*[^()\n:]+,\s*[^()\n:]+\)
    |(?<![.\w])open\s*\([^\n)]*,\s*O_[A-Z_]+\b
""", re.VERBOSE)
ADAPTER = "Sources/VaultCore/PlaintextVaultContentStore.swift"
PROVIDER = "Sources/VaultCore/VaultStorageProvider.swift"

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
    # Type aliases/metatype references can construct indirectly. Require review
    # of every runtime reference outside the implementation and selected provider.
    return [path for path, source in sources.items()
            if re.search(r"\bPlaintextVaultContentStore\b", source)
            and path not in (ADAPTER, PROVIDER)]

def fixture_selftest():
    fixture_root = ROOT / 'scripts/fixtures/storage-boundary'
    cases = json.loads((fixture_root / 'cases.json').read_text())
    for case in cases:
        source = (fixture_root / case['fixture']).read_text()
        actual = inventory({case['path']: source})
        allowed = collections.Counter({(e['path'], e['statement']): e['count']
                                       for e in case.get('allowed', [])})
        new, stale = violations(actual, allowed)
        observed = {'unreviewed': sum(new.values()), 'stale': sum(stale.values()),
                    'construction': len(construction_bypasses({case['path']: source}))}
        assert observed == case['expected'], f"{case['name']}: {observed} != {case['expected']}"
        # Cases deliberately accepted by the lexical scanner must explain the
        # semantic review they still need. Passing them is not boundary proof.
        if case.get('review_only'):
            assert case['reason'], f"{case['name']}: review-only fixture needs a reason"
    return len(cases)

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
    count = fixture_selftest()
    print(f'Storage boundary guard selftest passed (11 regression cases; {count} adversarial fixtures).')

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
        print("Unreviewed runtime adapter reference/construction: " + ", ".join(bypasses), file=sys.stderr)
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
