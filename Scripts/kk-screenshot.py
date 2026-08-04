#!/usr/bin/env python3
"""Grab live screenshots of KONTROL MK2 and MASCHINE MK3 displays from running ccd daemons.

Talks the daemon's binary control protocol out-of-band: the connection never
registers, so the currently connected client keeps its session and the device
is never touched — the daemon answers from its display shadow.

Usage:
    kk-screenshot.py [--device kontrol|maschine|all] [--socket PATH] [--screen 0|1|both] [--out DIR]

Without --device or --socket the historical single-daemon resolution applies
(KK_DAEMON_SOCKET, hardware socket, simulator socket) and the output keeps its
legacy names (kk-screen-0.png, kk-screen-1.png, kk-screens.png).

--device selects a product-bound daemon: kontrol (aliases kk, mk2) uses the
same historical resolution, maschine (alias mk3) uses exactly
/var/run/kompletekontrol-maschine.sock. Files are then prefixed with the
device name (kontrol-0.png, kontrol.png, ...). --device all captures every
reachable device, reports offline ones, and — when both screens are grabbed —
additionally writes a labeled kk-fleet.png contact sheet (KONTROL row above
MASCHINE row).
"""

import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from kk_daemon import (  # noqa: E402
    CLIError,
    DEVICE_ORDER,
    DaemonControlClient,
    EXIT_CONNECTION,
    device_socket_candidates,
    normalize_device,
    resolve_device_socket,
    resolve_socket_path,
    write_display_pngs,
    write_fleet_png,
)


def capture(socket_path, screens):
    with DaemonControlClient(socket_path) as client:
        return {screen: client.display_snapshot(screen) for screen in screens}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--device",
        help="kontrol|kk|mk2, maschine|mk3, or all — capture through the product-bound daemon(s)",
    )
    parser.add_argument("--socket", help="explicit daemon control socket (mutually exclusive with --device)")
    parser.add_argument("--screen", choices=["0", "1", "both"], default="both")
    parser.add_argument("--out", default="/tmp/kk-screens", help="output directory (default: /tmp/kk-screens)")
    args = parser.parse_args()

    if args.device and args.socket:
        parser.error("--device and --socket are mutually exclusive")

    screens = [0, 1] if args.screen == "both" else [int(args.screen)]
    written = []
    exit_code = 0
    try:
        if not args.device:
            socket_path = resolve_socket_path(args.socket)
            grabs = capture(socket_path, screens)
            print("daemon: %s" % socket_path)
            written = write_display_pngs(args.out, "kk-screen", grabs, combined_prefix="kk-screens")
        else:
            device = normalize_device(args.device)
            devices = DEVICE_ORDER if device == "all" else [device]
            fleet_rows = []
            captured_any = False
            for label in devices:
                socket_path = resolve_device_socket(label)
                if socket_path is None:
                    candidates = ", ".join(path for path in device_socket_candidates(label) if path)
                    if device == "all":
                        print("%s: offline (no reachable socket: %s)" % (label, candidates))
                        continue
                    raise CLIError(
                        "%s daemon is not reachable (tried: %s)." % (label.upper(), candidates),
                        EXIT_CONNECTION,
                    )
                grabs = capture(socket_path, screens)
                captured_any = True
                print("%s daemon: %s" % (label, socket_path))
                written += write_display_pngs(args.out, label, grabs, combined_prefix=label)
                if set(grabs) == {0, 1}:
                    fleet_rows.append((label, grabs))
            if device == "all" and not captured_any:
                raise CLIError("No device daemon is reachable.", EXIT_CONNECTION)
            if device == "all" and len(fleet_rows) > 1:
                fleet_path = write_fleet_png(args.out, "kk-fleet", fleet_rows)
                if fleet_path:
                    written.append(fleet_path)
    except CLIError as error:
        print("error: %s" % error, file=sys.stderr)
        return error.exit_code

    for path in written:
        print(path)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
