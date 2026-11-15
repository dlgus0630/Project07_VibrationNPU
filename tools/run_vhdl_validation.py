#!/usr/bin/env python3
"""Run VHDL migration checks without touching the original build or PASS markers.

Requires Vivado/XSim 2024.2 and mixed-language simulation.  The Verilog RTL is
used solely as a side-by-side reference; original source/data are never edited.
"""
from datetime import datetime, timezone
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VIVADO_BIN = Path(os.environ.get('VIVADO_BIN', '/tools/Xilinx/Vivado/2024.2/bin'))
VHDL_ORDER = [
    'fourier/vhdl/vibration_types.vhd', 'fourier/vhdl/vibration_regs.vhd',
    'common/reset_sync.vhd', 'fourier/vhdl/input_sync_rtl.vhd',
    'fourier/vhdl/mac_pe_rtl.vhd', 'fourier/vhdl/fault_latch_rtl.vhd',
    'fourier/vhdl/safety_supervisor_rtl.vhd', 'fourier/vhdl/unsigned_divider_rtl.vhd',
    'fourier/vhdl/pwm_period_rtl.vhd', 'fourier/vhdl/mpu_spi_fsm.vhd',
    'fourier/vhdl/fft64_features_fsm.vhd', 'fourier/vhdl/npu_2pe_fsm.vhd',
    'fourier/vhdl/vibration_core_fsm.vhd', 'fourier/vhdl/pid_controller_fsm.vhd',
    'fourier/vhdl/encoder_quadrature_rtl.vhd', 'fourier/vhdl/encoder_speed_rtl.vhd',
    'fourier/vhdl/motor_run_control_rtl.vhd',
    'fourier/vhdl/fourier_motor_struct.vhd', 'fourier/vhdl/fourier_motor_control.vhd',
    'fourier/vhdl/axi_registers_rtl.vhd',
    'fourier/vhdl/axi_vibration_struct.vhd', 'fourier/vhdl/axi_vibration_top.vhd',
]
TESTS = {
    'tb_fft_npu_vhdl': 'fourier/tb_vhdl/tb_fft_npu_vhdl.sv',
    'tb_mac': 'fourier/tb_vhdl/tb_mac.sv', 'tb_core': 'fourier/tb_vhdl/tb_core.sv',
    'tb_axi': 'fourier/tb_vhdl/tb_axi.sv', 'tb_spi': 'fourier/tb_vhdl/tb_spi.sv',
    'tb_fault_latch': 'fourier/tb_vhdl/tb_fault_latch.sv',
    'tb_safety_supervisor': 'fourier/tb_vhdl/tb_safety_supervisor.sv',
    'tb_core_equivalence': 'fourier/tb_vhdl/tb_core_equivalence.sv',
    'tb_pid_equivalence': 'fourier/tb_vhdl/tb_pid_equivalence.sv',
    'tb_motor_equivalence': 'fourier/tb_vhdl/tb_motor_equivalence.sv',
    'tb_reset_sync_vhdl': 'fourier/tb_vhdl/tb_reset_sync_vhdl.vhd',
    'tb_mac_pe_vhdl': 'fourier/tb_vhdl/tb_mac_pe_vhdl.vhd',
    'tb_fft_npu_native_vhdl': 'fourier/tb_vhdl/tb_fft_npu_native_vhdl.vhd',
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, folder, log):
    result = subprocess.run([str(x) for x in command], cwd=folder, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout, encoding='utf-8')
    if result.returncode or 'ERROR:' in result.stdout or 'FATAL' in result.stdout:
        raise RuntimeError(f'{command[0]} failed; inspect {log}\n{result.stdout[-4000:]}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test', action='append', choices=TESTS,
                        help='Run only the named test (may be repeated). Default: all tests.')
    args = parser.parse_args()
    for executable in ('xvhdl', 'xvlog', 'xelab', 'xsim'):
        if not (VIVADO_BIN / executable).is_file():
            raise SystemExit(f'Missing Vivado tool: {VIVADO_BIN / executable}')
    verilog = [ROOT / 'common/reset_sync.v', *sorted((ROOT / 'fourier/rtl').glob('*.v'))]
    inputs = [Path(__file__).resolve()] + [ROOT / p for p in VHDL_ORDER] + verilog + [ROOT / p for p in TESTS.values()]
    inputs += sorted((ROOT / 'data').glob('*.mem'))
    before = {p.relative_to(ROOT).as_posix(): sha256(p) for p in inputs}
    build = ROOT / 'build/vhdl_validation'
    build.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix='run_', dir=build))
    print(f'XSim work directory: {folder}', flush=True)
    for path in (ROOT / 'data').glob('*.mem'):
        shutil.copyfile(path, folder / path.name)
    # Give every baseline entity a unique name so both implementations can
    # coexist in one simulation and receive identical stimuli on each clock.
    names = [path.stem for path in verilog]
    pattern = re.compile(r'\b(' + '|'.join(map(re.escape, sorted(names, key=len, reverse=True))) + r')\b')
    ref_files = []
    for path in verilog:
        out = folder / (path.stem + '_ref.v')
        # XSim requires matching time units when a Verilog and VHDL design
        # share a snapshot. The RTL is synchronous and has no delay literals.
        out.write_text('`timescale 1ns/1ps\n' +
                       pattern.sub(lambda m: m.group(0) + '_ref', path.read_text(encoding='utf-8')),
                       encoding='utf-8')
        ref_files.append(out)
    run([VIVADO_BIN / 'xvhdl', '--2008', '--work', 'xil_defaultlib',
         *(ROOT / p for p in VHDL_ORDER),
         *(ROOT / p for p in TESTS.values() if Path(p).suffix == '.vhd')], folder, folder / 'xvhdl.log')
    run([VIVADO_BIN / 'xvlog', '-sv', '--work', 'xil_defaultlib', *ref_files,
         *(ROOT / p for p in TESTS.values() if Path(p).suffix != '.vhd')], folder, folder / 'xvlog.log')
    results = {}
    for name in args.test or TESTS:
        run([VIVADO_BIN / 'xelab', 'xil_defaultlib.' + name, '-s', name + '_vhdl'], folder, folder / (name + '_elab.log'))
        output = run([VIVADO_BIN / 'xsim', name + '_vhdl', '-runall', '-log', name + '_xsim.log'],
                     folder, folder / (name + '_console.log'))
        marker = 'TEST PASS ' + name
        if marker not in output or 'TEST FAIL' in output:
            raise RuntimeError(f'{name} did not pass; inspect {folder / (name + "_console.log")}')
        results[name] = next(line for line in output.splitlines() if marker in line)
        print(results[name], flush=True)
    after = {p.relative_to(ROOT).as_posix(): sha256(p) for p in inputs}
    if before != after:
        raise RuntimeError('Source or Golden data changed while the simulation was running.')
    report = {
        'timestamp_utc': datetime.now(timezone.utc).isoformat(),
        'tool': 'Vivado/XSim 2024.2', 'status': 'PASS',
        'note': 'Simulation only; no synthesis, implementation, or hardware measurements.',
        'tests': results, 'source_sha256': before,
    }
    (folder / 'validation.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'PASS: {len(results)} checks. Evidence: {folder / "validation.json"}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError) as exc:
        print(f'VHDL validation failed: {exc}', file=sys.stderr)
        sys.exit(1)
