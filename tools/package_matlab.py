#!/usr/bin/env python3
import hashlib
import zipfile
from pathlib import Path

from gates import digest

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {'artifacts', 'reports', 'build', 'measurements', '__pycache__', '.git'}


def main():
    files = [path for path in sorted(ROOT.rglob('*')) if path.is_file()
             and not any(part in EXCLUDED for part in path.relative_to(ROOT).parts)]
    expected = digest()
    output = ROOT / 'artifacts' / 'matlab_input.zip'
    output.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, ROOT.name + '/' + path.relative_to(ROOT).as_posix())
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        actual = hashlib.sha256()
        for path in files:
            relative = path.relative_to(ROOT).as_posix()
            actual.update(relative.encode())
            actual.update(archive.read(ROOT.name + '/' + relative))
        assert actual.hexdigest() == expected == digest()
    print(output)
    print(f'SOURCE SHA256: {expected}')


if __name__ == '__main__':
    main()
