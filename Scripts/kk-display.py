#!/usr/bin/env python3
"""Push PNG images to the Komplete Kontrol MK2 displays through a running ccd.

The write-direction sibling of kk-screenshot.py: images are converted to
RGB565 BE and blitted over the daemon's display channel. Like the snapshot
path this never registers a session — the connected client keeps running and
its next repaint overwrites the pushed image. That is the point: this is a
bench preview, not a takeover.

Usage:
    kk-display.py image.png [image2.png] [--screen 0|1] [--device kontrol|maschine] [--socket PATH]

Accepted geometries:
    480x272          one screen (--screen selects it, default 0)
    960x272/961x272  dual-screen canvas, split at the seam (the 961px form
                     is the snapshot layout with its 1px separator column)
    two 480x272 PNGs screens 0 and 1 in argument order
"""

import argparse
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from kk_daemon import (  # noqa: E402
    DISPLAY_HEIGHT,
    DISPLAY_WIDTH,
    CLIError,
    DaemonControlClient,
    EXIT_CONNECTION,
    EXIT_USAGE,
    device_socket_candidates,
    normalize_device,
    resolve_device_socket,
    resolve_socket_path,
)


def load_image(path):
    try:
        from PIL import Image
    except ImportError as error:
        raise CLIError(
            "Pushing images needs Pillow (python3 -m pip install pillow).", EXIT_USAGE
        ) from error
    try:
        return Image.open(path).convert("RGB")
    except OSError as error:
        raise CLIError("Can't read image %s: %s" % (path, error), EXIT_USAGE) from error


def rgb565be(image):
    pixels = bytearray(image.width * image.height * 2)
    index = 0
    for r, g, b in image.getdata():
        value = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        pixels[index] = value >> 8
        pixels[index + 1] = value & 0xFF
        index += 2
    return bytes(pixels)


def frames_for(paths, screen_argument):
    """Map the given images to (screen, image) pairs per the accepted geometries."""
    images = [load_image(path) for path in paths]
    single = (DISPLAY_WIDTH, DISPLAY_HEIGHT)

    if len(images) == 2:
        for path, image in zip(paths, images):
            if image.size != single:
                raise CLIError(
                    "Two-image push needs two %dx%d PNGs; %s is %dx%d."
                    % (*single, path, *image.size),
                    EXIT_USAGE,
                )
        return [(0, images[0]), (1, images[1])]

    image = images[0]
    if image.size == single:
        return [(int(screen_argument or "0"), image)]
    if image.size in ((DISPLAY_WIDTH * 2, DISPLAY_HEIGHT), (DISPLAY_WIDTH * 2 + 1, DISPLAY_HEIGHT)):
        right_x = image.width - DISPLAY_WIDTH
        return [
            (0, image.crop((0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT))),
            (1, image.crop((right_x, 0, image.width, DISPLAY_HEIGHT))),
        ]
    raise CLIError(
        "Unsupported geometry %dx%d for %s — expected 480x272, 960x272 or 961x272."
        % (*image.size, paths[0]),
        EXIT_USAGE,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("images", nargs="+", metavar="image.png", help="one or two PNGs (see geometries above)")
    parser.add_argument("--screen", choices=["0", "1"], help="target screen for a single 480x272 image (default 0)")
    parser.add_argument(
        "--device",
        help="kontrol|kk|mk2 or maschine|mk3 — push through that product-bound daemon "
        "(a preview belongs on one deliberately chosen surface, so 'all' is refused)",
    )
    parser.add_argument("--socket", help="daemon control socket (default: KK_DAEMON_SOCKET, hardware, then simulator)")
    parser.add_argument(
        "--hold",
        type=int,
        default=120,
        metavar="SECONDS",
        help="keep the display connection open so the preview persists in NO CLIENT "
        "mode; the daemon repaints its idle surface when the last display "
        "connection closes (default 120, 0 = fire and forget)",
    )
    args = parser.parse_args()

    if len(args.images) > 2:
        print("error: pass one or two images", file=sys.stderr)
        return EXIT_USAGE

    if args.device and args.socket:
        print("error: --device and --socket are mutually exclusive", file=sys.stderr)
        return EXIT_USAGE

    try:
        if args.device:
            device = normalize_device(args.device)
            if device == "all":
                raise CLIError(
                    "Refusing to push a preview to every surface — pick one device.",
                    EXIT_USAGE,
                )
            socket_path = resolve_device_socket(device)
            if socket_path is None:
                candidates = ", ".join(path for path in device_socket_candidates(device) if path)
                raise CLIError(
                    "%s daemon is not reachable (tried: %s)." % (device.upper(), candidates),
                    EXIT_CONNECTION,
                )
        else:
            socket_path = resolve_socket_path(args.socket)
        frames = frames_for(args.images, args.screen)
        with DaemonControlClient(socket_path) as client:
            # The drain barrier only answers inside a measurement session.
            client.begin_display_measurements()
            try:
                for screen, image in frames:
                    client.display_blit(screen, rgb565be(image))
                metrics = client.display_barrier()
            finally:
                client.end_display_measurements()

            print("daemon: %s" % socket_path)
            for screen, _image in frames:
                print("screen %d updated" % screen)
            print(
                "drained: %(writes)d writes, %(bytes)d bytes, %(nanoseconds)d ns, encoding %(encoding)s"
                % metrics
            )
            # Closing the last display connection makes the daemon repaint its
            # idle surface, so the preview lives exactly as long as we stay
            # connected.
            if args.hold > 0:
                print("holding preview for %ds (Ctrl-C releases early)" % args.hold, flush=True)
                try:
                    time.sleep(args.hold)
                except KeyboardInterrupt:
                    pass
    except CLIError as error:
        print("error: %s" % error, file=sys.stderr)
        return error.exit_code
    return 0


if __name__ == "__main__":
    sys.exit(main())
