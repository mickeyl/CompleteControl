#!/usr/bin/env python3
"""Smoke, stress, soak, and compare the complete Widget Lab interaction path."""

import argparse
import json
import os
from pathlib import Path
import queue
import random
import re
import signal
import subprocess
import sys
import threading
import time

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from kk_daemon import (  # noqa: E402
    AutomationClient,
    CLIError,
    DaemonControlClient,
    EXIT_COMMAND,
    EXIT_CONNECTION,
    EXIT_IO,
    HARDWARE_SOCKET,
    SIMULATOR_SOCKET,
    automation_path,
    base_socket_path,
    write_display_pngs,
)


VERSION = "0.1.0"
DEFAULT_WIDGET_LAB = REPO_ROOT / ".build" / "debug" / "widget-lab"
DEFAULT_SCENARIOS = REPO_ROOT / "Tools" / "WidgetLab" / "SmokeScenarios.json"
DISPLAY_WIDTH = 480
DISPLAY_HEIGHT = 272


class TestFailure(Exception):
    pass


def parse_duration(value):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(ms|s|m|h)?", value.strip().lower())
    if not match:
        raise argparse.ArgumentTypeError("use a duration such as 30s, 15m, or 8h")
    number = float(match.group(1))
    unit = match.group(2) or "s"
    factors = {"ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0}
    seconds = number * factors[unit]
    if seconds <= 0:
        raise argparse.ArgumentTypeError("duration must be greater than zero")
    return seconds


def default_output_directory(mode):
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    return Path("/tmp") / ("widget-lab-%s-%s" % (mode, timestamp))


def load_scenarios(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise CLIError("Can't read scenario manifest %s: %s" % (path, error), EXIT_IO) from error
    if document.get("version") != 1 or not isinstance(document.get("scenarios"), list):
        raise CLIError("Scenario manifest must have version 1 and a scenarios array.", EXIT_IO)
    scenarios = document["scenarios"]
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario.get("demo"), str) or not isinstance(scenario.get("actions"), list):
            raise CLIError("Scenario %d needs string demo and actions array." % index, EXIT_IO)
        for action in scenario["actions"]:
            keys = {key for key in ("send", "tap", "wait_ms", "wait_state") if key in action}
            if len(keys) != 1:
                raise CLIError(
                    "Every action in %s needs exactly one of send, tap, wait_ms, or wait_state."
                    % scenario["demo"],
                    EXIT_IO,
                )
    return scenarios


def validate_coverage(catalogue, scenarios):
    demo_ids = [demo["id"] for demo in catalogue]
    scenario_ids = [scenario["demo"] for scenario in scenarios]
    duplicates = sorted({item for item in scenario_ids if scenario_ids.count(item) > 1})
    missing = sorted(set(demo_ids) - set(scenario_ids))
    unknown = sorted(set(scenario_ids) - set(demo_ids))
    if duplicates or missing or unknown:
        details = []
        if duplicates:
            details.append("duplicate scenarios: %s" % ", ".join(duplicates))
        if missing:
            details.append("missing scenarios: %s" % ", ".join(missing))
        if unknown:
            details.append("unknown demos: %s" % ", ".join(unknown))
        raise TestFailure("Scenario coverage mismatch — " + "; ".join(details))


class WidgetLabControl:
    def __init__(self, executable, daemon_socket, artifact_directory, timeout):
        self.executable = str(executable)
        self.daemon_socket = daemon_socket
        self.timeout = timeout
        self.artifact_directory = Path(artifact_directory)
        self.process = None
        self.responses = queue.Queue()
        self.request_id = 0
        self.stderr_path = self.artifact_directory / "widgetlab.stderr.log"
        self._stderr_handle = None

    def start(self):
        if not os.path.isfile(self.executable) or not os.access(self.executable, os.X_OK):
            raise CLIError(
                "Widget Lab executable not found at %s. Run `make widget-lab-build`."
                % self.executable,
                EXIT_IO,
            )
        self.artifact_directory.mkdir(parents=True, exist_ok=True)
        self._stderr_handle = open(self.stderr_path, "w", encoding="utf-8")
        environment = os.environ.copy()
        environment["KK_DAEMON_SOCKET"] = self.daemon_socket
        self.process = subprocess.Popen(
            [self.executable, "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._stderr_handle,
            text=True,
            bufsize=1,
            env=environment,
        )
        threading.Thread(target=self._read_responses, name="widgetlab-json", daemon=True).start()
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            response = self._next_response(deadline - time.monotonic())
            if response.get("event") == "ready":
                return
        raise CLIError("Widget Lab did not enter control mode in time.", EXIT_CONNECTION)

    def _read_responses(self):
        try:
            for line in self.process.stdout:
                try:
                    self.responses.put(json.loads(line))
                except json.JSONDecodeError:
                    self.responses.put({"protocol_error": "non-JSON Widget Lab output", "line": line.rstrip()})
        finally:
            self.responses.put({"eof": True})

    def _next_response(self, timeout):
        try:
            response = self.responses.get(timeout=max(0.01, timeout))
        except queue.Empty as error:
            raise CLIError("Timed out waiting for Widget Lab control response.", EXIT_CONNECTION) from error
        if "protocol_error" in response:
            raise CLIError("%s: %s" % (response["protocol_error"], response["line"]), EXIT_CONNECTION)
        if response.get("eof"):
            code = self.process.poll()
            raise CLIError(
                "Widget Lab control stream closed%s. See %s."
                % ((" with exit code %s" % code) if code is not None else "", self.stderr_path),
                EXIT_CONNECTION,
            )
        return response

    def request(self, command, **fields):
        if self.process is None or self.process.poll() is not None:
            raise CLIError("Widget Lab is no longer running. See %s." % self.stderr_path, EXIT_CONNECTION)
        self.request_id += 1
        request = {"id": self.request_id, "command": command, **fields}
        try:
            self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise CLIError("Can't write to Widget Lab control stream: %s" % error, EXIT_CONNECTION) from error
        deadline = time.monotonic() + self.timeout
        while True:
            response = self._next_response(deadline - time.monotonic())
            if response.get("id") != self.request_id:
                continue
            if not response.get("ok"):
                raise TestFailure("Widget Lab %s failed: %s" % (command, response.get("error", "unknown error")))
            return response

    def close(self):
        if self.process is not None and self.process.poll() is None:
            try:
                self.request("quit")
            except (CLIError, TestFailure):
                self.process.terminate()
            try:
                self.process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2.0)
        if self._stderr_handle is not None:
            self._stderr_handle.close()


def send_automation(client, command):
    response = client.send_line(command)
    if response.startswith("err"):
        raise TestFailure("%s -> %s" % (command, response))
    return response


def release_transient_inputs(client):
    commands = ["button shift up", "fourd release", "strip release"]
    commands += ["encodertouch %d off" % encoder for encoder in range(1, 9)]
    for command in commands:
        try:
            send_automation(client, command)
        except (CLIError, TestFailure):
            pass


def perform_action(client, action, stress_random=None):
    if "wait_ms" in action:
        time.sleep(max(0, float(action["wait_ms"])) / 1000.0)
        return 0
    if "tap" in action:
        button = action["tap"]
        send_automation(client, "button %s down" % button)
        time.sleep(0.015)
        send_automation(client, "button %s up" % button)
        return 2

    command = action["send"]
    if stress_random is not None:
        words = command.split()
        if len(words) == 3 and words[0] == "encoder":
            base = int(words[2])
            words[2] = str(stress_random.choice((-1, 1)) * max(1, abs(base)) * stress_random.randint(1, 4))
            command = " ".join(words)
        elif len(words) == 2 and words[0] == "fourdwheel":
            base = int(words[1])
            words[1] = str(stress_random.choice((-1, 1)) * max(1, abs(base)) * stress_random.randint(1, 4))
            command = " ".join(words)
    send_automation(client, command)
    return 1


def scenario_repeat_count(demo, stress, burst):
    # The display benchmark already performs 12 alternating updates for each
    # fixture and owns the daemon-wide measurement session while it runs.
    return burst if stress and demo != "display-benchmark" else 1


def changed_pixel_count(expected, actual):
    return sum(
        expected[offset : offset + 2] != actual[offset : offset + 2]
        for offset in range(0, min(len(expected), len(actual)), 2)
    ) + abs(len(expected) - len(actual)) // 2


def diff_rgb565(expected, actual):
    output = bytearray()
    for offset in range(0, min(len(expected), len(actual)), 2):
        output += b"\xf8\x00" if expected[offset : offset + 2] != actual[offset : offset + 2] else b"\x00\x00"
    return bytes(output)


def checkpoint(control, daemon, directory, name, settle_timeout, exact=True):
    directory = Path(directory)
    deadline = time.monotonic() + settle_timeout
    last = None
    while True:
        snapshot = control.request("snapshot", directory=str(directory), name=name)["snapshot"]
        expected = [Path(path).read_bytes() for path in snapshot["screensRGB565BE"]]
        metrics = daemon.display_barrier()
        actual_screens = {screen: daemon.display_snapshot(screen) for screen in (0, 1)}
        actual = [actual_screens[screen][2] for screen in (0, 1)]
        differences = [changed_pixel_count(expected[index], actual[index]) for index in (0, 1)]
        last = (snapshot, expected, actual_screens, actual, differences, metrics)
        if exact and differences == [0, 0]:
            return {"ok": True, "differences": differences, "metrics": metrics, "snapshot": snapshot}
        if not exact:
            nonblack = [sum(pixels[offset : offset + 2] != b"\x00\x00" for offset in range(0, len(pixels), 2)) for pixels in actual]
            if all(count > 100 for count in nonblack):
                return {
                    "ok": True,
                    "differences": differences,
                    "nonblackPixels": nonblack,
                    "metrics": metrics,
                    "snapshot": snapshot,
                }
        if time.monotonic() >= deadline:
            break
        time.sleep(0.1)

    snapshot, expected, actual_screens, actual, differences, metrics = last
    write_display_pngs(str(directory), name + "-actual", actual_screens)
    diff_screens = {
        screen: (DISPLAY_WIDTH, DISPLAY_HEIGHT, diff_rgb565(expected[screen], actual[screen]))
        for screen in (0, 1)
    }
    write_display_pngs(str(directory), name + "-diff", diff_screens)
    return {
        "ok": False,
        "differences": differences,
        "metrics": metrics,
        "snapshot": snapshot,
        "error": "display did not settle to the expected frame",
    }


def wait_for_mode(control, expected, timeout):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = control.request("status")
        if last.get("mode") == expected:
            return last
        time.sleep(0.05)
    raise TestFailure("Widget Lab mode is %s, expected %s." % (last.get("mode") if last else "unknown", expected))


def wait_for_state(control, expected, timeout):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = control.request("status")
        if last.get("state") == expected:
            return last
        if last.get("state") == "failed":
            raise TestFailure("Widget Lab activity entered failed state while waiting for %s." % expected)
        time.sleep(0.05)
    raise TestFailure(
        "Widget Lab activity state is %s, expected %s."
        % (last.get("state") if last else "unknown", expected)
    )


def metrics_delta(before, after):
    result = {"encoding": after["encoding"]}
    for key in ("writes", "bytes", "nanoseconds", "failures"):
        result[key] = after[key] - before[key]
    return result


class WidgetLabTestRun:
    def __init__(self, args):
        self.args = args
        self.output = Path(args.output or default_output_directory(args.mode)).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.scenarios = load_scenarios(args.scenarios)
        if args.demo:
            requested = set(args.demo)
            self.scenarios = [scenario for scenario in self.scenarios if scenario["demo"] in requested]
            unknown = requested - {scenario["demo"] for scenario in self.scenarios}
            if unknown:
                raise CLIError("Unknown --demo value: %s" % ", ".join(sorted(unknown)), EXIT_IO)
        self.socket_path = base_socket_path(args.socket or os.environ.get("KK_DAEMON_SOCKET") or SIMULATOR_SOCKET)
        if self.socket_path == HARDWARE_SOCKET and not args.hardware:
            raise CLIError(
                "Refusing to drive physical hardware without --hardware. Use the simulator or opt in explicitly.",
                EXIT_USAGE,
            )
        self.automation_path = automation_path(self.socket_path)
        self.control = None
        self.automation = None
        self.daemon = None
        self.action_count = 0
        self.results = []
        self.failures = []
        self.seed = args.seed if args.seed is not None else int(time.time())
        self.random = random.Random(self.seed)
        self.metrics = {"encoding": "unknown", "writes": 0, "bytes": 0, "nanoseconds": 0, "failures": 0}

    def log(self, message):
        if not self.args.quiet:
            print(message, file=sys.stderr, flush=True)

    def start(self):
        self.log("Artifacts: %s" % self.output)
        self.log("Daemon: %s" % self.socket_path)
        self.log("Starting Widget Lab control client…")
        self.control = WidgetLabControl(
            self.args.widget_lab,
            self.socket_path,
            self.output,
            self.args.timeout,
        )
        self.control.start()
        self.automation = AutomationClient(self.automation_path, self.args.timeout)
        self.automation.connect()
        self.daemon = DaemonControlClient(self.socket_path, self.args.timeout)
        self.daemon.connect()

        catalogue = self.control.request("describe")["demos"]
        all_scenarios = load_scenarios(self.args.scenarios)
        validate_coverage(catalogue, all_scenarios)
        self.log("Scenario coverage: %d/%d demos" % (len(all_scenarios), len(catalogue)))

    def close(self):
        if self.automation is not None:
            release_transient_inputs(self.automation)
            self.automation.close()
        if self.daemon is not None:
            self.daemon.close()
        if self.control is not None:
            self.control.close()

    def initial_browser_check(self):
        self.log("Browser: real 4-D open and SCENE return")
        measurement_before = self.daemon.begin_display_measurements()
        try:
            initial = checkpoint(
                self.control,
                self.daemon,
                self.output / "browser-initial",
                "browser-initial",
                self.args.settle_timeout,
            )
            if not initial["ok"]:
                raise TestFailure("Initial browser snapshot mismatch: %s" % initial["differences"])
            send_automation(self.automation, "fourd click")
            send_automation(self.automation, "fourd release")
            wait_for_mode(self.control, "demo", self.args.settle_timeout)
            self.action_count += 2
            send_automation(self.automation, "button scene down")
            send_automation(self.automation, "button scene up")
            self.action_count += 2
            wait_for_mode(self.control, "browser", self.args.settle_timeout)
            result = checkpoint(
                self.control,
                self.daemon,
                self.output / "browser",
                "browser",
                self.args.settle_timeout,
            )
            if not result["ok"]:
                raise TestFailure("Browser snapshot mismatch: %s" % result["differences"])
        finally:
            self.add_metrics(metrics_delta(measurement_before, self.daemon.end_display_measurements()))

    def add_metrics(self, measurement):
        encoding = measurement["encoding"]
        if self.metrics["encoding"] == "unknown":
            self.metrics["encoding"] = encoding
        elif self.metrics["encoding"] != encoding:
            raise TestFailure(
                "daemon display encoding changed from %s to %s during the run"
                % (self.metrics["encoding"], encoding)
            )
        for key in ("writes", "bytes", "nanoseconds", "failures"):
            self.metrics[key] += measurement[key]

    def run_scenario(self, scenario, iteration, stress=False, take_snapshot=True):
        demo = scenario["demo"]
        self.log("%s #%d" % (demo, iteration))
        measurement_before = None
        measurement_active = False
        try:
            if demo != "display-benchmark":
                measurement_before = self.daemon.begin_display_measurements()
                measurement_active = True
            self.control.request("open", demo=demo)
            if "variant" in scenario:
                self.control.request("prepare", variant=scenario["variant"])

            if not stress:
                if not measurement_active:
                    measurement_before = self.daemon.begin_display_measurements()
                    measurement_active = True
                baseline = checkpoint(
                    self.control,
                    self.daemon,
                    self.output / ("%04d-%s-baseline" % (iteration, demo)),
                    demo + "-baseline",
                    self.args.settle_timeout,
                    exact=scenario.get("checkpoint", "exact") == "exact",
                )
                if not baseline["ok"]:
                    raise TestFailure(
                        "%s baseline snapshot mismatch: %s pixels" % (demo, baseline["differences"])
                    )
                if demo == "display-benchmark":
                    self.add_metrics(
                        metrics_delta(measurement_before, self.daemon.end_display_measurements())
                    )
                    measurement_active = False

            # Repeating the benchmark's start/cancel sequence as an outer burst
            # can overlap asynchronous teardown with the runner's next session.
            repeats = scenario_repeat_count(demo, stress, self.args.burst)
            for _ in range(repeats):
                for action in scenario["actions"]:
                    if "wait_state" in action:
                        wait_for_state(
                            self.control,
                            action["wait_state"],
                            float(action.get("timeout", self.args.settle_timeout)),
                        )
                    else:
                        self.action_count += perform_action(
                            self.automation,
                            action,
                            stress_random=self.random if stress else None,
                        )
                    if "wait_ms" not in action and "wait_state" not in action and self.args.action_delay:
                        time.sleep(self.args.action_delay)
            if not measurement_active:
                measurement_before = self.daemon.begin_display_measurements()
                measurement_active = True
            result = None
            if take_snapshot:
                artifact_dir = self.output / ("%04d-%s" % (iteration, demo))
                result = checkpoint(
                    self.control,
                    self.daemon,
                    artifact_dir,
                    demo,
                    self.args.settle_timeout,
                    exact=scenario.get("checkpoint", "exact") == "exact",
                )
                if not result["ok"]:
                    raise TestFailure("%s snapshot mismatch: %s pixels" % (demo, result["differences"]))
            else:
                metrics = self.daemon.display_barrier()
                if metrics["failures"]:
                    raise TestFailure("daemon recorded %d display transport failures" % metrics["failures"])

            measurement_after = self.daemon.end_display_measurements()
            measurement_active = False
            measurement = metrics_delta(measurement_before, measurement_after)
            self.add_metrics(measurement)
            if result is not None:
                result["measurement"] = measurement

            send_automation(self.automation, "button scene down")
            send_automation(self.automation, "button scene up")
            self.action_count += 2
            wait_for_mode(self.control, "browser", self.args.settle_timeout)
            self.results.append({"demo": demo, "iteration": iteration, "ok": True, "checkpoint": result})
        except (CLIError, TestFailure) as error:
            if measurement_active:
                try:
                    self.add_metrics(metrics_delta(measurement_before, self.daemon.end_display_measurements()))
                except (CLIError, TestFailure):
                    pass
            release_transient_inputs(self.automation)
            failure = {"demo": demo, "iteration": iteration, "error": str(error)}
            self.failures.append(failure)
            self.results.append({**failure, "ok": False})
            self.log("FAILED: %s" % error)
            try:
                self.control.request("browser")
            except (CLIError, TestFailure):
                pass
            if self.args.fail_fast:
                raise

    def execute(self):
        started_wall = time.time()
        started = time.monotonic()
        self.start()
        self.initial_browser_check()
        self.log("Encoding: %s; seed: %d" % (self.metrics["encoding"], self.seed))

        if self.args.mode == "smoke":
            for iteration, scenario in enumerate(self.scenarios, start=1):
                self.run_scenario(scenario, iteration)
        else:
            deadline = started + self.args.duration
            iteration = 0
            next_snapshot = started
            catalogue_pass = 0
            while (self.args.cycles is not None and catalogue_pass < self.args.cycles) or (
                self.args.cycles is None and time.monotonic() < deadline
            ):
                catalogue_pass += 1
                ordered = list(self.scenarios)
                self.random.shuffle(ordered)
                for scenario in ordered:
                    if self.args.cycles is None and time.monotonic() >= deadline:
                        break
                    iteration += 1
                    now = time.monotonic()
                    take_snapshot = now >= next_snapshot
                    self.run_scenario(scenario, iteration, stress=True, take_snapshot=take_snapshot)
                    if take_snapshot:
                        next_snapshot = now + self.args.snapshot_interval

        ended_wall = time.time()
        metrics_before = {"encoding": self.metrics["encoding"], "writes": 0, "bytes": 0, "nanoseconds": 0, "failures": 0}
        metrics_after = dict(self.metrics)
        report = {
            "schemaVersion": 1,
            "toolVersion": VERSION,
            "mode": self.args.mode,
            "passed": not self.failures and self.metrics["failures"] == 0,
            "seed": self.seed,
            "socket": self.socket_path,
            "startedAt": started_wall,
            "endedAt": ended_wall,
            "durationSeconds": ended_wall - started_wall,
            "actionCount": self.action_count,
            "scenarioCount": len(self.results),
            "cataloguePassCount": 1 if self.args.mode == "smoke" else catalogue_pass,
            "metricsBefore": metrics_before,
            "metricsAfter": metrics_after,
            "metricsDelta": dict(self.metrics),
            "failures": self.failures,
            "results": self.results,
        }
        report_path = self.output / "report.json"
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return report, report_path


def compare_reports(args):
    try:
        adaptive = json.loads(Path(args.adaptive_report).read_text(encoding="utf-8"))
        legacy = json.loads(Path(args.legacy_report).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CLIError("Can't read comparison reports: %s" % error, EXIT_IO) from error

    problems = []
    if adaptive.get("metricsDelta", {}).get("encoding") != "adaptive":
        problems.append("adaptive report does not identify adaptive encoding")
    if legacy.get("metricsDelta", {}).get("encoding") != "legacy":
        problems.append("legacy report does not identify legacy encoding")
    for label, report in (("adaptive", adaptive), ("legacy", legacy)):
        if not report.get("passed"):
            problems.append("%s run did not pass" % label)
        if report.get("metricsDelta", {}).get("failures") != 0:
            problems.append("%s run recorded transport failures" % label)
    for key in ("seed", "actionCount", "scenarioCount"):
        if adaptive.get(key) != legacy.get(key):
            problems.append("reports have different %s" % key)

    adaptive_bytes = adaptive.get("metricsDelta", {}).get("bytes", 0)
    legacy_bytes = legacy.get("metricsDelta", {}).get("bytes", 0)
    allowed_bytes = legacy_bytes * (1.0 + args.allow_adaptive_overhead / 100.0)
    if adaptive_bytes > allowed_bytes:
        problems.append(
            "adaptive used %d bytes versus %d legacy bytes" % (adaptive_bytes, legacy_bytes)
        )

    def average_latency(report):
        metrics = report.get("metricsDelta", {})
        return metrics.get("nanoseconds", 0) / max(1, metrics.get("writes", 0))

    adaptive_latency = average_latency(adaptive)
    legacy_latency = average_latency(legacy)
    if adaptive_latency > legacy_latency * (1.0 + args.max_latency_regression / 100.0):
        problems.append("adaptive average transport latency exceeds the allowed regression")

    comparison = {
        "passed": not problems,
        "adaptiveReport": str(Path(args.adaptive_report).resolve()),
        "legacyReport": str(Path(args.legacy_report).resolve()),
        "adaptiveBytes": adaptive_bytes,
        "legacyBytes": legacy_bytes,
        "byteReductionPercent": (
            100.0 * (legacy_bytes - adaptive_bytes) / legacy_bytes if legacy_bytes else 0.0
        ),
        "adaptiveAverageTransportNanoseconds": adaptive_latency,
        "legacyAverageTransportNanoseconds": legacy_latency,
        "problems": problems,
    }
    if args.json:
        print(json.dumps(comparison, indent=2, sort_keys=True))
    else:
        print("PASS" if comparison["passed"] else "FAIL")
        print("adaptive bytes: %d" % adaptive_bytes)
        print("legacy bytes:   %d" % legacy_bytes)
        print("reduction:      %.2f%%" % comparison["byteReductionPercent"])
        for problem in problems:
            print("error: %s" % problem, file=sys.stderr)
    return 0 if comparison["passed"] else EXIT_COMMAND


def validate_command(args):
    executable = Path(args.widget_lab)
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise CLIError(
            "Widget Lab executable not found at %s. Run `make widget-lab-build`." % executable,
            EXIT_IO,
        )
    try:
        process = subprocess.run(
            [str(executable), "--describe-json"],
            check=True,
            capture_output=True,
            text=True,
            timeout=args.timeout,
        )
        catalogue = json.loads(process.stdout)
    except (subprocess.SubprocessError, json.JSONDecodeError) as error:
        raise CLIError("Can't read Widget Lab catalogue: %s" % error, EXIT_IO) from error
    scenarios = load_scenarios(args.scenarios)
    validate_coverage(catalogue, scenarios)
    result = {"passed": True, "demoCount": len(catalogue), "scenarioCount": len(scenarios)}
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print("PASS — scenario coverage %d/%d demos" % (len(scenarios), len(catalogue)))
    return 0


def add_run_options(parser, mode):
    parser.set_defaults(mode=mode)
    parser.add_argument("--socket", metavar="PATH", help="daemon base or automation socket (default: simulator)")
    parser.add_argument("--hardware", action="store_true", help="allow the physical hardware daemon")
    parser.add_argument(
        "--widget-lab",
        default=str(DEFAULT_WIDGET_LAB),
        metavar="PATH",
        help="Widget Lab executable (default: %(default)s)",
    )
    parser.add_argument(
        "--scenarios",
        default=str(DEFAULT_SCENARIOS),
        metavar="PATH",
        help="scenario manifest (default: %(default)s)",
    )
    parser.add_argument("--demo", action="append", help="run one demo; repeat for multiple demos")
    parser.add_argument("-o", "--output", metavar="DIR", help="artifact directory (default: a new /tmp directory)")
    parser.add_argument("--timeout", type=float, default=5.0, metavar="SECONDS", help="socket timeout (default: 5)")
    parser.add_argument(
        "--settle-timeout",
        type=float,
        default=5.0,
        metavar="SECONDS",
        help="maximum exact-snapshot settle time (default: 5)",
    )
    parser.add_argument("--seed", type=int, help="random seed (stress/soak default: current time)")
    parser.add_argument("--fail-fast", action="store_true", help="stop after the first failed scenario")
    parser.add_argument(
        "--action-delay",
        type=float,
        default=0.075 if mode == "smoke" else 0.002,
        metavar="SECONDS",
        help="settle delay after input actions (default: %(default)s)",
    )
    parser.add_argument("-q", "--quiet", action="store_true", help="suppress progress output")
    parser.add_argument("--json", action="store_true", help="write the final report JSON to stdout")
    parser.add_argument("--burst", type=int, default=1 if mode == "smoke" else 3, metavar="COUNT")
    if mode != "smoke":
        default_duration = "15m" if mode == "stress" else "8h"
        default_interval = "15s" if mode == "stress" else "1m"
        parser.add_argument("--duration", type=parse_duration, default=parse_duration(default_duration), metavar="DURATION")
        parser.add_argument(
            "--cycles",
            type=int,
            metavar="COUNT",
            help="run a fixed number of complete catalogue passes instead of using --duration",
        )
        parser.add_argument(
            "--snapshot-interval",
            type=parse_duration,
            default=parse_duration(default_interval),
            metavar="DURATION",
        )


def make_parser():
    parser = argparse.ArgumentParser(
        description="Drive every Widget Lab demo through ccd and verify live display output.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  widget-lab-test.py smoke
  widget-lab-test.py stress --duration 30m --seed 42
  widget-lab-test.py soak --duration 8h --output /tmp/adaptive-soak
  widget-lab-test.py compare --adaptive-report A/report.json --legacy-report B/report.json

The runner launches and later stops only its own Widget Lab process. It never restarts,
reconfigures, or stops ccd. Physical hardware requires the explicit --hardware flag.
""",
    )
    parser.add_argument("--version", action="version", version="widget-lab-test %s" % VERSION)
    subparsers = parser.add_subparsers(dest="subcommand", required=True)
    for mode in ("smoke", "stress", "soak"):
        add_run_options(subparsers.add_parser(mode, help="run the %s profile" % mode), mode)
    validate = subparsers.add_parser("validate", help="validate scenario coverage without a daemon")
    validate.set_defaults(mode="validate")
    validate.add_argument("--widget-lab", default=str(DEFAULT_WIDGET_LAB), metavar="PATH")
    validate.add_argument("--scenarios", default=str(DEFAULT_SCENARIOS), metavar="PATH")
    validate.add_argument("--timeout", type=float, default=5.0, metavar="SECONDS")
    validate.add_argument("--json", action="store_true")
    compare = subparsers.add_parser("compare", help="compare completed adaptive and legacy reports")
    compare.set_defaults(mode="compare")
    compare.add_argument("--adaptive-report", required=True, metavar="PATH")
    compare.add_argument("--legacy-report", required=True, metavar="PATH")
    compare.add_argument("--allow-adaptive-overhead", type=float, default=0.0, metavar="PERCENT")
    compare.add_argument("--max-latency-regression", type=float, default=20.0, metavar="PERCENT")
    compare.add_argument("--json", action="store_true")
    return parser


def main(argv=None):
    parser = make_parser()
    args = parser.parse_args(argv)
    if args.mode in ("compare", "validate"):
        try:
            return compare_reports(args) if args.mode == "compare" else validate_command(args)
        except (CLIError, TestFailure) as error:
            print("error: %s" % error, file=sys.stderr)
            return error.exit_code if isinstance(error, CLIError) else EXIT_COMMAND

    if args.timeout <= 0 or args.settle_timeout <= 0:
        parser.error("--timeout and --settle-timeout must be greater than zero")
    if args.action_delay < 0:
        parser.error("--action-delay cannot be negative")
    if args.burst <= 0:
        parser.error("--burst must be greater than zero")
    if args.mode != "smoke" and args.cycles is not None and args.cycles <= 0:
        parser.error("--cycles must be greater than zero")

    run = None
    interrupted = False
    try:
        run = WidgetLabTestRun(args)
        report, report_path = run.execute()
        if args.json:
            print(json.dumps(report, indent=2, sort_keys=True))
        else:
            print("PASS" if report["passed"] else "FAIL")
            print("report: %s" % report_path)
            print("encoding: %s" % report["metricsDelta"]["encoding"])
            print("actions: %d; scenarios: %d" % (report["actionCount"], report["scenarioCount"]))
        return 0 if report["passed"] else EXIT_COMMAND
    except KeyboardInterrupt:
        interrupted = True
        print("Stopping…", file=sys.stderr)
        return 130
    except (CLIError, TestFailure) as error:
        print("error: %s" % error, file=sys.stderr)
        return error.exit_code if isinstance(error, CLIError) else EXIT_COMMAND
    finally:
        if run is not None:
            run.close()
        if interrupted:
            signal.signal(signal.SIGINT, signal.SIG_DFL)


if __name__ == "__main__":
    sys.exit(main())
