#!/usr/bin/env python3
"""Compare original/modular firmware on a deterministic host BSP, then compile ARM.

The host test models peripheral replies. Its times are software test values,
not hardware performance observations. Saved ELF/CSV/timing evidence is untouched.
"""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIRMWARE = ROOT / 'fourier/firmware'
TEST = ROOT / 'fourier/tb_host'
BEFORE = ROOT / 'docs/evidence/readability_complete_2026-11-15/before'
APPLICATION = ['main.c', 'app_platform.c', 'app_telemetry.c', 'sensor_spi.c',
               'app_inference.c', 'motor_commands.c', 'golden.c']
ARM_GCC = Path('/tools/Xilinx/Vitis/2024.2/gnu/aarch32/lin/gcc-arm-none-eabi/bin/arm-none-eabi-gcc')
DEFAULT_BSP = Path('/home/dlgus0630/workspace/Project07_VibrationNPU_vitis/fourier_plat/'
                   'ps7_cortexa9_0/standalone_ps7_cortexa9_0/bsp/include')
SCENARIOS = {
    'replay_pair': 'r',
    'replay_fault': 'x',
    'benchmark': 'b',
    'safety': 'f',
    'gain_and_integrator_commands': 'gGwWog',
    'telemetry_restart': 'tftTTtT',
    'open_loop_from_idle': 'p',
    'open_loop_while_streaming': 'tpT',
    'sensor_6500': 'isd',
    'sensor_9250': 'isd',
    'sensor_signed_samples': 'isd',
    'unknown_sensor': 'is',
    'configuration_mismatch': 'is',
    'spi_timeout': 'i',
    'data_ready_timeout': 'is',
    'sample_interval_error': 'is',
    'pl_timeout': 'r',
    'pl_status_error': 'r',
    'result_mismatch': 'rb',
    'uninitialized_sensor': 'sd?',
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(command, cwd):
    result = subprocess.run([str(value) for value in command], cwd=cwd,
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f'{command}\n{result.stdout}\n{result.stderr}')
    return result


def host_source(source, destination):
    # Only the ARM memory-barrier instruction is replaced for the x86 host.
    # The driver logs the barrier in the same position as a MOCK,DSB_SY event.
    text = source.read_text()
    instruction = '__asm__ volatile("dsb sy" ::: "memory");'
    text = text.replace(instruction, 'mock_memory_barrier();')
    destination.write_text(text, encoding='utf-8')
    return destination


def compare_host_checker(folder, gcc):
    original = folder / 'host_check_before'
    current = folder / 'host_check_current'
    flags = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
             '-fsanitize=undefined', '-fno-sanitize-recover=undefined', '-I', str(FIRMWARE)]
    execute([gcc, *flags, FIRMWARE / 'golden.c', BEFORE / 'fourier/firmware/host_check.c',
             '-o', original], folder)
    execute([gcc, *flags, FIRMWARE / 'golden.c', FIRMWARE / 'host_check.c', '-o', current], folder)
    fixture = folder / 'fixture'
    data = fixture / 'data'
    data.mkdir(parents=True)
    for path in (ROOT / 'data').glob('*.mem'):
        shutil.copy2(path, data / path.name)
    results = {}
    variations = ['unchanged', 'fft_re', 'fft_im', 'features', 'hidden', 'logits', 'class', 'truncated']
    for variation in variations:
        changed_path = None
        if variation != 'unchanged':
            name = variation
            if variation == 'truncated':
                name = 'samples'
            changed_path = data / (name + '.mem')
            saved = changed_path.read_bytes()
            if variation == 'truncated':
                changed_path.write_text('')
            else:
                words = changed_path.read_text().splitlines()
                words[0] = format(int(words[0], 16) ^ 1, 'x')
                changed_path.write_text('\n'.join(words) + '\n')
        outputs = [subprocess.run([str(program)], cwd=fixture, capture_output=True, timeout=10)
                   for program in [original, current]]
        expected = (outputs[0].returncode, outputs[0].stdout, outputs[0].stderr)
        actual = (outputs[1].returncode, outputs[1].stdout, outputs[1].stderr)
        assert expected == actual, f'Host checker behavior changed: {variation}: {expected} != {actual}'
        results[variation] = dict(exit_code=outputs[1].returncode,
                                  stdout=outputs[1].stdout.decode(), stderr=outputs[1].stderr.decode())
        if changed_path:
            changed_path.write_bytes(saved)
    return results


def compare_result_layout(folder, gcc):
    source = folder / 'result_layout.c'
    source.write_text(
        '#include <stddef.h>\n#include <stdio.h>\n#include "golden.h"\n'
        'int main(void) {\n'
        'printf("%zu %zu %zu %zu %zu %zu %zu\\n", sizeof(inference_result),\n'
        'offsetof(inference_result,re), offsetof(inference_result,im),\n'
        'offsetof(inference_result,features), offsetof(inference_result,hidden),\n'
        'offsetof(inference_result,logits), offsetof(inference_result,class_id));\n'
        'return 0;\n}\n')
    layouts = []
    for index, include in enumerate([BEFORE / 'fourier/firmware', FIRMWARE]):
        output = folder / f'layout_{index}'
        execute([gcc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', include,
                 source, '-o', output], folder)
        layouts.append(execute([output], folder).stdout.strip())
    assert layouts[0] == layouts[1], f'Result structure layout changed: {layouts}'
    return {'status': 'PASS', 'sizeof_and_offsets': layouts[1]}


