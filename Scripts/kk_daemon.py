"""Shared clients and image helpers for CompleteControl daemon tooling."""

import os
import socket
import struct
import time
import zlib


MAGIC = 0x00324B4B  # "KK2\0"
PROTOCOL_VERSION = 1
CHANNEL_CONTROL = 1
CHANNEL_DISPLAY = 3
TYPE_DISPLAY_BLIT = 5
TYPE_ACK = 6
TYPE_DISPLAY_SNAPSHOT = 7
TYPE_DISPLAY_BARRIER = 9

DISPLAY_WIDTH = 480
DISPLAY_HEIGHT = 272
HEADER = struct.Struct("<IBBHHHII")

HARDWARE_SOCKET = "/var/run/kompletekontrol-libusb.sock"
MASCHINE_SOCKET = "/var/run/kompletekontrol-maschine.sock"
SIMULATOR_SOCKET = "/tmp/kontrol-simulator-daemon.sock"

# Canonical device tokens for the product-bound daemon pair, plus their
# accepted CLI spellings. "all" fans a capture out to every reachable device.
DEVICE_ALIASES = {
    "kontrol": "kontrol",
    "kk": "kontrol",
    "mk2": "kontrol",
    "maschine": "maschine",
    "mk3": "maschine",
    "all": "all",
}
DEVICE_ORDER = ["kontrol", "maschine"]

EXIT_COMMAND = 1
EXIT_USAGE = 2
EXIT_CONNECTION = 3
EXIT_IO = 4


class CLIError(Exception):
    def __init__(self, message, exit_code=EXIT_IO):
        super().__init__(message)
        self.exit_code = exit_code


def automation_path(base_path):
    return base_path if base_path.endswith(".automation") else base_path + ".automation"


def base_socket_path(path):
    return path[: -len(".automation")] if path.endswith(".automation") else path


def socket_candidates(explicit=None, environ=None):
    if explicit:
        return [base_socket_path(explicit)]
    environ = os.environ if environ is None else environ
    configured = environ.get("KK_DAEMON_SOCKET")
    return [configured] if configured else [HARDWARE_SOCKET, SIMULATOR_SOCKET]


def automation_socket_candidates(explicit=None, environ=None):
    return [automation_path(path) for path in socket_candidates(explicit, environ) if path]


def socket_is_reachable(path, timeout=0.5):
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(timeout)
    try:
        probe.connect(path)
        return True
    except OSError:
        return False
    finally:
        probe.close()


def resolve_socket_path(explicit=None, environ=None, reachable=socket_is_reachable):
    candidates = socket_candidates(explicit, environ)
    if explicit:
        return candidates[0]
    for path in candidates:
        if path and os.path.exists(path) and reachable(path):
            return path
    raise CLIError(
        "No reachable daemon socket. Tried: %s\nStart ccd, or pass --socket <path>."
        % ", ".join(path for path in candidates if path),
        EXIT_CONNECTION,
    )


def normalize_device(token):
    device = DEVICE_ALIASES.get((token or "").lower())
    if device is None:
        raise CLIError(
            "Unknown device %r. Use kontrol|kk|mk2, maschine|mk3, or all." % token,
            EXIT_USAGE,
        )
    return device


def device_socket_candidates(device, environ=None):
    """Socket candidates for one canonical device token.

    The KONTROL slot keeps the historical resolution (KK_DAEMON_SOCKET
    override, then hardware socket, then simulator). The MASCHINE slot is the
    fixed product-bound daemon socket only — composite setups address exact
    endpoints, never discovery.
    """
    environ = os.environ if environ is None else environ
    if device == "kontrol":
        configured = environ.get("KK_DAEMON_SOCKET")
        return [configured] if configured else [HARDWARE_SOCKET, SIMULATOR_SOCKET]
    if device == "maschine":
        return [MASCHINE_SOCKET]
    raise CLIError("Unknown device %r." % device, EXIT_USAGE)


def resolve_device_socket(device, environ=None, reachable=socket_is_reachable):
    """The reachable socket for one device, or None when it is offline."""
    for path in device_socket_candidates(device, environ):
        if path and os.path.exists(path) and reachable(path):
            return path
    return None


def resolve_automation_socket_path(explicit=None, environ=None, reachable=socket_is_reachable):
    candidates = automation_socket_candidates(explicit, environ)
    if explicit:
        return candidates[0]
    for path in candidates:
        if os.path.exists(path) and reachable(path):
            return path
    raise CLIError(
        "No reachable automation socket. Tried: %s\n"
        "Start ccd with CCD_ENABLE_AUTOMATION=1, or pass --socket <path>."
        % ", ".join(candidates),
        EXIT_CONNECTION,
    )


