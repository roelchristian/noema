#!/usr/bin/env python3
"""Keep 16 representative before/after pairs; hash the full rendered matrix."""
import hashlib
import json
import shutil
from pathlib import Path

root = Path(__file__).resolve().parent
modes = [f"{theme}-{scheme}-{contrast}" for theme in ("system", "midnightIris")
         for scheme in ("light", "dark") for contrast in ("standard", "increased")]
selected = [f"workspace-minimum-{mode}.png" for mode in modes]
selected += [f"inspector-minimum-{mode}.png" for mode in (
    "system-light-standard", "system-dark-increased", "midnightIris-dark-standard", "midnightIris-light-increased")]
selected += ["sources-native-table-system-light-standard.png", "workspace-locked-midnightIris-dark-standard.png",
             "workspace-no-vault-system-light-standard.png", "vault-creation-sheet-content-midnightIris-dark-standard.png"]
manifest = {"fixture": "DesignTokenValidationTests.swift",
            "fixture_sha256": hashlib.sha256((root.parents[1] / "Tests/NoemaEditorTests/DesignTokenValidationTests.swift").read_bytes()).hexdigest(),
            "captures": {}, "source_refs": {}, "platforms": {}}
for source, destination in (("baseline", "before"), ("after", "after")):
    generated = root / "generated" / source
    manifest["source_refs"][source] = (generated / "source-ref.txt").read_text().strip()
    manifest["platforms"][source] = (generated / "platform.txt").read_text().strip()
    files = sorted(generated.glob("*.png"))
    if len(files) != 136:
        raise SystemExit(f"Expected 136 {source} captures, found {len(files)}")
    manifest["captures"][source] = {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in files}
    evidence = root / "evidence" / destination
    evidence.mkdir(parents=True, exist_ok=True)
    for name in selected:
        shutil.copy2(generated / name, evidence / name)
manifest["committed_pairs"] = selected
(root / "capture-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
