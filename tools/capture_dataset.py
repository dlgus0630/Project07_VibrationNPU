#!/usr/bin/env python3
"""Capture MPU-6500/9250 windows and build a run-separated training dataset."""
import argparse
import csv
import hashlib
import json
import math
import os
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

SAMPLES_PER_WINDOW = 64
SAMPLE_RATE_HZ = 1000
SENSOR_IDS = {"0x70": "MPU-6500", "0x71": "MPU-9250"}
FIELDS = ["run_id", "label", "condition", "window", "sample_index",
          "raw_x", "dt_us", "host_time_s"]
ROOT = Path(__file__).resolve().parents[1]


def parse_sample(line):
    parts = line.strip().split(",")
    if len(parts) != 4 or parts[0] != "SAMPLE":
        return None
    try:
        index, raw, dt_us = map(int, parts[1:])
    except ValueError:
        return None
    return index, raw, dt_us


def read_line(ser, deadline):
    while time.monotonic() < deadline:
        line = ser.readline().decode("ascii", errors="replace").strip()
        if line:
            if not line.startswith("SAMPLE,"):
                print(line, flush=True)
            return line
    raise TimeoutError("UART response timed out")


def initialize_sensor(ser, timeout):
    ser.reset_input_buffer()
    ser.write(b"i")
    deadline = time.monotonic() + timeout
    sensor_model = None
    reported_model = None
    while time.monotonic() < deadline:
        line = read_line(ser, deadline)
        if line.startswith("WHO_AM_I,"):
            sensor_model = SENSOR_IDS.get(line.split(",")[1].lower())
        if line.startswith("SENSOR_MODEL,"):
            reported_model = line.split(",", 1)[1]
            if sensor_model != reported_model:
                raise RuntimeError("WHO_AM_I and SENSOR_MODEL disagree")
        if line == "SENSOR_READY,1":
            if sensor_model is None or reported_model != sensor_model:
                raise RuntimeError("SENSOR_READY without verified ID and model")
            return sensor_model
        if line == "SENSOR_READY,0" or line.startswith("ERROR,"):
            raise RuntimeError("MPU initialization failed: " + line)
    raise TimeoutError("MPU initialization response timed out")


def acquire_window(ser, timeout):
    ser.reset_input_buffer()
    ser.write(b"d")
    deadline = time.monotonic() + timeout
    samples = []
    while len(samples) < SAMPLES_PER_WINDOW:
        line = read_line(ser, deadline)
        if line.startswith("ERROR,"):
            raise RuntimeError(line)
        item = parse_sample(line)
        if item is None:
            continue
        expected = len(samples)
        if item[0] != expected:
            raise RuntimeError(f"sample index {item[0]}, expected {expected}")
        if not -32768 <= item[1] <= 32767:
            raise RuntimeError(f"raw sample outside int16: {item[1]}")
        if expected == 0:
            if item[2] != 0:
                raise RuntimeError(f"first dt_us must be 0, got {item[2]}")
        elif not 700 <= item[2] <= 1300:
            raise RuntimeError(f"dt_us outside 700..1300: {item[2]}")
        samples.append(item)
    return samples


def atomic_csv(path, rows, force=False):
    path = Path(path)
    if path.exists() and not force:
        raise FileExistsError(f"refusing to overwrite {path}; use --force")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".partial")
    try:
        with temporary.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(rows)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def sha256_file(path):
    path = Path(path)
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".partial")
    try:
        temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n",
                             encoding="utf-8")
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def capture(args):
    import serial
    label = {"normal": 0, "abnormal": 1}[args.condition]
    rows = []
    rejected = 0
    with serial.Serial(args.port, 115200, timeout=0.2) as ser:
        sensor_model = initialize_sensor(ser, args.init_timeout)
        while len(rows) // SAMPLES_PER_WINDOW < args.windows:
            window = len(rows) // SAMPLES_PER_WINDOW
            try:
                samples = acquire_window(ser, args.window_timeout)
            except (RuntimeError, TimeoutError) as error:
                rejected += 1
                print(f"REJECT,{rejected},{error}", flush=True)
                if rejected > args.max_errors:
                    raise RuntimeError("too many rejected capture attempts") from error
                continue
            stamp = time.time()
            for index, raw, dt_us in samples:
                rows.append({"run_id": args.run_id, "label": label,
                             "condition": args.condition, "window": window,
                             "sample_index": index, "raw_x": raw,
                             "dt_us": dt_us, "host_time_s": f"{stamp:.6f}"})
            print(f"WINDOW,{window + 1}/{args.windows},PASS", flush=True)
    atomic_csv(args.output, rows, args.force)
    meta = {
        "format_version": 1, "run_id": args.run_id, "condition": args.condition,
        "label": label, "sample_rate_hz": SAMPLE_RATE_HZ, "sensor": sensor_model,
        "axis": "X", "range_g": 2, "samples_per_window": SAMPLES_PER_WINDOW,
        "windows": args.windows, "supply_v": args.supply_v,
        "motor_target_rpm": args.motor_target_rpm,
        "motor_duty_pct": args.motor_duty_pct, "note": args.note,
        "capture_csv": Path(args.output).name,
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "bitstream_sha256": sha256_file(ROOT / "artifacts/fourier.bit"),
        "firmware_elf_sha256": sha256_file(ROOT / "artifacts/fourier_app.elf"),
    }
    sidecar = Path(args.output).with_suffix(".json")
    atomic_json(sidecar, meta)
    print(f"CAPTURE PASS: {args.output} ({args.windows} windows, {rejected} rejected)")


