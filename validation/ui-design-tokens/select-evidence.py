#!/usr/bin/env python3
"""Select local PR-review images and hash both full matrices in a managed run."""
import argparse
import hashlib
import json
import shutil
import sys
sys.dont_write_bytecode = True
from pathlib import Path

root = Path(__file__).resolve().parent
sys.path.insert(0, str(root.parents[1] / 'scripts'))
import local_evidence as local


def select(run_id):
    fd = local.open_run(run_id)
    locked = False
    try:
        local.inspect_tree(fd, local.os.fstat(fd).st_dev)
        local.os.mkdir('.active', dir_fd=fd)
        locked = True
        run = local.REPO / '.local/agent-runs' / run_id
        modes = [f'{theme}-{scheme}-{contrast}' for theme in ('system', 'midnightIris')
                 for scheme in ('light', 'dark') for contrast in ('standard', 'increased')]
        selected = [f'workspace-minimum-{mode}.png' for mode in modes]
        selected += [f'inspector-page-properties-280-{mode}.png' for mode in (
            'system-light-standard', 'system-dark-increased',
            'midnightIris-dark-standard', 'midnightIris-light-increased')]
        selected += ['sources-native-table-system-light-standard.png', 'workspace-locked-midnightIris-dark-standard.png',
                     'workspace-no-vault-system-light-standard.png', 'vault-creation-sheet-content-midnightIris-dark-standard.png']
        fixture = local.REPO / 'Tests/NoemaVisualValidationTests/DesignTokenCaptureTests.swift'
        manifest = {'fixture': str(fixture.relative_to(local.REPO)),
                    'fixture_sha256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
                    'captures': {}, 'source_refs': {}, 'platforms': {}, 'review_pairs': selected}
        # Validate both matrices before creating any review outputs.
        for source in ('baseline', 'after'):
            generated = run / source
            files = sorted(generated.glob('*.png'))
            expected = (8 * 3 + 12) * len(modes) # All page/source tabs at three widths plus workspace fixtures
            if len(files) != expected:
                raise ValueError(f'Expected {expected} {source} captures, found {len(files)}')
            missing = set(selected) - {file.name for file in files}
            if missing:
                raise ValueError(f'Missing representative {source} captures: {sorted(missing)}')
            manifest['source_refs'][source] = (generated / 'source-ref.txt').read_text().strip()
            manifest['platforms'][source] = (generated / 'platform.txt').read_text().strip()
            manifest['captures'][source] = {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in files}
        for source, destination in (('baseline', 'before'), ('after', 'after')):
            evidence = run / 'evidence' / destination
            evidence.mkdir(parents=True, exist_ok=True)
            for name in selected:
                shutil.copy2(run / source / name, evidence / name)
        (run / 'capture-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        if local.exists(fd, '.failed'):
            local.os.unlink('.failed', dir_fd=fd)
        local.marker(fd, '.complete')
        print(f'Local review evidence: {run / "evidence"}\nLocal manifest: {run / "capture-manifest.json"}')
    except Exception:
        if locked:
            local.marker(fd, '.failed')
            local.marker(fd, '.complete')
        raise
    finally:
        if locked:
            local.os.rmdir('.active', dir_fd=fd)
        local.os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    try:
        select(args.run_id)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
