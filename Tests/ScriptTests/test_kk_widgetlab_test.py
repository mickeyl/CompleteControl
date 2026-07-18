import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest


REPO_ROOT = Path(__file__).parents[2]
SCRIPT_PATH = REPO_ROOT / "Scripts" / "kk-widgetlab-test.py"
SPEC = importlib.util.spec_from_file_location("kk_widgetlab_test", SCRIPT_PATH)
widgetlab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(widgetlab)


class DurationTests(unittest.TestCase):
    def test_human_durations(self):
        self.assertEqual(widgetlab.parse_duration("250ms"), 0.25)
        self.assertEqual(widgetlab.parse_duration("2m"), 120)
        self.assertEqual(widgetlab.parse_duration("1.5h"), 5400)


class ScenarioTests(unittest.TestCase):
    def test_checked_in_manifest_covers_unique_demo_ids(self):
        scenarios = widgetlab.load_scenarios(widgetlab.DEFAULT_SCENARIOS)
        ids = [scenario["demo"] for scenario in scenarios]
        self.assertEqual(len(ids), 15)
        self.assertEqual(len(ids), len(set(ids)))

    def test_coverage_reports_missing_and_unknown_demos(self):
        catalogue = [{"id": "one"}, {"id": "two"}]
        scenarios = [{"demo": "one"}, {"demo": "three"}]
        with self.assertRaisesRegex(widgetlab.TestFailure, "missing scenarios: two"):
            widgetlab.validate_coverage(catalogue, scenarios)

    def test_stress_bursts_leave_the_self_measuring_benchmark_serial(self):
        self.assertEqual(widgetlab.scenario_repeat_count("meter", True, 3), 3)
        self.assertEqual(widgetlab.scenario_repeat_count("display-benchmark", True, 3), 1)
        self.assertEqual(widgetlab.scenario_repeat_count("meter", False, 3), 1)


class PixelTests(unittest.TestCase):
    def test_diff_counts_rgb565_pixels_and_marks_changes_red(self):
        expected = b"\x00\x00\x12\x34"
        actual = b"\x00\x00\x12\x35"
        self.assertEqual(widgetlab.changed_pixel_count(expected, actual), 1)
        self.assertEqual(widgetlab.diff_rgb565(expected, actual), b"\x00\x00\xf8\x00")


class ComparisonTests(unittest.TestCase):
    def test_matching_successful_reports_compare_cleanly(self):
        base = {
            "passed": True,
            "seed": 42,
            "actionCount": 100,
            "scenarioCount": 13,
        }
        adaptive = {
            **base,
            "metricsDelta": {
                "encoding": "adaptive",
                "writes": 10,
                "bytes": 100,
                "nanoseconds": 1000,
                "failures": 0,
            },
        }
        legacy = {
            **base,
            "metricsDelta": {
                "encoding": "legacy",
                "writes": 10,
                "bytes": 200,
                "nanoseconds": 1000,
                "failures": 0,
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            adaptive_path = Path(directory) / "adaptive.json"
            legacy_path = Path(directory) / "legacy.json"
            adaptive_path.write_text(json.dumps(adaptive), encoding="utf-8")
            legacy_path.write_text(json.dumps(legacy), encoding="utf-8")
            args = type("Args", (), {
                "adaptive_report": str(adaptive_path),
                "legacy_report": str(legacy_path),
                "allow_adaptive_overhead": 0.0,
                "max_latency_regression": 20.0,
                "json": False,
            })()
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(widgetlab.compare_reports(args), 0)


if __name__ == "__main__":
    unittest.main()
