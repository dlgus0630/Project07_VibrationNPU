#!/usr/bin/env python3
"""Audit captured-only replay data and produce an independent integer reference.

No signals are generated, repaired, interpolated, or written to the dataset.
The preview is computed from independent 64-sample measured frames. Host receipt
times describe frame ordering; they are not sample acquisition timestamps.
"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path

import numpy as np

from capture_dataset import FIELDS, load_run
from model import features, npu

ROOT = Path(__file__).resolve().parents[1]
RUN_IDS = ["normal_50_01", "normal_50_02", "normal_50_03",
           "fault_ripple_01", "fault_ripple_02", "fault_ripple_03"]
CONTRACT = {"sample_rate_hz": 1000, "sensor": "MPU-6500", "axis": "X",
            "range_g": 2, "samples_per_window": 64}
WINDOW_FIELDS = ["RunID", "Split", "WindowID", "TrueLabel", "PredictedClass",
                 "F1", "F2", "F3", "F4", "H1", "H2", "H3", "H4", "L0", "L1",
                 "HostTime_s", "HostElapsed_s", "FrameDuration_s",
                 "RawMean_counts", "ACRMS_counts"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    require(path.is_file(), f"missing required input: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    require(path.is_file(), f"missing required input: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def read_integer_matrix(path, shape):
    require(path.is_file(), f"missing required input: {path}")
    with path.open(encoding="utf-8", newline="") as handle:
        try:
            values = np.array([[int(value) for value in row]
                               for row in csv.reader(handle)], dtype=np.int64)
        except (ValueError, OverflowError) as error:
            raise ValueError(f"invalid integer matrix: {path}") from error
    require(values.shape == shape, f"unexpected matrix shape {values.shape}: {path}")
    return values


def validate_model(model):
    for key, shape, lo, hi in [("w1", (4, 4), -128, 127), ("w2", (2, 4), -128, 127),
                               ("b1", (4,), -(2**31), 2**31 - 1),
                               ("b2", (2,), -(2**31), 2**31 - 1)]:
        array = np.asarray(model.get(key))
        require(array.shape == shape and np.issubdtype(array.dtype, np.integer),
                f"invalid quantized model shape/type: {key}")
        require(bool(np.all((array >= lo) & (array <= hi))), f"model range: {key}")
    for key in ["shift1", "shift2"]:
        value = model.get(key)
        require(type(value) is int and 0 <= value <= 31, f"invalid model {key}")


def audit_inputs(root=ROOT):
    """Fail closed unless manifest, sidecars, captures and exports agree exactly."""
    root = Path(root).resolve()
    manifest_path = root / "data/dataset_source.json"
    manifest = read_json(manifest_path)
    require(manifest.get("type") == "real", "dataset_source must declare type=real")
    require(manifest.get("split_by") == "run_id", "split must be by run_id")
    require(manifest.get("label_map") == {"normal": 0, "abnormal": 1}, "label_map mismatch")
    for key, value in CONTRACT.items():
        require(manifest.get(key) == value, f"manifest acquisition contract: {key}")
    source_runs = manifest.get("source_runs", [])
    ids = [source.get("run_id") for source in source_runs]
    require(len(ids) == 6 and set(ids) == set(RUN_IDS),
            "expected six distinct final_50pct source run IDs")
    train_ids = manifest.get("train_run_ids", [])
    val_ids = manifest.get("validation_run_ids", [])
    require(len(train_ids) == len(set(train_ids)) == 4, "invalid train split IDs")
    require(len(val_ids) == len(set(val_ids)) == 2, "invalid validation split IDs")
    require(not set(train_ids) & set(val_ids), "train/validation split overlap")
    require(set(train_ids) | set(val_ids) == set(ids), "split omits/introduces source run")
    require(set(val_ids) == {"normal_50_03", "fault_ripple_03"},
            "preserve original validation run IDs; this is not a new external test")
    require(manifest.get("train_windows") == 240 and manifest.get("validation_windows") == 120,
            "manifest split window counts mismatch")
    inputs = {"data/dataset_source.json": digest(manifest_path)}
    runs = []
    for source in source_runs:
        run_id = source["run_id"]
        expected_file = f"measurements/final_50pct/{run_id}.csv"
        require(source.get("file") == expected_file, f"unapproved capture path: {run_id}")
        path = root / expected_file
        sidecar = path.with_suffix(".json")
        require(digest(path) == source.get("sha256"), f"capture SHA-256 mismatch: {run_id}")
        require(digest(sidecar) == source.get("metadata_sha256"), f"metadata SHA-256 mismatch: {run_id}")
        run = load_run(path)
        meta = run["metadata"]
        require(meta == source.get("acquisition"), f"embedded acquisition metadata mismatch: {run_id}")
        for key, value in {**CONTRACT, "format_version": 1, "windows": 60,
                           "supply_v": 12.0, "motor_duty_pct": 50.0,
                           "motor_target_rpm": None, "capture_csv": path.name}.items():
            require(meta.get(key) == value, f"sidecar acquisition contract {key}: {run_id}")
        require(source.get("windows") == 60 and len(run["windows"]) == 60,
                f"expected 60 complete frames: {run_id}")
        expected_label = 0 if run_id.startswith("normal_") else 1
        require(run["label"] == expected_label and source.get("condition") == run["condition"],
                f"run condition/label mismatch: {run_id}")
        with path.open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            require(reader.fieldnames == FIELDS, f"capture column ordering/schema: {run_id}")
            rows = list(reader)
        require(len(rows) == 60 * 64, f"capture row count mismatch: {run_id}")
        stamps, durations, dt_values = [], [], []
        for frame in range(60):
            block = rows[frame * 64:(frame + 1) * 64]
            require([int(row["window"]) for row in block] == [frame] * 64,
                    f"frame IDs must be chronological contiguous 0..59: {run_id}/{frame}")
            require([int(row["sample_index"]) for row in block] == list(range(64)),
                    f"sample order must be chronological 0..63: {run_id}/{frame}")
            frame_stamps = [float(row["host_time_s"]) for row in block]
            require(all(math.isfinite(value) for value in frame_stamps)
                    and len(set(frame_stamps)) == 1,
                    f"one finite host receipt timestamp required per frame: {run_id}/{frame}")
            stamps.append(frame_stamps[0])
            dt_us = [int(row["dt_us"]) for row in block]
            durations.append(sum(dt_us) / 1e6)
            dt_values.extend(dt_us[1:])
        require(all(value > 0 for value in np.diff(stamps)), f"host timestamps not strictly increasing: {run_id}")
        # Host receipt gaps are reported separately; never used to synthesize samples.
        run.update(split="train" if run_id in train_ids else "validation",
                   host_time_s=np.asarray(stamps), frame_duration_s=np.asarray(durations),
                   dt_us=np.asarray(dt_values), samples=np.asarray(run["windows"], dtype=np.int64))
        runs.append(run)
        inputs[expected_file] = digest(path)
        inputs[str(sidecar.relative_to(root))] = digest(sidecar)
    by_id = {run["run_id"]: run for run in runs}
    matrices = {}
    for split, split_ids, prefix, count in [("train", train_ids, "train", 240),
                                           ("validation", val_ids, "val", 120)]:
        expected = np.concatenate([by_id[run_id]["samples"] for run_id in split_ids])
        labels = np.concatenate([np.full((60, 1), by_id[run_id]["label"], dtype=np.int64)
                                 for run_id in split_ids])
        for suffix, values, shape in [("samples", expected, (count, 64)), ("labels", labels, (count, 1))]:
            filename = f"data/{prefix}_{suffix}.csv"
            actual = read_integer_matrix(root / filename, shape)
            require(np.array_equal(actual, values), f"{split} {suffix} differ from captures/split order")
            inputs[filename] = digest(root / filename)
        matrices[split] = expected
    require(not set(map(tuple, matrices["train"])) & set(map(tuple, matrices["validation"])),
            "duplicate measured windows across train/validation")
    model_path = root / "data/model.json"
    model = read_json(model_path)
    validate_model(model)
    inputs["data/model.json"] = digest(model_path)
    return {"root": root, "manifest": manifest, "runs": runs, "model": model, "input_sha256": inputs}


def confusion(rows):
    counts = [[0, 0], [0, 0]]
    for row in rows:
        counts[row["TrueLabel"]][row["PredictedClass"]] += 1
    total = len(rows)
    correct = counts[0][0] + counts[1][1]
    return {"windows": total, "correct": correct, "accuracy": correct / total,
            "confusion_true_rows_predicted_columns": counts,
            "false_positive_rate": counts[0][1] / sum(counts[0]) if sum(counts[0]) else None,
            "fault_recall": counts[1][1] / sum(counts[1]) if sum(counts[1]) else None}


def calculate_reference(audit):
    """Retain measured DC in the existing integer FFT/NPU path."""
    rows, summaries = [], []
    for run in audit["runs"]:
        start = len(rows)
        for frame, samples in enumerate(run["samples"]):
            feature = features(samples)
            hidden, logits, prediction = npu(feature, audit["model"])
            row = dict(zip(WINDOW_FIELDS[:5], [run["run_id"], run["split"], frame, run["label"], prediction]))
            row.update({f"F{i + 1}": value for i, value in enumerate(feature)})
            row.update({f"H{i + 1}": value for i, value in enumerate(hidden)})
            row.update({f"L{i}": value for i, value in enumerate(logits)})
            row.update(HostTime_s=float(run["host_time_s"][frame]),
                       HostElapsed_s=float(run["host_time_s"][frame] - run["host_time_s"][0]),
                       FrameDuration_s=float(run["frame_duration_s"][frame]),
                       RawMean_counts=float(np.mean(samples)),
                       ACRMS_counts=float(np.sqrt(np.mean((samples - np.mean(samples))**2))))
            rows.append(row)
        run_rows = rows[start:]
        intervals = np.diff(run["host_time_s"])
        durations = run["frame_duration_s"]
        summaries.append({"RunID": run["run_id"], "Split": run["split"],
                          "TrueLabel": run["label"], "Windows": 60,
                          "Correct": sum(row["TrueLabel"] == row["PredictedClass"] for row in run_rows),
                          "Accuracy": confusion(run_rows)["accuracy"],
                          "RawMean_counts": float(run["samples"].mean()),
                          "MeanACRMS_counts": float(np.mean([row["ACRMS_counts"] for row in run_rows])),
                          "HostSpan_s": float(run["host_time_s"][-1] - run["host_time_s"][0]),
                          "HostIntervalMin_s": float(intervals.min()),
                          "HostIntervalMax_s": float(intervals.max()),
                          "FrameDurationMin_s": float(durations.min()),
                          "FrameDurationMax_s": float(durations.max()),
                          "SampleDeltaMin_us": int(run["dt_us"].min()),
                          "SampleDeltaMax_us": int(run["dt_us"].max()),
                          "NominalObservedSampleTime_s": 60 * 64 / 1000})
    # Exported features must also match the integer path; ordering follows manifest.
    for split, prefix, split_key in [("train", "train", "train_run_ids"),
                                     ("validation", "val", "validation_run_ids")]:
        ordered = [row for run_id in audit["manifest"][split_key] for row in rows if row["RunID"] == run_id]
        expected = np.asarray([[row[f"F{i}"] for i in range(1, 5)] for row in ordered])
        filename = f"data/{prefix}_features.csv"
        require(np.array_equal(read_integer_matrix(audit["root"] / filename, expected.shape), expected),
                f"{split} exported features differ from current integer reference")
        audit["input_sha256"][filename] = digest(audit["root"] / filename)
    return rows, summaries


def write_csv(path, rows, fields=None):
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields or list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def preview(audit, rows, output):
    """Plot independent measured frame spectra; the 3D axes are not spatial XYZ."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import Normalize
    from matplotlib.ticker import MaxNLocator

    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "axes.spines.top": False, "axes.spines.right": False})
    fig = plt.figure(figsize=(16, 11), facecolor="#f5f7fb")
    fig.suptitle("MEASURED DATA ONLY  |  MPU-6500 X-axis replay", x=0.045, ha="left",
                 y=0.974, fontsize=22, weight="bold", color="#122139")
    fig.text(0.046, 0.929, "6 recorded runs · 360 frames · 23,040 raw samples · nominal 1 kHz · 64 samples/frame",
             fontsize=12, color="#485a73")
    grid = fig.add_gridspec(2, 3, left=0.055, right=0.96, top=0.87, bottom=0.12,
                           wspace=0.34, hspace=0.43, height_ratios=[1.1, 1])
    frequency = np.fft.rfftfreq(64, 1 / 1000)
    run_by_id = {run["run_id"]: run for run in audit["runs"]}
    spectra = {}
    for run in audit["runs"]:
        ac = run["samples"] - run["samples"].mean(axis=1, keepdims=True)
        amplitude = np.abs(np.fft.rfft(ac, axis=1)) / 64
        amplitude[:, 1:-1] *= 2
        spectra[run["run_id"]] = amplitude
    vmax = max(spectra[run_id].max() for run_id in ["normal_50_03", "fault_ripple_03"])
    for column, run_id in enumerate(["normal_50_03", "fault_ripple_03"]):
        run = run_by_id[run_id]
        ax = fig.add_subplot(grid[0, column], projection="3d", facecolor="white")
        cmap = plt.get_cmap("viridis")
        norm = Normalize(0, vmax)
        times = run["host_time_s"] - run["host_time_s"][0]
        for index, frame in enumerate(spectra[run_id]):
            ax.plot(frequency, np.full_like(frequency, times[index]), frame,
                    color=cmap(norm(frame.max())), linewidth=0.7, alpha=0.9)
        ax.set(xlabel="Frequency (Hz)", ylabel="Host elapsed (s)", zlabel="Amplitude (counts)",
               zlim=(0, vmax), xlim=(0, 500), ylim=(0, 23))
        ax.set_title(("Normal" if column == 0 else "Torque ripple") + " · original validation run", pad=15, weight="bold")
        ax.view_init(elev=25, azim=-63)
        ax.xaxis.set_major_locator(MaxNLocator(4))
        ax.yaxis.set_major_locator(MaxNLocator(4))
        ax.zaxis.set_major_locator(MaxNLocator(4))
        ax.tick_params(labelsize=8)
    ax = fig.add_subplot(grid[0, 2], facecolor="white")
    matrix = np.asarray(confusion([row for row in rows if row["Split"] == "validation"])
                        ["confusion_true_rows_predicted_columns"])
    ax.imshow(matrix, cmap="Blues", vmin=0, vmax=60)
    for i in range(2):
        for j in range(2):
            ax.text(j, i, str(matrix[i, j]), ha="center", va="center", fontsize=27, weight="bold",
                    color="white" if matrix[i, j] > 30 else "#16263e")
    ax.set(xticks=[0, 1], yticks=[0, 1], xticklabels=["Normal", "Fault"],
           yticklabels=["Normal", "Fault"], xlabel="Predicted", ylabel="Recorded condition")
    ax.set_title("Original validation: 118 / 120\n98.33% · reused split, not an external test", fontsize=12, weight="bold", pad=13)
    colors = {"normal": "#007b94", "abnormal": "#d45939"}
    ax = fig.add_subplot(grid[1, 0], facecolor="white")
    for condition in ["normal", "abnormal"]:
        subset = np.concatenate([spectra[run["run_id"]] for run in audit["runs"] if run["condition"] == condition])
        ax.plot(frequency, subset.mean(axis=0), color=colors[condition], linewidth=2,
                label="Normal (180 frames)" if condition == "normal" else "Torque ripple (180 frames)")
    ax.set(xlabel="Frequency (Hz)", ylabel="Mean amplitude (counts)", xlim=(0, 500))
    ax.set_title("Mean of individual measured-frame spectra", weight="bold", pad=13)
    ax.legend(frameon=False, fontsize=9)
    ax.grid(alpha=0.15)
    ax = fig.add_subplot(grid[1, 1], facecolor="white")
    for run_id in ["normal_50_03", "fault_ripple_03"]:
        run = run_by_id[run_id]
        subset = [row for row in rows if row["RunID"] == run_id]
        ax.scatter([row["HostElapsed_s"] for row in subset], [row["ACRMS_counts"] for row in subset],
                   s=14, color=colors[run["condition"]], label=run_id)
    ax.set(xlabel="Host receipt elapsed time (s)", ylabel="Frame AC RMS (counts)", xlim=(0, 23))
    ax.set_title("Measured frame levels · gaps retained", weight="bold", pad=13)
    ax.legend(frameon=False, fontsize=8)
    ax.grid(alpha=0.15)
    ax = fig.add_subplot(grid[1, 2], facecolor="white")
    run = run_by_id["normal_50_03"]
    for index, (stamp, duration) in enumerate(zip(run["host_time_s"][:6], run["frame_duration_s"][:6])):
        # Receipt marks are points. A separate bar denotes only within-frame duration.
        receipt = stamp - run["host_time_s"][0]
        ax.scatter(receipt, 1, s=45, color="#007b94")
        ax.plot([receipt, receipt + duration], [0.45, 0.45], color="#d45939", linewidth=5)
    ax.set(xlabel="Relative host receipt (s)", xlim=(-0.05, 2.1), ylim=(0, 1.5),
           yticks=[0.45, 1], yticklabels=["Frame duration*", "Receipt mark"])
    ax.set_title("64-sample captures are discontinuous", weight="bold", pad=13)
    ax.text(0.04, 0.08, "~63 ms recorded / ~384 ms receipt interval\n*Bar width only; acquisition start is unknown.",
            transform=ax.transAxes, fontsize=8.5, color="#485a73")
    ax.grid(axis="x", alpha=0.15)
    fig.text(0.055, 0.058, "3D axes: frequency × host elapsed time × amplitude. No reconstructed spatial motion or fabricated Y/Z channels.",
             fontsize=10, color="#34465f")
    fig.text(0.055, 0.033, "Spectral display: per-frame mean removal only, rectangular DFT, 15.625 Hz bin spacing. Integer NPU: original raw DC retained.",
             fontsize=9.5, color="#576980")
    fig.savefig(output, dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)


