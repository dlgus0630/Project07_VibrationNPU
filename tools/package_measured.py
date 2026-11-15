#!/usr/bin/env python3
"""Build a standalone, actual-measurements-only MATLAB/Simulink input ZIP.

No synthetic research sources, plant parameters, generated samples or old SLX
artifacts are included. Model files are generated when MATLAB executes the
measured entry point. Original capture bytes are copied without rewriting.
"""
import csv
import hashlib
import json
import math
from pathlib import Path
import zipfile

from check_measured_replay import generate

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'Project07_VibrationNPU_Measured'
MOTOR_NAMES = (
    'open_loop_identification', 'step_original_gains', 'step_candidate_gains',
    'disturbance_2026-09-16_v4_final', 'disturbance_2026-09-16_v5_repeat',
)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit_motor(root):
    """Independently check recorded counters/codes and archived unit exports."""
    columns = ['sample', 'time_s', 'reference_q12', 'measured_q12', 'duty_q12',
               'integral_q12', 'armed', 'fault', 'enabled',
               'target_rpm', 'measured_rpm', 'duty_percent']
    records = []
    for name in MOTOR_NAMES:
        relative = f'artifacts/experiments/{name}.csv'
        path = root / relative
        with path.open(newline='', encoding='utf-8') as handle:
            reader = csv.DictReader(handle)
            assert reader.fieldnames == columns, f'Unexpected motor schema: {name}'
            rows = [{key: float(value) for key, value in row.items()} for row in reader]
        assert len(rows) >= 2
        previous = None
        missing = 0
        for r in rows:
            assert all(math.isfinite(x) for x in r.values()), name
            for key in ['sample', *columns[2:9]]:
                assert r[key].is_integer(), (name, key)
            assert r['sample'] >= 0 and abs(r['time_s'] - r['sample'] / 100) < 1e-9, name
            if previous is not None:
                assert r['sample'] > previous, name
                missing += int(r['sample'] - previous - 1)
            previous = r['sample']
            assert all(r[key] in (0, 1) for key in ('armed', 'fault', 'enabled')), name
            assert all(0 <= r[key] <= 8191 for key in ('reference_q12', 'measured_q12')), name
            assert 0 <= r['duty_q12'] <= 4096, name
            assert -(2**31) <= r['integral_q12'] <= 2**31 - 1, name
            for code, exported in [('reference_q12', 'target_rpm'), ('measured_q12', 'measured_rpm')]:
                expected = r[code] * (108000 / 988.427) / 4096
                assert math.isclose(r[exported], expected, rel_tol=1e-10, abs_tol=1e-9), name
            assert math.isclose(r['duty_percent'], r['duty_q12'] * 100 / 4096,
                                rel_tol=1e-10, abs_tol=1e-9), name
        records.append(dict(file=relative, sha256=sha256(path), records=len(rows),
                            first_counter=int(rows[0]['sample']), last_counter=int(rows[-1]['sample']),
                            missing_counters=missing,
                            time_basis='Original CSV sample / nominal 100 Hz; not measured wall clock'))
    return dict(status='PASS_RECORDED_SCHEMA_AND_UNITS', files=records,
                total_records=sum(r['records'] for r in records), matlab_simulink_executed=False)


