#!/usr/bin/env python3
"""Verify saved evidence and source preservation, including the C readability edit."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

from check_golden_equivalence import BASELINE, BASELINE_SHA256

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    scopes = ['common/reset_sync.v', 'fourier/rtl', 'fourier/firmware',
              'data', 'measurements', 'artifacts/experiments']
    changed = subprocess.check_output(
        ['git', 'diff', '--name-only', 'HEAD', '--', *scopes],
        cwd=ROOT, text=True).splitlines()
    # User-authorized C readability changes require a numerical/protocol proof.
    # Original RTL, model tables, recordings and stored evidence stay protected.
    golden_name = 'fourier/firmware/golden.c'
    firmware_edits = {'fourier/firmware/main.c', 'fourier/firmware/host_check.c',
                      'fourier/firmware/golden.h'}
    unexpected = set(changed) - {golden_name} - firmware_edits
    assert not unexpected, f'Protected source/data changed: {sorted(unexpected)}'
    tracked = subprocess.check_output(['git', 'ls-files', '--', *scopes],
                                      cwd=ROOT, text=True).splitlines()
    refactored = {}
    if sha256(ROOT / golden_name) != BASELINE_SHA256:
        assert sha256(BASELINE) == BASELINE_SHA256, 'Original Golden model changed'
        subprocess.run([sys.executable, str(ROOT / 'tools/check_golden_equivalence.py')],
                       cwd=ROOT, check=True)
        equivalence = json.loads((ROOT / 'reports/golden_equivalence.json').read_text())
        assert equivalence['status'] == 'PASS'
        assert equivalence['source_sha256'][golden_name] == sha256(ROOT / golden_name)
        refactored[golden_name] = dict(
            original_sha256=BASELINE_SHA256,
            current_sha256=sha256(ROOT / golden_name),
            equivalence_report='reports/golden_equivalence.json',
            compared_frames=equivalence['total_frames'])
    if set(changed) & firmware_edits:
        baseline_root = ROOT / 'docs/evidence/readability_complete_2026-11-15/before'
        originals = {}
        for name in firmware_edits:
            original = subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT)
            digest = hashlib.sha256(original).hexdigest()
            assert sha256(baseline_root / name) == digest, f'Original firmware changed: {name}'
            originals[name] = digest
        subprocess.run([sys.executable, str(ROOT / 'tools/check_firmware_equivalence.py')],
                       cwd=ROOT, check=True)
        proof = json.loads((ROOT / 'reports/firmware_equivalence.json').read_text())
        assert proof['status'] == 'PASS' and proof['result_layout']['status'] == 'PASS'
        for name in firmware_edits:
            assert proof['source_sha256'][name] == sha256(ROOT / name)
            refactored[name] = dict(original_sha256=originals[name], current_sha256=sha256(ROOT / name),
                                   equivalence_report='reports/firmware_equivalence.json')
    snapshot = {name: sha256(ROOT / name) for name in tracked if name not in refactored}
    manifest = json.loads((ROOT / 'docs/evidence/capture_manifest.json').read_text())
    for name, expected in manifest['files'].items():
        assert sha256(ROOT / name) == expected, f'Historical evidence changed: {name}'
    dataset = json.loads((ROOT / 'data/dataset_source.json').read_text())
    captures = {}
    for run in dataset['source_runs']:
        csv = run['file']
        metadata = str(Path(csv).with_suffix('.json'))
        for name, expected in [(csv, run['sha256']), (metadata, run['metadata_sha256'])]:
            assert sha256(ROOT / name) == expected, f'Recorded input changed: {name}'
            captures[name] = expected
    result = dict(status='PASS', original_tracked_files=len(snapshot),
                  tracked_scope_files=len(tracked),
                  refactored_sources=refactored,
                  historical_evidence_files=len(manifest['files']),
                  recorded_capture_files=len(captures),
                  preserved_files=snapshot, capture_files=captures)
    output = ROOT / 'reports/vhdl_preservation.json'
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(f'PASS: {len(snapshot)} original files, {len(manifest["files"])} historical evidence hashes, '
          f'{len(captures)} original capture hashes unchanged; '
          f'{len(refactored)} readable C sources verified against original numerical/protocol behavior.')


if __name__ == '__main__':
    main()