def generate(root=ROOT, output=None, make_preview=True):
    audit = audit_inputs(root)
    rows, summaries = calculate_reference(audit)
    output = Path(output) if output is not None else audit["root"] / "reports/measured_offline"
    # Do not emit apparently valid reports before every input has passed.
    output.mkdir(parents=True, exist_ok=True)
    reference = {
        "schema_version": 1, "status": "PASS", "data_type": "measured_only",
        "source": "data/dataset_source.json", "sensor": "MPU-6500", "measured_axes": ["X"],
        "sample_rate_hz_nominal": 1000, "samples_per_frame": 64, "run_count": 6,
        "frame_count": 360, "sample_count": 23040,
        "input_sha256": audit["input_sha256"],
        "source_sha256": {**audit["input_sha256"], "tools/model.py": digest(Path(__file__).with_name("model.py"))},
        "source_files": [{"file": filename, "sha256": value}
                         for filename, value in audit["input_sha256"].items()],
        "model_sha256": audit["input_sha256"]["data/model.json"],
        "manifest_sha256": audit["input_sha256"]["data/dataset_source.json"],
        "reference_implementation_sha256": {"tools/model.py": digest(Path(__file__).with_name("model.py")),
                                             "tools/check_measured_replay.py": digest(Path(__file__))},
        "integer_path": "Existing tools/model.py FFT/NPU; original raw int16 DC preserved; weights unchanged",
        "spectral_display": {"method": "Independent per-frame 64-point rectangular DFT after frame mean subtraction",
                             "frequency_bin_hz": 15.625, "units": "raw ADC counts",
                             "scaling": "one-sided amplitude; interior bins doubled",
                             "timing": "nominal 1 kHz spectrum; measured dt_us separately audited; no interpolation"},
        "timing_limitations": ["host_time_s is one host receipt timestamp per frame, not a sensor timestamp",
                               "frames contain 64 measured samples with dt_us; gaps are not filled",
                               "no continuous-run FFT, precise RPM, displacement, Y/Z or 6-DOF inference"],
        "validation_scope": "Re-evaluation of original held-out runs; not a new external test or deployment accuracy estimate",
        "train": confusion([row for row in rows if row["Split"] == "train"]),
        "validation": confusion([row for row in rows if row["Split"] == "validation"]),
        "all": confusion(rows), "runs": summaries,
        "misclassified_frames": [{key: row[key] for key in ["RunID", "Split", "WindowID", "TrueLabel", "PredictedClass"]}
                                 for row in rows if row["TrueLabel"] != row["PredictedClass"]],
        "matlab_simulink_execution": "not performed by this offline Python reference",
        "window_reference_csv": "measured_reference_frames.csv", "run_summary_csv": "measured_runs.csv",
    }
    write_csv(output / "measured_reference_frames.csv", rows, WINDOW_FIELDS)
    write_csv(output / "measured_runs.csv", summaries)
    (output / "measured_reference.json").write_text(json.dumps(reference, indent=2) + "\n", encoding="utf-8")
    if make_preview:
        preview(audit, rows, output / "measured_preview_3d.png")
    return reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="Project07_VibrationNPU root")
    parser.add_argument("--output", type=Path, help="report output directory")
    parser.add_argument("--no-preview", action="store_true")
    args = parser.parse_args()
    try:
        reference = generate(args.root, args.output, not args.no_preview)
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f"MEASURED AUDIT FAIL: {error}") from error
    print("MEASURED AUDIT PASS: 6 real runs / 360 complete frames / 23040 raw samples")
    print(f"TRAIN {reference['train']['correct']}/240; ORIGINAL VALIDATION {reference['validation']['correct']}/120")
    print("No new MATLAB/Simulink runtime result is claimed by this Python audit.")


if __name__ == "__main__":
    main()