class AutomationClient:
    def __init__(self, path, timeout=3.0):
        self.path = path
        self.timeout = timeout
        self._socket = None
        self._buffer = b""

    @property
    def connected(self):
        return self._socket is not None

    def connect(self):
        self.close()
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout)
        try:
            connection.connect(self.path)
        except OSError as error:
            connection.close()
            raise CLIError(
                "Can't connect to %s: %s\n"
                "Check that ccd is running with CCD_ENABLE_AUTOMATION=1."
                % (self.path, error.strerror or error),
                EXIT_CONNECTION,
            ) from error
        self._socket = connection
        self._buffer = b""

    def close(self):
        if self._socket is not None:
            self._socket.close()
        self._socket = None
        self._buffer = b""

    def send_line(self, line):
        if self._socket is None:
            raise CLIError("Not connected. Run 'reconnect' and try again.", EXIT_CONNECTION)
        try:
            self._socket.sendall((line + "\n").encode("utf-8"))
            while b"\n" not in self._buffer:
                chunk = self._socket.recv(4096)
                if not chunk:
                    self.close()
                    raise CLIError(
                        "The daemon closed the automation connection. Run 'reconnect' and try again.",
                        EXIT_CONNECTION,
                    )
                self._buffer += chunk
        except socket.timeout as error:
            self.close()
            raise CLIError(
                "Timed out waiting for the daemon. The command may already have been delivered; "
                "run 'reconnect' before continuing.",
                EXIT_CONNECTION,
            ) from error
        except OSError as error:
            self.close()
            raise CLIError(
                "Automation connection failed: %s. Run 'reconnect' and try again."
                % (error.strerror or error),
                EXIT_CONNECTION,
            ) from error

        response, self._buffer = self._buffer.split(b"\n", 1)
        return response.decode("utf-8", "replace")

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, _error_type, _error, _traceback):
        self.close()


def encode_frame(frame_type, sequence, payload=b"", channel=CHANNEL_CONTROL):
    return HEADER.pack(
        MAGIC,
        PROTOCOL_VERSION,
        channel,
        frame_type,
        0,
        0,
        sequence,
        len(payload),
    ) + payload


def read_frame(sock):
    buffer = b""
    while len(buffer) < HEADER.size:
        chunk = sock.recv(65536)
        if not chunk:
            raise CLIError("The daemon closed the control connection.", EXIT_CONNECTION)
        buffer += chunk
    magic, version, _channel, frame_type, _flags, _pad, sequence, payload_len = HEADER.unpack(
        buffer[: HEADER.size]
    )
    if magic != MAGIC or version != PROTOCOL_VERSION:
        raise CLIError("Unexpected binary frame header from the daemon.", EXIT_CONNECTION)
    while len(buffer) < HEADER.size + payload_len:
        chunk = sock.recv(65536)
        if not chunk:
            raise CLIError("The daemon closed the control connection mid-frame.", EXIT_CONNECTION)
        buffer += chunk
    return frame_type, sequence, buffer[HEADER.size : HEADER.size + payload_len]


def parse_ack(payload):
    if len(payload) < 4:
        return None, ""
    (status,) = struct.unpack("<i", payload[:4])
    return status, payload[4:].decode("utf-8", "replace")