def compile_arm(folder):
    bsp = Path(os.environ.get('VIBRATION_BSP_INCLUDE', str(DEFAULT_BSP)))
    if not ARM_GCC.is_file() or not (bsp / 'xparameters.h').is_file():
        return {'status': 'NOT RUN', 'reason': 'Cortex-A9 compiler/BSP include unavailable'}
    results = {}
    objects = []
    for name in APPLICATION:
        output = folder / ('arm_' + name + '.o')
        command = [ARM_GCC, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                   '-DSDT', '-mcpu=cortex-a9', '-mfloat-abi=hard', '-mfpu=vfpv3',
                   '-isystem', bsp, '-I', FIRMWARE, '-c', FIRMWARE / name, '-o', output]
        execute(command, folder)
        results[name] = {'object_sha256': sha256(output)}
        objects.append(output)
    application = Path('/home/dlgus0630/workspace/Project07_VibrationNPU_vitis/fourier_app/src')
    spec = Path('/home/dlgus0630/workspace/Project07_VibrationNPU_vitis/fourier_plat/'
                'export/fourier_plat/sw/standalone_ps7_cortexa9_0/Xilinx.spec')
    elf = folder / 'readable_firmware.elf'
    command = [ARM_GCC, '-mcpu=cortex-a9', '-mfloat-abi=hard', '-mfpu=vfpv3',
               '-specs=' + str(spec), *objects, '-Wl,-T,' + str(application / 'lscript.ld'),
               '-L' + str(bsp.parent / 'lib'), '-Wl,--start-group', '-lxilstandalone',
               '-lxiltimer', '-lxil', '-lgcc', '-lc', '-Wl,--end-group', '-o', elf]
    execute(command, folder)
    return {'status': 'PASS', 'bsp_include': str(bsp), 'objects': results,
            'link': 'PASS', 'elf_sha256': sha256(elf),
            'tool': execute([ARM_GCC, '--version'], folder).stdout.splitlines()[0]}


def main():
    gcc = shutil.which('gcc')
    if not gcc:
        raise RuntimeError('gcc required')
    saved = json.loads((BEFORE.parent / 'before_sha256.json').read_text())
    for name in ['fourier/firmware/main.c', 'fourier/firmware/host_check.c', 'fourier/firmware/golden.h']:
        assert sha256(BEFORE / name) == saved[name], f'Original source changed: {name}'
    inputs = [Path(__file__).resolve(), *FIRMWARE.glob('*.c'), *FIRMWARE.glob('*.h'),
              *TEST.rglob('*.c'), *TEST.rglob('*.h')]
    hashes = {path.relative_to(ROOT).as_posix(): sha256(path) for path in inputs}
    results = {}
    with tempfile.TemporaryDirectory(prefix='firmware_readability_') as directory:
        folder = Path(directory)
        originals = [host_source(BEFORE / 'fourier/firmware/main.c', folder / 'main_before.c'),
                     FIRMWARE / 'golden.c']
        current = [host_source(FIRMWARE / name, folder / name) for name in APPLICATION]
        programs = []
        for label, sources in [('before', originals), ('after', current)]:
            objects = []
            for index, source in enumerate(sources):
                output = folder / f'{label}_{index}.o'
                flags = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                         '-fsanitize=undefined', '-fno-sanitize-recover=undefined',
                         '-I', str(FIRMWARE), '-I', str(TEST / 'bsp_mock'),
                         '-include', str(TEST / 'bsp_mock/mock_bsp.h')]
                if source.name in ['main.c', 'main_before.c']:
                    flags += ['-Dmain=firmware_entry']
                execute([gcc, *flags, '-c', source, '-o', output], folder)
                objects.append(output)
            executable = folder / label
            execute([gcc, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                     '-fsanitize=undefined', '-fno-sanitize-recover=undefined', '-I', FIRMWARE,
                     TEST / 'firmware_protocol_driver.c', *objects, '-o', executable], folder)
            programs.append(executable)
        for scenario, commands in SCENARIOS.items():
            before = execute([programs[0], scenario, commands], folder)
            after = execute([programs[1], scenario, commands], folder)
            if (before.stdout, before.stderr) != (after.stdout, after.stderr):
                output = ROOT / 'build/firmware_mismatch'
                output.mkdir(parents=True, exist_ok=True)
                (output / 'before.txt').write_text(before.stdout)
                (output / 'after.txt').write_text(after.stdout)
                raise AssertionError(f'Firmware trace changed: {scenario}; inspect {output}')
            results[scenario] = {'commands': commands, 'trace_lines': len(after.stdout.splitlines()),
                                  'trace_sha256': hashlib.sha256(after.stdout.encode()).hexdigest()}
            print(f'PASS firmware protocol: {scenario}', flush=True)
        host_checker = compare_host_checker(folder, gcc)
        result_layout = compare_result_layout(folder, gcc)
        arm = compile_arm(folder)
    for path in inputs:
        assert sha256(path) == hashes[path.relative_to(ROOT).as_posix()], path
    report = dict(status='PASS', timestamp_utc=datetime.now(timezone.utc).isoformat(),
                  scenarios=results, host_checker=host_checker, result_layout=result_layout, arm_compile=arm,
                  source_sha256=hashes,
                  note='Host BSP software protocol test; timer values are not hardware measurements.')
    (ROOT / 'reports').mkdir(exist_ok=True)
    (ROOT / 'reports/firmware_equivalence.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'FIRMWARE EQUIVALENCE PASS: {len(results)} command scenarios, '
          f'{len(host_checker)} host checker cases; ARM compile {arm["status"]}')


if __name__ == '__main__':
    main()
