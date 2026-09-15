#!/usr/bin/env python3
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {'artifacts', 'reports', 'build', 'measurements', '__pycache__', '.git'}


def digest():
    value = hashlib.sha256()
    for path in sorted(ROOT.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if any(part in EXCLUDED for part in relative.parts):
            continue
        if path.suffix.lower() == '.md':
            continue
        value.update(relative.as_posix().encode())
        value.update(path.read_bytes())
    return value.hexdigest()


def main():
    action, stage = sys.argv[1:3]
    if stage not in {'matlab', 'sim'}:
        raise SystemExit('stage: matlab or sim')
    marker = ROOT / 'reports' / f'{stage}.pass'
    if action == 'clear':
        marker.unlink(missing_ok=True)
    elif action == 'check':
        if not marker.exists() or marker.read_text().strip() != digest():
            raise SystemExit(f'BLOCKED: run {stage} for the current source first.')
    elif action == 'mark':
        marker.parent.mkdir(exist_ok=True)
        marker.write_text(digest() + '\n')
    else:
        raise SystemExit('action: clear, check, or mark')


if __name__ == '__main__':
    main()
