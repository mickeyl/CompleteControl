#!/usr/bin/env python3
"""Inject synthetic Komplete Kontrol MK2 input into a running ccd for scripted testing.

Talks the daemon's opt-in automation socket (the daemon must have been started with
CCD_ENABLE_AUTOMATION set) — a plain line-based text REPL: one command per line, one
"ok"/"err ..." response per line. Works identically against a simulator-backed or a
hardware-backed daemon, so a script written against the simulator also drives real hardware.

Usage:
    kk-input.py button play down
    kk-input.py note 60 100 on
    kk-input.py --script scenario.txt   # one command per line; blank lines and '#' comments
                                         # are skipped; pacing between lines (if any) is the
                                         # caller's job — this tool sends lines back-to-back
    kk-input.py help

Commands: button <name> down|up, encoder <1-8> <delta>, encodertouch <1-8> on|off,
fourdwheel <delta>, fourd left|up|down|right|click|touch|release,
note <midiNote> <velocity> on|off, midi <statusHex> <data1> <data2>,
strip <position 0-1024|release> [timeMs], help
"""

import argparse
import os
import socket
import sys

HARDWARE_SOCKET = "/var/run/kompletekontrol-libusb.sock"
SIMULATOR_SOCKET = "/tmp/kontrol-simulator-daemon.sock"


def resolve_automation_socket_path(explicit):
    if explicit:
        return explicit
    env = os.environ.get("KK_DAEMON_SOCKET")
    candidates = [env] if env else [HARDWARE_SOCKET, SIMULATOR_SOCKET]
    tried = []
    for base in candidates:
        if not base:
            continue
        path = base + ".automation"
        tried.append(path)
        if not os.path.exists(path):
            continue
        try:
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(0.5)
            probe.connect(path)
            probe.close()
            return path
        except OSError:
            continue
    sys.exit(
        "error: no reachable automation socket (tried: %s) — is ccd running with "
        "CCD_ENABLE_AUTOMATION set?" % ", ".join(tried)
    )


def send_line(sock, line):
    sock.sendall((line + "\n").encode("utf-8"))
    buffer = b""
    while b"\n" not in buffer:
        chunk = sock.recv(4096)
        if not chunk:
            sys.exit("error: daemon closed the automation connection")
        buffer += chunk
    return buffer.split(b"\n", 1)[0].decode("utf-8", "replace")


def iter_script_lines(path):
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            yield line


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--socket", help="daemon automation socket (default: derived from KK_DAEMON_SOCKET, hardware, then simulator)")
    parser.add_argument("--script", help="file with one automation command per line")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="a single automation command, e.g. button play down")
    args = parser.parse_args()

    if not args.script and not args.command:
        parser.print_help()
        sys.exit(2)

    socket_path = resolve_automation_socket_path(args.socket)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(3.0)
    sock.connect(socket_path)

    exit_code = 0
    try:
        lines = list(iter_script_lines(args.script)) if args.script else [" ".join(args.command)]
        for line in lines:
            response = send_line(sock, line)
            print("%s -> %s" % (line, response))
            if response.startswith("err"):
                exit_code = 1
    finally:
        sock.close()

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
