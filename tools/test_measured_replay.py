#!/usr/bin/env python3
"""Real-capture regression and fail-closed corruption tests; no generated dataset."""
import csv
import json
import shutil
import tempfile
import unittest
from pathlib import Path

import numpy as np

import check_measured_replay as subject


class MeasuredReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.audit = subject.audit_inputs()
        cls.rows, cls.runs = subject.calculate_reference(cls.audit)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="measured_replay_test_")
        self.root = Path(self.temporary.name)
        for filename in self.audit["input_sha256"]:
            destination = self.root / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(subject.ROOT / filename, destination)
        self.manifest_path = self.root / "data/dataset_source.json"
        self.manifest = json.loads(self.manifest_path.read_text())
        self.source = self.manifest["source_runs"][0]
        self.capture = self.root / self.source["file"]

    def tearDown(self):
        self.temporary.cleanup()

    def save_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def alter_rows(self, edit, refresh_hash=True):
        with self.capture.open(newline="") as handle:
            reader = csv.DictReader(handle)
            fields = reader.fieldnames
            rows = list(reader)
        edit(rows)
        with self.capture.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)
        if refresh_hash:
            self.source["sha256"] = subject.digest(self.capture)
            self.save_manifest()

    def reject(self, message):
        with self.assertRaisesRegex(ValueError, message):
            subject.audit_inputs(self.root)

    def test_actual_capture_counts_and_original_validation(self):
        self.assertEqual(len(self.rows), 360)
        self.assertEqual(sum(run["samples"].size for run in self.audit["runs"]), 23040)
        self.assertEqual(subject.confusion([row for row in self.rows if row["Split"] == "train"])["correct"], 240)
        result = subject.confusion([row for row in self.rows if row["Split"] == "validation"])
        historical = json.loads((subject.ROOT / "data/training_metrics.json").read_text())
        self.assertEqual(result["confusion_true_rows_predicted_columns"], historical["confusion"])
        self.assertEqual(result["accuracy"], historical["int8_accuracy"])

    def test_existing_hardware_golden_vectors_for_actual_frames(self):
        data = subject.ROOT / "data"
        cases = np.loadtxt(data / "cases.csv", delimiter=",", dtype=np.int64)
        lookup = {}
        for run in self.audit["runs"]:
            run_rows = [row for row in self.rows if row["RunID"] == run["run_id"]]
            lookup.update({tuple(samples): row for samples, row in zip(run["samples"], run_rows)})
        def read_mem(name, width, signed=False):
            values = [int(line, 16) for line in (data / name).read_text().splitlines()]
            if signed:
                values = [value - 256 if value >= 128 else value for value in values]
            return np.asarray(values).reshape(-1, width)
        golden_features = read_mem("features.mem", 4)
        golden_hidden = read_mem("hidden.mem", 4)
        golden_logits = read_mem("logits.mem", 2, True)
        golden_class = read_mem("class.mem", 1)
        matched = 0
        for index, samples in enumerate(cases):
            if tuple(samples) not in lookup:
                continue  # Existing edge-case vectors are not measured records.
            row = lookup[tuple(samples)]
            self.assertEqual([row[f"F{i}"] for i in range(1, 5)], golden_features[index].tolist())
            self.assertEqual([row[f"H{i}"] for i in range(1, 5)], golden_hidden[index].tolist())
            self.assertEqual([row[f"L{i}"] for i in range(2)], golden_logits[index].tolist())
            self.assertEqual(row["PredictedClass"], golden_class[index, 0])
            matched += 1
        self.assertEqual(matched, 16)

    def test_recorded_dc_and_discontinuity_are_preserved(self):
        for run in self.audit["runs"]:
            self.assertGreater(run["samples"].mean(), 16000)
            self.assertTrue(np.all(np.diff(run["host_time_s"]) > 0.38))
            self.assertTrue(np.all(run["frame_duration_s"] < 0.064))
        self.assertEqual(self.rows[0]["RawMean_counts"], float(self.audit["runs"][0]["samples"][0].mean()))

    def test_missing_source_is_rejected(self):
        self.capture.unlink()
        self.reject("missing required input")

    def test_missing_metadata_is_rejected(self):
        self.capture.with_suffix(".json").unlink()
        self.reject("missing required input")

    def test_source_hash_tamper_is_rejected(self):
        self.alter_rows(lambda rows: rows[0].update(raw_x="0"), refresh_hash=False)
        self.reject("capture SHA-256 mismatch")

    def test_metadata_hash_tamper_is_rejected(self):
        with self.capture.with_suffix(".json").open("a") as handle:
            handle.write(" ")
        self.reject("metadata SHA-256 mismatch")

    def test_manifest_embedded_metadata_mismatch_is_rejected(self):
        self.source["acquisition"]["supply_v"] = 13
        self.save_manifest()
        self.reject("embedded acquisition metadata mismatch")

    def test_wrong_supply_even_with_matching_hashes_is_rejected(self):
        sidecar = self.capture.with_suffix(".json")
        metadata = json.loads(sidecar.read_text())
        metadata["supply_v"] = 13
        sidecar.write_text(json.dumps(metadata))
        self.source["acquisition"] = metadata
        self.source["metadata_sha256"] = subject.digest(sidecar)
        self.save_manifest()
        self.reject("sidecar acquisition contract supply_v")

    def test_missing_whole_frame_even_with_matching_hash_is_rejected(self):
        self.alter_rows(lambda rows: rows.__delitem__(slice(64, 128)))
        self.reject("expected 60 complete frames")

    def test_disordered_samples_even_with_matching_hash_are_rejected(self):
        def reorder(rows):
            rows[1], rows[2] = rows[2], rows[1]
        self.alter_rows(reorder)
        self.reject("sample order must be chronological")

    def test_noncontiguous_frame_ids_are_rejected(self):
        def rename(rows):
            for row in rows[-64:]:
                row["window"] = "60"
        self.alter_rows(rename)
        self.reject("frame IDs must be chronological")

    def test_multiple_host_stamps_in_frame_are_rejected(self):
        self.alter_rows(lambda rows: rows[1].update(host_time_s="1789348594.7"))
        self.reject("one finite host receipt timestamp")

    def test_nonmonotonic_host_stamps_are_rejected(self):
        def edit(rows):
            for row in rows[64:128]:
                row["host_time_s"] = rows[0]["host_time_s"]
        self.alter_rows(edit)
        self.reject("host timestamps not strictly increasing")

    def test_invalid_sample_dt_is_rejected(self):
        self.alter_rows(lambda rows: rows[1].update(dt_us="500"))
        self.reject("invalid dt_us")

    def test_fake_dataset_type_is_rejected(self):
        self.manifest["type"] = "synthetic"
        self.save_manifest()
        self.reject("type=real")

    def test_overlapping_run_split_is_rejected(self):
        self.manifest["validation_run_ids"][0] = "normal_50_01"
        self.save_manifest()
        self.reject("split overlap")

    def test_reordered_split_without_reordered_export_is_rejected(self):
        self.manifest["train_run_ids"].reverse()
        self.save_manifest()
        self.reject("train samples differ")

    def test_exported_sample_change_is_rejected(self):
        path = self.root / "data/val_samples.csv"
        values = np.loadtxt(path, delimiter=",", dtype=np.int64)
        values[0, 0] += 1
        np.savetxt(path, values, delimiter=",", fmt="%d")
        self.reject("validation samples differ")

    def test_exported_feature_change_is_rejected(self):
        path = self.root / "data/train_features.csv"
        values = np.loadtxt(path, delimiter=",", dtype=np.int64)
        values[0, 0] += 1
        np.savetxt(path, values, delimiter=",", fmt="%d")
        with self.assertRaisesRegex(ValueError, "exported features differ"):
            subject.calculate_reference(subject.audit_inputs(self.root))

    def test_output_records_input_hashes_and_no_runtime_claim(self):
        reference = subject.generate(self.root, self.root / "reports", make_preview=False)
        for item in reference["source_files"]:
            self.assertEqual(subject.digest(self.root / item["file"]), item["sha256"])
        self.assertEqual(reference["model_sha256"], subject.digest(self.root / "data/model.json"))
        self.assertEqual(reference["manifest_sha256"], subject.digest(self.manifest_path))
        self.assertIn("not performed", reference["matlab_simulink_execution"])
        self.assertTrue((self.root / "reports/measured_reference_frames.csv").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
