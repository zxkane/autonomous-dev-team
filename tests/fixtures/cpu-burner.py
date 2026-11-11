#!/usr/bin/env python3
"""A single, self-expiring Linux CPU worker and pidfd-based cleanup.

There is no launcher fork, supervisor, process-name lookup or group signal.
The shell owns/reaps the child. Its kernel wall timer survives runner death.
"""

import math
import os
from pathlib import Path
import signal
import sys


def identity(pid):
    """Return pid, parent, group, session, start ticks for a live process."""
    try:
        # comm can contain spaces and parentheses; fields follow the final ')'.
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] in ("Z", "X"):
            return None
        return (pid, int(fields[1]), int(fields[2]), int(fields[3]), int(fields[19]))
    except (OSError, ValueError, IndexError):
        return None


def stop(expected):
    """Signal only a verified direct child of the invoking shell.

    Exit 2 means the child already exited, 1 means ownership is unverified.
    Opening the pidfd before rechecking identity prevents PID-reuse signaling.
    """
    if len(expected) != 5 or any(type(n) is not int or n <= 1 for n in expected):
        return 1
    pid, parent, pgid, sid, _ = expected
    if parent != os.getppid() or pid == parent or pgid != pid or sid != pid:
        return 1
    if pgid == os.getpgrp():
        return 1
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        return 2
    except OSError:
        return 1
    try:
        actual = identity(pid)
        if actual is None:
            return 2
        if actual != expected:
            return 1
        signal.pidfd_send_signal(fd, signal.SIGKILL)
        return 0
    except ProcessLookupError:
        return 2
    except OSError:
        return 1
    finally:
        os.close(fd)


def check_support():
    if not hasattr(signal, "pidfd_send_signal") or not hasattr(os, "pidfd_open"):
        raise RuntimeError("CPU fixture requires Python 3.9+ with Linux pidfds")
    fd = os.pidfd_open(os.getpid())
    os.close(fd)


def run(ready, seconds):
    if not math.isfinite(seconds) or not 0.1 <= seconds <= 120:
        raise ValueError("CPU fixture lifetime must be between 0.1 and 120 seconds")
    # Arm the kernel timer before readiness; the default SIGALRM action exits
    # even if the shell dies or the Python loop stops handling Python signals.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
    signal.setitimer(signal.ITIMER_REAL, seconds)
    os.setsid()
    record = identity(os.getpid())
    if record is None:
        raise RuntimeError("could not verify CPU fixture identity")
    pending = ready + ".tmp"
    with open(os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        f.write(" ".join(map(str, record)) + "\n")
    os.replace(pending, ready)
    while True:
        pass


def main():
    check_support()
    command = sys.argv[1]
    if command == "check":
        return 0
    if command == "run":
        run(sys.argv[2], float(sys.argv[3]))
    elif command in ("stop", "alive"):
        if any(not value.isascii() or not value.isdecimal() for value in sys.argv[2:]):
            return 1
        expected = tuple(map(int, sys.argv[2:]))
        if command == "stop":
            return stop(expected)
        return 0 if len(expected) == 5 and identity(expected[0]) == expected else 1
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"CPU fixture: {error}", file=sys.stderr)
        sys.exit(1)
