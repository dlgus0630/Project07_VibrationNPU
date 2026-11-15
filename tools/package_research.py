#!/usr/bin/env python3
"""Package MATLAB research sources and the Korean guide for MATLAB Drive.

The archive contains the same gate-tracked sources as package_matlab.py, plus
the research guide. It does not contain generated or previously validated SLX
files. RUN_RESEARCH_STUDY generates the new model inside MATLAB/Simulink.
"""
import hashlib
import json
import zipfile
from pathlib import Path

from gates import EXCLUDED, ROOT, digest


def main():
    documentation = [ROOT / 'docs' / name for name in
                     ('MATLAB_SIMULINK_RESEARCH.md', 'STUDY_CODE_NOTES.md', 'REAL_DATASET.md', 'HARDWARE.md')]
    documentation.append(ROOT / 'artifacts' / 'hardware_validation_2026-09-14.md')
    for path in documentation:
        assert path.is_file(), f'Missing documentation: {path}'
    reference_outputs = [ROOT / 'reports' / 'research_offline' / name for name in
                         ('reference_check.json', 'reference_preview_3d.png', 'VALIDATION.md')]
    reference_outputs = [path for path in reference_outputs if path.is_file()]
    files = [p for p in sorted(ROOT.rglob('*')) if p.is_file()
             and not any(part in EXCLUDED for part in p.relative_to(ROOT).parts)]
    tracked = [p for p in files if p.suffix.lower() != '.md']
    source_hash = digest()
    output = ROOT / 'artifacts' / 'matlab_research_input.zip'
    output.parent.mkdir(exist_ok=True)
    manifest = {
        'source_sha256': source_hash,
        'entrypoint': "RUN_RESEARCH_STUDY('ripple')",
        'guide': 'docs/MATLAB_SIMULINK_RESEARCH.md',
        'new_slx_included': False,
        'measured_capture_inputs_included': False,
        'readme_figure_export_requires_full_repository': True,
        'matlab_execution': 'NOT_RUN_IN_BUILD_ENVIRONMENT',
        'files': {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in tracked},
    }
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in [*files, *documentation, *reference_outputs]:
            if path == ROOT / 'README.md':
                continue
            archive.write(path, ROOT.name + '/' + path.relative_to(ROOT).as_posix())
        archive.writestr(ROOT.name + '/README.md', """# MATLAB·Simulink 6자유도 연구 패키지

압축을 풀고 RUN_RESEARCH_STUDY.m이 있는 폴더에서 실행합니다.

```matlab
RUN_RESEARCH_STUDY('ripple')
```

질량·강성·감쇠·가진력은 연구용 가정값이며 실측 XYZ가 아닙니다.
이 패키지는 연구 모델과 기존 정수 Golden 소스, 연구 설명서를 제공합니다.
공식 Golden 검증은 RUN_MATLAB_CHECKS, 연구 전체 시나리오는
RUN_RESEARCH_STUDY('all')로 실행합니다. 새 MATLAB·Simulink 실행 검증은 아직 남아 있습니다.

실측 센서 CSV와 모터 telemetry 원본은 이 ZIP에 포함되지 않습니다.
실측 재현에는 별도 matlab_measured_input.zip을 사용하고 RUN_MEASURED_STUDY를 실행합니다.
소스 지문을 유지하기 위해 실측 함수와 EXPORT_README_FIGURES 소스도 함께 들어 있지만,
그 함수들은 이 연구 ZIP만으로 실행할 수 없습니다. README의 전체 그림 내보내기는
실측 원본과 모든 소스가 있는 전체 저장소에서 수행해야 합니다.

- [6자유도 연구 가이드](docs/MATLAB_SIMULINK_RESEARCH.md)
- [한국어 코드 각주 안내](docs/STUDY_CODE_NOTES.md)
- Python 독립 수치 참조: reports/research_offline/ (MATLAB 실행 결과가 아님)
""")
        archive.writestr(ROOT.name + '/artifacts/research_source_manifest.json',
                         json.dumps(manifest, indent=2) + '\n')
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        actual = hashlib.sha256()
        for path in tracked:
            relative = path.relative_to(ROOT).as_posix()
            actual.update(relative.encode())
            actual.update(archive.read(ROOT.name + '/' + relative))
        assert actual.hexdigest() == source_hash == digest(), 'Source changed while packaging.'
        assert ROOT.name + '/RUN_RESEARCH_STUDY.m' in archive.namelist()
        assert ROOT.name + '/docs/MATLAB_SIMULINK_RESEARCH.md' in archive.namelist()
    print(output)
    print(f'SOURCE SHA256: {source_hash}')
    print('New Simulink model: generated when RUN_RESEARCH_STUDY executes in MATLAB.')


if __name__ == '__main__':
    main()
