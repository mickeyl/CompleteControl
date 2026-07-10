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
import socket
import struct
import sys
import zlib

MAGIC = 0x00324B4B  # "KK2\0"
PROTOCOL_VERSION = 1
CHANNEL_CONTROL = 1
TYPE_VERSION = 1
TYPE_ACK = 6
TYPE_DISPLAY_SNAPSHOT = 7
HEADER = struct.Struct("<IBBHHHII")  # magic, version, channel, type, flags, pad, sequence, payload length

HARDWARE_SOCKET = "/var/run/kompletekontrol-libusb.sock"
SIMULATOR_SOCKET = "/tmp/kontrol-simulator-daemon.sock"


def resolve_socket_path(explicit):
    if explicit:
        return explicit
    env = os.environ.get("KK_DAEMON_SOCKET")
    candidates = [env] if env else [HARDWARE_SOCKET, SIMULATOR_SOCKET]
    for path in candidates:
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
        "error: no reachable daemon socket (tried: %s) — is ccd running?"
        % ", ".join(candidates)
    )


def encode_frame(frame_type, sequence, payload=b""):
    return (
        HEADER.pack(MAGIC, PROTOCOL_VERSION, CHANNEL_CONTROL, frame_type, 0, 0, sequence, len(payload))
        + payload
    )


def read_frame(sock):
    buffer = b""
    while len(buffer) < HEADER.size:
        chunk = sock.recv(65536)
        if not chunk:
            sys.exit("error: daemon closed the connection")
        buffer += chunk
    magic, version, _channel, frame_type, _flags, _pad, sequence, payload_len = HEADER.unpack(
        buffer[: HEADER.size]
    )
    if magic != MAGIC or version != PROTOCOL_VERSION:
        sys.exit("error: unexpected frame header from daemon")
    while len(buffer) < HEADER.size + payload_len:
        chunk = sock.recv(65536)
        if not chunk:
            sys.exit("error: daemon closed the connection mid-frame")
        buffer += chunk
    return frame_type, sequence, buffer[HEADER.size : HEADER.size + payload_len]


def parse_ack(payload):
    if len(payload) < 4:
        return None, ""
    (status,) = struct.unpack("<i", payload[:4])
    return status, payload[4:].decode("utf-8", "replace")


def grab_screen(sock, screen, sequence):
    sock.sendall(encode_frame(TYPE_DISPLAY_SNAPSHOT, sequence, bytes([screen])))
    frame_type, seq, payload = read_frame(sock)
    if frame_type == TYPE_ACK:
        status, message = parse_ack(payload)
        # A daemon that predates displaySnapshot cannot decode the frame type at
        # all and answers a sequence-0 "binary parse" ack.
        if message in ("unexpected type", "binary parse") or seq == 0:
            sys.exit(
                "error: the running daemon predates displaySnapshot support — "
                "rebuild ccd and restart the daemon"
            )
        sys.exit("error: daemon refused snapshot for screen %d: %s (%s)" % (screen, status, message))
    if seq != sequence:
        sys.exit("error: out-of-sequence response from daemon")
    if frame_type != TYPE_DISPLAY_SNAPSHOT or len(payload) < 6:
        sys.exit("error: malformed snapshot response")
    _screen, _reserved, width, height = struct.unpack("<BBHH", payload[:6])
    pixels = payload[6:]
    if len(pixels) != width * height * 2:
        sys.exit("error: snapshot pixel count mismatch")
    return width, height, pixels


def rgb565be_to_rgb888(pixels):
    rgb = bytearray(len(pixels) // 2 * 3)
    for i in range(0, len(pixels), 2):
        value = (pixels[i] << 8) | pixels[i + 1]
        r5 = (value >> 11) & 0x1F
        g6 = (value >> 5) & 0x3F
        b5 = value & 0x1F
        j = i // 2 * 3
        rgb[j] = (r5 << 3) | (r5 >> 2)
        rgb[j + 1] = (g6 << 2) | (g6 >> 4)
        rgb[j + 2] = (b5 << 3) | (b5 >> 2)
    return bytes(rgb)


def write_png(path, width, height, rgb):
    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    stride = width * 3
    raw = b"".join(b"\x00" + rgb[y * stride : (y + 1) * stride] for y in range(height))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", help="daemon control socket (default: KK_DAEMON_SOCKET, hardware, then simulator)")
    parser.add_argument("--screen", choices=["0", "1", "both"], default="both")
    parser.add_argument("--out", default="/tmp/kk-screens", help="output directory (default: /tmp/kk-screens)")
    args = parser.parse_args()

    socket_path = resolve_socket_path(args.socket)
    os.makedirs(args.out, exist_ok=True)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(3.0)
    sock.connect(socket_path)

    screens = [0, 1] if args.screen == "both" else [int(args.screen)]
    grabs = {}
    for sequence, screen in enumerate(screens, start=1):
        grabs[screen] = grab_screen(sock, screen, sequence)
    sock.close()

    written = []
    for screen, (width, height, pixels) in grabs.items():
        path = os.path.join(args.out, "kk-screen-%d.png" % screen)
        write_png(path, width, height, rgb565be_to_rgb888(pixels))
        written.append(path)

    if len(grabs) == 2:
        (w0, h0, p0), (w1, h1, p1) = grabs[0], grabs[1]
        if h0 == h1:
            left = rgb565be_to_rgb888(p0)
            right = rgb565be_to_rgb888(p1)
            combined = bytearray()
            for y in range(h0):
                combined += left[y * w0 * 3 : (y + 1) * w0 * 3]
                combined += right[y * w1 * 3 : (y + 1) * w1 * 3]
            path = os.path.join(args.out, "kk-screens.png")
            write_png(path, w0 + w1, h0, bytes(combined))
            written.append(path)

    print("daemon: %s" % socket_path)
    for path in written:
        print(path)


if __name__ == "__main__":
    main()