def main():
    # Fail on corrupt/missing captures; never fall back to an invented signal.
    reference = generate(ROOT, make_preview=True)
    motor_audit = audit_motor(ROOT)
    offline = ROOT / 'reports/measured_offline'
    motor_report = offline / 'motor_measured_audit.json'
    motor_report.write_text(json.dumps(motor_audit, indent=2) + '\n', encoding='utf-8')
    # calculate_reference also audits exported feature files; include the
    # final reference's dependency set rather than the initial raw-only set.
    selected = set(reference['input_sha256'])
    selected.update(r['file'] for r in motor_audit['files'])
    selected.update({
        'RUN_MEASURED_STUDY.m', 'matlab/fft64_fixed.m', 'matlab/npu_int8.m',
        'matlab/fourier_fft_sl.m', 'matlab/fourier_features_sl.m',
        'docs/MATLAB_SIMULINK_MEASURED.md', 'docs/MATLAB_SIMULINK_RESEARCH.md',
        'docs/STUDY_CODE_NOTES.md', 'DESIGN.md',
        'tools/check_measured_replay.py', 'tools/model.py', 'tools/capture_dataset.py',
        'tools/capture_telemetry.py', 'tools/package_measured.py',
    })
    selected.update(p.relative_to(ROOT).as_posix() for p in (ROOT / 'matlab/measured').glob('*.m'))
    selected.update('reports/measured_offline/' + name for name in (
        'measured_reference.json', 'measured_reference_frames.csv', 'measured_runs.csv',
        'measured_preview_3d.png', 'motor_measured_audit.json',
    ))
    verification = offline / 'VALIDATION.md'
    if verification.is_file():
        selected.add(verification.relative_to(ROOT).as_posix())
    for name in selected:
        assert (ROOT / name).is_file(), f'Missing dependency: {name}'
        assert '/research/' not in name and not name.endswith('.slx'), name
        assert not name.startswith('data/cases'), name
    files = {name: sha256(ROOT / name) for name in sorted(selected)}
    receipt = dict(format_version=1, entrypoint='RUN_MEASURED_STUDY',
                   data_origin='RECORDED_HARDWARE_ONLY',
                   measured_axes=['X'], vibration_windows=360,
                   motor_records=motor_audit['total_records'],
                   reused_validation=reference['validation'],
                   matlab_simulink_execution='NOT_RUN_IN_BUILD_ENVIRONMENT',
                   new_slx_included=False, files=files)
    readme = """# 실측 전용 MATLAB·Simulink 2차 패키지

현재 폴더를 이 파일과 RUN_MEASURED_STUDY.m이 있는 곳으로 바꾸고 실행하세요.

```matlab
RUN_MEASURED_STUDY
```

실측 진동 6개 run(23,040개 X축 원시값)과 모터 기록 5개가 원본 그대로 들어 있습니다.
추가 다운로드나 Python 실행 없이 MATLAB 분석을 시작할 수 있습니다.
Simulink가 있으면 reports/measured/에 진동과 모터 재생용 .slx 두 개를 생성하고 검증합니다.
Simulink가 없으면 MATLAB 분석만 실행하고 UNAVAILABLE로 기록합니다.

3D 그림은 실제 프레임 스펙트럼입니다. Y/Z·변위·자세는 측정되어 있지 않습니다.
기존 가정 기반 6자유도 모델 소스/입력은 이 패키지에 없습니다.
MATLAB/Simulink 실행 확인은 아직 수행하지 않았습니다.
기존 source 전체를 위한 FPGA build gate 패키지가 아니므로 .pass 파일을 만들지 않습니다.

자세한 설명: [실측 가이드](docs/MATLAB_SIMULINK_MEASURED.md).
기록된 Python 재현 결과: reports/measured_offline/.
"""
    output = ROOT / 'artifacts/matlab_measured_input.zip'
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in files:
            archive.write(ROOT / name, PREFIX + '/' + name)
        archive.writestr(PREFIX + '/README.md', readme)
        archive.writestr(PREFIX + '/measured_package_manifest.json', json.dumps(receipt, indent=2) + '\n')
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == len(set(archive.namelist()))
        for name, expected in files.items():
            assert hashlib.sha256(archive.read(PREFIX + '/' + name)).hexdigest() == expected == sha256(ROOT / name), name
        for item in reference['source_files']:
            assert hashlib.sha256(archive.read(PREFIX + '/' + item['file'])).hexdigest() == item['sha256'], item['file']
    print(output)
    print(f'{len(files)} source/data/report files; {motor_audit["total_records"]} actual motor records.')
    print('PASS: original capture hashes, ZIP integrity, dependencies; no MATLAB execution claimed.')


if __name__ == '__main__':
    main()