class DaemonControlClient:
    def __init__(self, path, timeout=3.0):
        self.path = base_socket_path(path)
        self.timeout = timeout
        self._socket = None
        self._sequence = 0
        self._display_socket = None
        self._display_sequence = 0

    def connect(self):
        self.close()
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout)
        try:
            connection.connect(self.path)
        except OSError as error:
            connection.close()
            raise CLIError(
                "Can't connect to daemon control socket %s: %s"
                % (self.path, error.strerror or error),
                EXIT_CONNECTION,
            ) from error
        self._socket = connection

    def close(self):
        if self._socket is not None:
            self._socket.close()
        if self._display_socket is not None:
            self._display_socket.close()
        self._socket = None
        self._display_socket = None

    def _request(self, frame_type, payload=b""):
        if self._socket is None:
            raise CLIError("Daemon control client is not connected.", EXIT_CONNECTION)
        self._sequence += 1
        sequence = self._sequence
        try:
            self._socket.sendall(encode_frame(frame_type, sequence, payload))
            response_type, response_sequence, response_payload = read_frame(self._socket)
        except (OSError, socket.timeout) as error:
            self.close()
            raise CLIError("Daemon control request failed: %s" % error, EXIT_CONNECTION) from error
        if response_sequence != sequence:
            raise CLIError("Out-of-sequence response from the daemon.", EXIT_CONNECTION)
        if response_type == TYPE_ACK:
            status, message = parse_ack(response_payload)
            if status != 0:
                raise CLIError("Daemon refused request: %s (%s)" % (message, status), EXIT_COMMAND)
        return response_type, response_payload

    def display_snapshot(self, screen):
        response_type, payload = self._request(TYPE_DISPLAY_SNAPSHOT, bytes([screen]))
        if response_type != TYPE_DISPLAY_SNAPSHOT or len(payload) < 6:
            raise CLIError("Malformed display snapshot response.", EXIT_CONNECTION)
        response_screen, _reserved, width, height = struct.unpack("<BBHH", payload[:6])
        pixels = payload[6:]
        if response_screen != screen or len(pixels) != width * height * 2:
            raise CLIError("Display snapshot pixel count mismatch.", EXIT_CONNECTION)
        return width, height, pixels

    def _display_request(self, frame_type, payload, label):
        if self._display_socket is None:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(self.timeout)
            try:
                connection.connect(self.path + ".display")
            except OSError as error:
                connection.close()
                raise CLIError(
                    "Can't connect to daemon display socket %s: %s"
                    % (self.path + ".display", error.strerror or error),
                    EXIT_CONNECTION,
                ) from error
            self._display_socket = connection
        self._display_sequence += 1
        sequence = self._display_sequence
        try:
            self._display_socket.sendall(
                encode_frame(frame_type, sequence, payload=payload, channel=CHANNEL_DISPLAY)
            )
            response_type, response_sequence, response_payload = read_frame(self._display_socket)
        except (OSError, socket.timeout) as error:
            self._display_socket.close()
            self._display_socket = None
            raise CLIError("Daemon %s failed: %s" % (label, error), EXIT_CONNECTION) from error
        if response_sequence != sequence:
            raise CLIError("Out-of-sequence %s response." % label, EXIT_CONNECTION)
        if response_type != TYPE_ACK:
            raise CLIError("Malformed %s response." % label, EXIT_CONNECTION)
        return parse_ack(response_payload)

    def display_blit(self, screen, pixels_rgb565be, x=0, y=0,
                     width=DISPLAY_WIDTH, height=DISPLAY_HEIGHT, timeout_ms=1000):
        """Queue one blit; like every display client the daemon coalesces per
        screen and a later frame from the registered client simply overwrites
        it — this is a preview, not a takeover."""
        expected = width * height * 2
        if len(pixels_rgb565be) != expected:
            raise CLIError(
                "Display blit needs %d RGB565 bytes for %dx%d, got %d."
                % (expected, width, height, len(pixels_rgb565be)),
                EXIT_USAGE,
            )
        payload = struct.pack("<BBHHHHI", screen, 0, x, y, width, height, timeout_ms)
        status, message = self._display_request(
            TYPE_DISPLAY_BLIT, payload + bytes(pixels_rgb565be), "display blit"
        )
        if status != 0:
            raise CLIError("Display blit refused: %s (%s)" % (message, status), EXIT_COMMAND)

    def _display_barrier(self, action=None, deadline=None):
        deadline = time.monotonic() + self.timeout if deadline is None else deadline
        status, message = self._display_request(
            TYPE_DISPLAY_BARRIER,
            b"" if action is None else bytes([action]),
            "display barrier",
        )
        if status == -11 and time.monotonic() < deadline:
            time.sleep(0.01)
            return self._display_barrier(action=action, deadline=deadline)
        if status != 0:
            raise CLIError("Display barrier failed: %s (%s)" % (message, status), EXIT_COMMAND)
        fields = {}
        for token in message.split():
            key, separator, value = token.partition("=")
            if separator:
                fields[key] = value
        required = ("encoding", "writes", "bytes", "nanoseconds", "failures")
        if not message.startswith("display-drained ") or any(key not in fields for key in required):
            raise CLIError("Malformed display barrier metrics: %s" % message, EXIT_CONNECTION)
        return {
            "encoding": fields["encoding"],
            "writes": int(fields["writes"]),
            "bytes": int(fields["bytes"]),
            "nanoseconds": int(fields["nanoseconds"]),
            "failures": int(fields["failures"]),
        }

    def begin_display_measurements(self):
        return self._display_barrier(action=1)

    def display_barrier(self):
        return self._display_barrier()

    def end_display_measurements(self):
        return self._display_barrier(action=0)

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, _error_type, _error, _traceback):
        self.close()


