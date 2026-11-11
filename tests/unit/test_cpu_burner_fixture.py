"""Ownership regressions and bounded Linux process lifecycle integration."""

import ctypes
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "tests/fixtures/cpu-burner.py"
SHELL = ROOT / "tests/fixtures/cpu-burner.sh"
spec = importlib.util.spec_from_file_location("burner", WORKER)
burner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(burner)


class Ownership(unittest.TestCase):
    def setUp(self):
        self.identity = (101, 77, 101, 101, 12345)

    def test_053_only_verified_pidfd_receives_signal(self):
        for pid in [50, 101, 202]:
            record = (pid, 77, pid, pid, 12345)
            with self.subTest(pid=pid), \
                    mock.patch.object(burner.os, "getppid", return_value=77), \
                    mock.patch.object(burner.os, "getpgrp", return_value=70), \
                    mock.patch.object(burner.os, "pidfd_open", return_value=9) as opened, \
                    mock.patch.object(burner.os, "close"), \
                    mock.patch.object(burner, "identity", return_value=record), \
                    mock.patch.object(burner.signal, "pidfd_send_signal") as sent:
                self.assertEqual(burner.stop(record), 0)
                opened.assert_called_once_with(pid)
                sent.assert_called_once_with(9, signal.SIGKILL)

    def test_054_invalid_stale_caller_and_unowned_targets(self):
        invalid = [(), (0, 77, 0, 0, 12345), (1, 77, 1, 1, 12345),
                   ("", 77, 101, 101, 12345), ("oops", 77, 101, 101, 12345),
                   (-101, 77, -101, -101, 12345), (101, 99, 101, 101, 12345),
                   (101, 77, 70, 101, 12345), (101, 77, 101, 70, 12345),
                   (70, 77, 70, 70, 12345), (77, 77, 77, 77, 12345),
                   (101, 77, 101, 101, 99999)]
        for expected in invalid:
            with self.subTest(expected=expected), \
                    mock.patch.object(burner.os, "getppid", return_value=77), \
                    mock.patch.object(burner.os, "getpgrp", return_value=70), \
                    mock.patch.object(burner.os, "pidfd_open", return_value=9), \
                    mock.patch.object(burner.os, "close"), \
                    mock.patch.object(burner, "identity", return_value=self.identity), \
                    mock.patch.object(burner.signal, "pidfd_send_signal") as sent:
                self.assertNotEqual(burner.stop(expected), 0)
                sent.assert_not_called()
        for actual in [None, (101, 88, 101, 101, 12345),
                       (101, 77, 102, 101, 12345), (101, 77, 101, 102, 12345),
                       (101, 77, 101, 101, 12346)]:
            with self.subTest(actual=actual), \
                    mock.patch.object(burner.os, "getppid", return_value=77), \
                    mock.patch.object(burner.os, "getpgrp", return_value=70), \
                    mock.patch.object(burner.os, "pidfd_open", return_value=9), \
                    mock.patch.object(burner.os, "close"), \
                    mock.patch.object(burner, "identity", return_value=actual), \
                    mock.patch.object(burner.signal, "pidfd_send_signal") as sent:
                self.assertNotEqual(burner.stop(self.identity), 0)
                sent.assert_not_called()


RUNNER = r'''
set -euo pipefail
source "$1"
fixture_dir="$2"
pgrep() {
    touch "$fixture_dir/discovery-used"
    printf '%s\n' "${CPU_TEST_CANDIDATES:-101 202}" | tr ' ' '\n'
}
trap 'cpu_burner_cleanup' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[[ "$3" != job-control ]] || set -m
cpu_burner_start "$2" "$2" 3
if cpu_burner_stop "" || cpu_burner_stop 0 || cpu_burner_stop "$$"; then
    exit 99
fi
saved_record="${_CPU_BURNER_RECORDS[$CPU_BURNER_PID]}"
_CPU_BURNER_RECORDS[$CPU_BURNER_PID]="${saved_record% *} 2"
if cpu_burner_stop "$CPU_BURNER_PID"; then exit 99; fi
_CPU_BURNER_RECORDS[$CPU_BURNER_PID]="$saved_record"
printf '%s\n' "$CPU_BURNER_PID" > "$2/pid"
# These runners have their own sessions, so the observer's watchdog cannot
# reach them. Bound their wait too if the observer itself disappears.
deadline=$((SECONDS + 6))
while [[ ! -f "$2/go" && "$SECONDS" -lt "$deadline" ]]; do sleep 0.02; done
[[ -f "$2/go" ]] || exit 24
case "$3" in
    fail) exit 23 ;;
    startup-fail) cpu_burner_start "$2" "$2" 0 ;;
    expiry)
        sleep 3.2
        if cpu_burner_alive "$CPU_BURNER_PID"; then exit 99; fi
        cpu_burner_stop "$CPU_BURNER_PID"
        ;;
esac
'''


class Lifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Reap burners adopted after forced runner death, even under a PID 1
        # that does not reap orphans. This affects only this isolated observer.
        if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runners = []
        self.owned = []
        self.watchdogs = []
        self.sentinel = subprocess.Popen(["sleep", "30"], start_new_session=True)

    def tearDown(self):
        try:
            for runner, directory in self.runners:
                (directory / "go").touch()
                try:
                    runner.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    runner.kill()  # Popen's owned direct child, never a group.
                    runner.wait(timeout=2)
            for record in self.owned:
                self.await_exit(record, 5)
        finally:
            # These pinned handles remain safe even if the worker's own timer
            # is the regression. Keep an independent watchdog alive until here.
            for fd, watchdog in self.watchdogs:
                try:
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.close(fd)
                watchdog.terminate()
                watchdog.wait(timeout=2)
            for record in self.owned:
                try:
                    os.waitpid(record[0], 0)
                except ChildProcessError:
                    pass
            self.sentinel.terminate()
            self.sentinel.wait(timeout=2)
            self.tmp.cleanup()

    def launch(self, mode="normal", candidates="101 202", block_alarm=False):
        directory = Path(self.tmp.name) / str(len(self.runners))
        directory.mkdir()
        runner = subprocess.Popen(["bash", "-c", RUNNER, "_", str(SHELL),
                                   str(directory), mode], start_new_session=True,
                                  env={**os.environ, "CPU_TEST_CANDIDATES": candidates},
                                  preexec_fn=(lambda: signal.pthread_sigmask(
                                      signal.SIG_BLOCK, {signal.SIGALRM})) if block_alarm else None)
        self.runners.append((runner, directory))
        deadline = time.monotonic() + 2
        while not (directory / "pid").exists():
            self.assertIsNone(runner.poll(), "runner failed before readiness")
            self.assertLess(time.monotonic(), deadline, "readiness timeout")
            time.sleep(0.01)
        pid = int((directory / "pid").read_text())
        fd = os.pidfd_open(pid)
        record = burner.identity(pid)
        self.assertIsNotNone(record)
        self.assertEqual(record[1], runner.pid)
        self.assertEqual(record[2:4], (pid, pid))
        # The worker escapes the outer timeout's process group intentionally.
        # This independent watchdog holds its verified pidfd and survives loss
        # of this observer too; a broken worker timer cannot leak a CPU burner.
        watchdog = subprocess.Popen([
            sys.executable, "-c",
            "import signal,sys,time; time.sleep(10)\n"
            "try: signal.pidfd_send_signal(int(sys.argv[1]), signal.SIGKILL)\n"
            "except ProcessLookupError: pass\n", str(fd)],
            pass_fds=(fd,), start_new_session=True,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.watchdogs.append((fd, watchdog))
        self.owned.append(record)
        return runner, directory, record

    def alive(self, record):
        current = burner.identity(record[0])
        # Parent changes after runner loss; that does not mean the worker died.
        return current is not None and current[0] == record[0] and current[4] == record[4]

    def await_exit(self, record, seconds=5):
        deadline = time.monotonic() + seconds
        while self.alive(record):
            self.assertLess(time.monotonic(), deadline, f"burner survived: {record}")
            time.sleep(0.02)
        try:
            os.waitpid(record[0], os.WNOHANG)
        except ChildProcessError:
            pass
        self.assertIsNone(self.sentinel.poll(), "unrelated sentinel was signaled")

    def test_055_normal_and_failure_reap_children(self):
        for mode, expected_rc in [("normal", 0), ("fail", 23)]:
            runner, directory, record = self.launch(mode)
            (directory / "go").touch()
            self.assertEqual(runner.wait(timeout=2), expected_rc)
            self.assertFalse(Path(f"/proc/{record[0]}").exists(), "child not reaped")
            self.await_exit(record)

    def test_053_candidate_order_does_not_affect_actual_lifecycle(self):
        for candidates in ["101 202", "202 101", ""]:
            runner, directory, record = self.launch(candidates=candidates)
            (directory / "go").touch()
            self.assertEqual(runner.wait(timeout=2), 0)
            self.await_exit(record)
            self.assertFalse((directory / "discovery-used").exists())

    def test_056_supported_interruptions(self):
        for sig in [signal.SIGHUP, signal.SIGINT, signal.SIGTERM]:
            runner, _, record = self.launch()
            runner.send_signal(sig)
            self.assertEqual(runner.wait(timeout=2), 128 + sig)
            self.assertFalse(Path(f"/proc/{record[0]}").exists(), "child not reaped")
            self.await_exit(record)

    def test_057_abrupt_runner_and_session_loss(self):
        for whole_group in [False, True]:
            runner, _, record = self.launch()
            before = time.monotonic()
            if whole_group:
                # Popen(start_new_session=True) owns this isolated live group.
                self.assertEqual(os.getpgid(runner.pid), runner.pid)
                self.assertNotEqual(runner.pid, os.getpgrp())
                os.killpg(runner.pid, signal.SIGKILL)
            else:
                runner.kill()
            runner.wait(timeout=2)
            self.await_exit(record)
            self.assertLess(time.monotonic() - before, 5)
            print(f"TC-LGC4-057 group={whole_group} pid={record[0]} exited; sentinel alive")

    def test_058_overlapping_owners(self):
        first, dir1, record1 = self.launch()
        second, dir2, record2 = self.launch()
        (dir1 / "go").touch()
        self.assertEqual(first.wait(timeout=2), 0)
        self.await_exit(record1)
        self.assertTrue(self.alive(record2), "first owner killed second's child")
        (dir2 / "go").touch()
        self.assertEqual(second.wait(timeout=2), 0)
        self.await_exit(record2)

    def test_059_job_control_and_startup_failure(self):
        for mode, success in [("job-control", True), ("startup-fail", False)]:
            runner, directory, record = self.launch(mode)
            (directory / "go").touch()
            self.assertEqual(runner.wait(timeout=2) == 0, success)
            self.await_exit(record)

    def test_059_expired_worker_is_not_reported_alive(self):
        runner, directory, record = self.launch("expiry")
        (directory / "go").touch()
        self.assertEqual(runner.wait(timeout=5), 0)
        self.assertFalse(Path(f"/proc/{record[0]}").exists(), "expired child not reaped")
        self.await_exit(record)

    def test_060_inherited_blocked_alarm_after_runner_loss(self):
        runner, _, record = self.launch(block_alarm=True)
        runner.kill()
        runner.wait(timeout=2)
        self.await_exit(record)


if __name__ == "__main__":
    unittest.main(verbosity=2)
