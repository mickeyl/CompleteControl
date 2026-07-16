#!/usr/bin/env python3
"""Grab live screenshots of the Komplete Kontrol MK2 displays from a running ccd.

Talks the daemon's binary control protocol out-of-band: the connection never
registers, so the currently connected client keeps its session and the device
is never touched — the daemon answers from its display shadow.

Usage:
    kk-screenshot.py [--socket PATH] [--screen 0|1|both] [--out DIR]

Writes kk-screen-0.png, kk-screen-1.png, and a side-by-side kk-screens.png
(when both screens are grabbed), then prints the file paths.
"""

import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from kk_daemon import (  # noqa: E402
    CLIError,
    DaemonControlClient,
    resolve_socket_path,
    write_display_pngs,
)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", help="daemon control socket (default: KK_DAEMON_SOCKET, hardware, then simulator)")
    parser.add_argument("--screen", choices=["0", "1", "both"], default="both")
    parser.add_argument("--out", default="/tmp/kk-screens", help="output directory (default: /tmp/kk-screens)")
    args = parser.parse_args()

    try:
        socket_path = resolve_socket_path(args.socket)
        screens = [0, 1] if args.screen == "both" else [int(args.screen)]
        with DaemonControlClient(socket_path) as client:
            grabs = {screen: client.display_snapshot(screen) for screen in screens}
        written = write_display_pngs(args.out, "kk-screen", grabs, combined_prefix="kk-screens")
    except CLIError as error:
        print("error: %s" % error, file=sys.stderr)
        return error.exit_code

    print("daemon: %s" % socket_path)
    for path in written:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