def load_run(path):
    path = Path(path)
    sidecar = path.with_suffix(".json")
    if not sidecar.is_file():
        raise ValueError(f"missing run metadata sidecar: {sidecar}")
    meta = json.loads(sidecar.read_text(encoding="utf-8"))
    rows = list(csv.DictReader(path.open(encoding="utf-8")))
    if not rows or set(rows[0]) != set(FIELDS):
        raise ValueError(f"invalid capture CSV schema: {path}")
    run_ids = {row["run_id"] for row in rows}
    labels = {int(row["label"]) for row in rows}
    conditions = {row["condition"] for row in rows}
    if len(run_ids) != 1 or len(labels) != 1 or len(conditions) != 1:
        raise ValueError(f"one file must contain exactly one run/label/condition: {path}")
    label = labels.pop()
    condition = conditions.pop()
    if label not in (0, 1) or condition != ("normal" if label == 0 else "abnormal"):
        raise ValueError(f"label/condition mismatch: {path}")
    if meta.get("run_id") not in run_ids or meta.get("label") != label or meta.get("condition") != condition:
        raise ValueError(f"CSV and JSON metadata disagree: {path}")
    if (meta.get("sample_rate_hz"), meta.get("axis"), meta.get("range_g")) != (
            SAMPLE_RATE_HZ, "X", 2):
        raise ValueError(f"unsupported acquisition contract: {sidecar}")
    if meta.get("sensor") not in SENSOR_IDS.values():
        raise ValueError(f"unsupported sensor model: {sidecar}")
    grouped = defaultdict(list)
    for row in rows:
        grouped[int(row["window"])].append(row)
    windows = []
    for window_id in sorted(grouped):
        block = sorted(grouped[window_id], key=lambda row: int(row["sample_index"]))
        indices = [int(row["sample_index"]) for row in block]
        if indices != list(range(SAMPLES_PER_WINDOW)):
            raise ValueError(f"window {window_id} is incomplete or duplicated: {path}")
        values = [int(row["raw_x"]) for row in block]
        if min(values) < -32768 or max(values) > 32767:
            raise ValueError(f"window {window_id} exceeds int16: {path}")
        for index, row in enumerate(block):
            dt_us = int(row["dt_us"])
            if (index == 0 and dt_us != 0) or (index and not 700 <= dt_us <= 1300):
                raise ValueError(f"window {window_id} has invalid dt_us: {path}")
        windows.append(values)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return {"path": path, "run_id": run_ids.pop(), "label": label,
            "condition": condition, "windows": windows, "sha256": digest,
            "metadata": meta, "metadata_sha256": sha256_file(sidecar)}


def write_matrix(path, values):
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerows(values)


