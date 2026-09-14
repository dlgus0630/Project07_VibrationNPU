#!/usr/bin/env python3
"""Offline regression tests for capture_dataset.py; no serial hardware required."""
import argparse
import csv
import json
import tempfile
from pathlib import Path

import capture_dataset as subject


def make_run(path, run_id, condition, base):
    label = 0 if condition == "normal" else 1
    rows = []
    for window in range(8):
        for index in range(64):
            rows.append({"run_id": run_id, "label": label, "condition": condition,
                         "window": window, "sample_index": index,
                         "raw_x": base + window * 100 + index,
                         "dt_us": 0 if index == 0 else 1000,
                         "host_time_s": "1.0"})
    subject.atomic_csv(path, rows)
    subject.atomic_json(path.with_suffix(".json"), {
        "format_version": 1, "run_id": run_id, "condition": condition,
        "label": label, "sample_rate_hz": 1000, "sensor": "MPU-6500",
        "axis": "X", "range_g": 2, "samples_per_window": 64,
        "windows": 8, "supply_v": 12.0, "motor_target_rpm": 40.0,
        "motor_duty_pct": None,
        "note": "test fixture", "capture_csv": path.name,
    })


def main():
    assert subject.parse_sample("SAMPLE,0,-123,0") == (0, -123, 0)
    assert subject.parse_sample("noise") is None
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        specs = [("normal_0", "normal", 0), ("normal_1", "normal", 1000),
                 ("abnormal_0", "abnormal", 2000), ("abnormal_1", "abnormal", 3000)]
        paths = []
        for run_id, condition, base in specs:
            path = root / f"{run_id}.csv"
            make_run(path, run_id, condition, base)
            paths.append(path)
        args = argparse.Namespace(runs=paths, output=root / "dataset",
                                  validation_run=["normal_1", "abnormal_1"],
                                  validation_fraction=1 / 3, force=False)
        subject.build(args)
        meta = json.loads((args.output / "dataset.json").read_text())
        assert meta["split_by"] == "run_id"
        assert meta["sensor"] == "MPU-6500" and meta["axis"] == "X" and meta["range_g"] == 2
        assert meta["train_windows"] == 16 and meta["validation_windows"] == 16
        train = list(csv.reader((args.output / "train_samples.csv").open()))
        validation = list(csv.reader((args.output / "val_samples.csv").open()))
        assert len(train) == len(validation) == 16
        assert not (set(map(tuple, train)) & set(map(tuple, validation)))
    print("CAPTURE DATASET TEST PASS")


if __name__ == "__main__":
    main()