def rgb565be_to_rgb888(pixels):
    rgb = bytearray(len(pixels) // 2 * 3)
    for index in range(0, len(pixels), 2):
        value = (pixels[index] << 8) | pixels[index + 1]
        r5 = (value >> 11) & 0x1F
        g6 = (value >> 5) & 0x3F
        b5 = value & 0x1F
        output = index // 2 * 3
        rgb[output] = (r5 << 3) | (r5 >> 2)
        rgb[output + 1] = (g6 << 2) | (g6 >> 4)
        rgb[output + 2] = (b5 << 3) | (b5 >> 2)
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
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        handle.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        handle.write(chunk(b"IEND", b""))


# 5x7 uppercase bitmap glyphs (one int per row, 5 bits wide) — just enough to
# caption the fleet sheet without a Pillow dependency.
CAPTION_GLYPHS = {
    "A": (0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    "C": (0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E),
    "E": (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F),
    "H": (0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    "I": (0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E),
    "K": (0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11),
    "L": (0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F),
    "M": (0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11),
    "N": (0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11),
    "O": (0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
    "R": (0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11),
    "S": (0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E),
    "T": (0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04),
    " ": (0, 0, 0, 0, 0, 0, 0),
}

CAPTION_HEIGHT = 20
CAPTION_SCALE = 2
CAPTION_BACKGROUND = (24, 24, 24)
CAPTION_FOREGROUND = (220, 220, 220)


def caption_band(width, text):
    band = bytearray(width * CAPTION_HEIGHT * 3)
    for index in range(0, len(band), 3):
        band[index : index + 3] = bytes(CAPTION_BACKGROUND)
    glyph_height = 7 * CAPTION_SCALE
    top = (CAPTION_HEIGHT - glyph_height) // 2
    x = 8
    for character in text.upper():
        glyph = CAPTION_GLYPHS.get(character, CAPTION_GLYPHS[" "])
        for row, bits in enumerate(glyph):
            for column in range(5):
                if not bits & (0x10 >> column):
                    continue
                for dy in range(CAPTION_SCALE):
                    for dx in range(CAPTION_SCALE):
                        px = x + column * CAPTION_SCALE + dx
                        py = top + row * CAPTION_SCALE + dy
                        if px >= width:
                            continue
                        offset = (py * width + px) * 3
                        band[offset : offset + 3] = bytes(CAPTION_FOREGROUND)
        x += 6 * CAPTION_SCALE
    return bytes(band)


def write_fleet_png(directory, name, device_rows):
    """One labeled contact sheet: per device a caption band plus its
    side-by-side display pair. Returns the path, or None when the rows do not
    share a width (unexpected mixed geometries)."""
    rows = []
    sheet_width = None
    for label, screens in device_rows:
        width0, height0, pixels0 = screens[0]
        width1, height1, pixels1 = screens[1]
        if height0 != height1:
            return None
        row_width = width0 + width1
        if sheet_width is None:
            sheet_width = row_width
        elif sheet_width != row_width:
            return None
        left = rgb565be_to_rgb888(pixels0)
        right = rgb565be_to_rgb888(pixels1)
        body = bytearray()
        for y in range(height0):
            body += left[y * width0 * 3 : (y + 1) * width0 * 3]
            body += right[y * width1 * 3 : (y + 1) * width1 * 3]
        rows.append(caption_band(row_width, label) + bytes(body))
    if not rows or sheet_width is None:
        return None
    sheet = b"".join(rows)
    height = len(sheet) // (sheet_width * 3)
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "%s.png" % name)
    write_png(path, sheet_width, height, sheet)
    return path


def write_display_pngs(directory, prefix, screens, combined_prefix=None):
    os.makedirs(directory, exist_ok=True)
    written = []
    converted = {}
    for screen, (width, height, pixels) in sorted(screens.items()):
        rgb = rgb565be_to_rgb888(pixels)
        converted[screen] = (width, height, rgb)
        path = os.path.join(directory, "%s-%d.png" % (prefix, screen))
        write_png(path, width, height, rgb)
        written.append(path)
    if set(converted) == {0, 1}:
        w0, h0, left = converted[0]
        w1, h1, right = converted[1]
        if h0 == h1:
            combined = bytearray()
            for y in range(h0):
                combined += left[y * w0 * 3 : (y + 1) * w0 * 3]
                combined += right[y * w1 * 3 : (y + 1) * w1 * 3]
            path = os.path.join(directory, "%s.png" % (combined_prefix or prefix))
            write_png(path, w0 + w1, h0, bytes(combined))
            written.append(path)
    return written