def build(args):
    runs = [load_run(path) for path in args.runs]
    ids = [run["run_id"] for run in runs]
    if len(ids) != len(set(ids)):
        raise ValueError("run_id values must be unique")
    by_label = {label: [run for run in runs if run["label"] == label] for label in (0, 1)}
    if any(len(group) < 2 for group in by_label.values()):
        raise ValueError("at least two independent runs per class are required")
    sensor_models = {run["metadata"]["sensor"] for run in runs}
    if len(sensor_models) != 1:
        raise ValueError("all runs in one dataset must use the same sensor model")
    requested = set(args.validation_run or [])
    unknown = requested - set(ids)
    if unknown:
        raise ValueError("unknown validation run_id: " + ", ".join(sorted(unknown)))
    validation = []
    training = []
    for label in (0, 1):
        group = by_label[label]
        selected = [run for run in group if run["run_id"] in requested]
        if requested and not selected:
            raise ValueError(f"validation split has no class {label} run")
        if not requested:
            count = max(1, math.ceil(len(group) * args.validation_fraction))
            count = min(count, len(group) - 1)
            selected = group[-count:]
        selected_ids = {run["run_id"] for run in selected}
        validation.extend(selected)
        training.extend(run for run in group if run["run_id"] not in selected_ids)
    train_windows = [window for run in training for window in run["windows"]]
    val_windows = [window for run in validation for window in run["windows"]]
    train_labels = [run["label"] for run in training for _ in run["windows"]]
    val_labels = [run["label"] for run in validation for _ in run["windows"]]
    if len(val_windows) < 16:
        raise ValueError("validation split needs at least 16 windows")
    duplicates = set(map(tuple, train_windows)) & set(map(tuple, val_windows))
    if duplicates:
        raise ValueError("duplicate windows cross the train/validation split")
    output = Path(args.output)
    products = ["dataset.json", "train_samples.csv", "val_samples.csv",
                "train_labels.csv", "val_labels.csv"]
    if any((output / name).exists() for name in products) and not args.force:
        raise FileExistsError(f"refusing to overwrite dataset in {output}; use --force")
    output.mkdir(parents=True, exist_ok=True)
    write_matrix(output / "train_samples.csv", train_windows)
    write_matrix(output / "val_samples.csv", val_windows)
    write_matrix(output / "train_labels.csv", [[value] for value in train_labels])
    write_matrix(output / "val_labels.csv", [[value] for value in val_labels])
    metadata = {
        "type": "real", "sample_rate_hz": SAMPLE_RATE_HZ,
        "sensor": sensor_models.pop(), "axis": "X", "range_g": 2,
        "samples_per_window": SAMPLES_PER_WINDOW, "split_by": "run_id",
        "label_map": {"normal": 0, "abnormal": 1},
        "train_run_ids": [run["run_id"] for run in training],
        "validation_run_ids": [run["run_id"] for run in validation],
        "train_windows": len(train_windows), "validation_windows": len(val_windows),
        "source_runs": [{"run_id": run["run_id"], "condition": run["condition"],
                         "windows": len(run["windows"]), "file": str(run["path"]),
                         "sha256": run["sha256"],
                         "metadata_sha256": run["metadata_sha256"],
                         "acquisition": run["metadata"]} for run in runs],
    }
    atomic_json(output / "dataset.json", metadata)
    print(f"DATASET PASS: train={len(train_windows)}, validation={len(val_windows)}")
    print(output)


def parser():
    top = argparse.ArgumentParser(description=__doc__)
    sub = top.add_subparsers(dest="command", required=True)
    cap = sub.add_parser("capture", help="capture one independent acquisition run")
    cap.add_argument("--port", required=True)
    cap.add_argument("--condition", choices=("normal", "abnormal"), required=True)
    cap.add_argument("--run-id", required=True)
    cap.add_argument("--windows", type=int, default=60)
    cap.add_argument("--output", type=Path, required=True)
    cap.add_argument("--supply-v", type=float, default=12.0)
    motor = cap.add_mutually_exclusive_group(required=True)
    motor.add_argument("--motor-target-rpm", type=float)
    motor.add_argument("--motor-duty-pct", type=float)
    cap.add_argument("--note", default="")
    cap.add_argument("--init-timeout", type=float, default=3.0)
    cap.add_argument("--window-timeout", type=float, default=2.0)
    cap.add_argument("--max-errors", type=int, default=5)
    cap.add_argument("--force", action="store_true")
    cap.set_defaults(func=capture)
    make = sub.add_parser("build", help="build a strict run-separated dataset")
    make.add_argument("runs", nargs="+", type=Path)
    make.add_argument("--output", type=Path, required=True)
    make.add_argument("--validation-run", action="append")
    make.add_argument("--validation-fraction", type=float, default=1 / 3)
    make.add_argument("--force", action="store_true")
    make.set_defaults(func=build)
    return top


def main():
    args = parser().parse_args()
    if getattr(args, "windows", 1) < 1:
        raise SystemExit("--windows must be positive")
    fraction = getattr(args, "validation_fraction", 0.5)
    if not 0 < fraction < 1:
        raise SystemExit("--validation-fraction must be between 0 and 1")
    args.func(args)


if __name__ == "__main__":
    main()
