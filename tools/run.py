#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=['create', 'sim', 'build'])
    args = parser.parse_args()
    executable = os.environ.get('VIVADO') or shutil.which('vivado')
    if not executable:
        raise SystemExit('Vivado 2024.2 not found. Set VIVADO to its executable path.')
    source = {'create': 'create_fourier.tcl', 'sim': 'run_simulations.tcl',
              'build': 'build_bitstream.tcl'}[args.stage]
    (ROOT / 'reports').mkdir(exist_ok=True)
    (ROOT / 'build').mkdir(exist_ok=True)
    environment = os.environ.copy()
    environment['FPGA_PYTHON'] = sys.executable
    environment.pop('PYTHONHOME', None)
    environment.pop('PYTHONPATH', None)
    command = [executable, '-mode', 'batch', '-nojournal',
               '-log', str(ROOT / 'reports' / f'vivado_{args.stage}.log'),
               '-source', str(ROOT / 'vivado' / source)]
    subprocess.run(command, cwd=ROOT / 'build', env=environment, check=True)


if __name__ == '__main__':
    main()

