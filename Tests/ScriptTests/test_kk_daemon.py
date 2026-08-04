import socket
import struct
import threading
import unittest
from pathlib import Path
import sys


SCRIPT_DIR = Path(__file__).parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPT_DIR))
import kk_daemon


class SocketPathTests(unittest.TestCase):
    def test_automation_and_base_paths_round_trip(self):
        self.assertEqual(kk_daemon.automation_path("/tmp/test.sock"), "/tmp/test.sock.automation")
        self.assertEqual(
            kk_daemon.base_socket_path("/tmp/test.sock.automation"),
            "/tmp/test.sock",
        )

    def test_explicit_automation_path_resolves_to_base_control_socket(self):
        self.assertEqual(
            kk_daemon.socket_candidates("/tmp/test.sock.automation"),
            ["/tmp/test.sock"],
        )


class DeviceResolutionTests(unittest.TestCase):
    def test_device_aliases_normalize_and_unknown_tokens_fail(self):
        for token in ("kontrol", "KK", "mk2"):
            self.assertEqual(kk_daemon.normalize_device(token), "kontrol")
        for token in ("maschine", "MK3"):
            self.assertEqual(kk_daemon.normalize_device(token), "maschine")
        self.assertEqual(kk_daemon.normalize_device("all"), "all")
        with self.assertRaises(kk_daemon.CLIError):
            kk_daemon.normalize_device("maschine-studio")

    def test_kontrol_slot_keeps_historical_resolution(self):
        self.assertEqual(
            kk_daemon.device_socket_candidates("kontrol", environ={}),
            [kk_daemon.HARDWARE_SOCKET, kk_daemon.SIMULATOR_SOCKET],
        )
        self.assertEqual(
            kk_daemon.device_socket_candidates(
                "kontrol", environ={"KK_DAEMON_SOCKET": "/tmp/sim.sock"}
            ),
            ["/tmp/sim.sock"],
        )

    def test_maschine_slot_is_the_fixed_product_bound_socket_only(self):
        self.assertEqual(
            kk_daemon.device_socket_candidates(
                "maschine", environ={"KK_DAEMON_SOCKET": "/tmp/sim.sock"}
            ),
            [kk_daemon.MASCHINE_SOCKET],
        )

    def test_resolve_device_socket_returns_none_for_offline_devices(self):
        self.assertIsNone(
            kk_daemon.resolve_device_socket(
                "maschine",
                environ={},
                reachable=lambda path, timeout=0.5: False,
            )
        )


class BinaryClientTests(unittest.TestCase):
    def test_display_snapshot_parses_rgb565_payload(self):
        client_socket, daemon_socket = socket.socketpair()
        client = kk_daemon.DaemonControlClient("unused")
        client._socket = client_socket

        def serve():
            with daemon_socket:
                request = daemon_socket.recv(4096)
                sequence = kk_daemon.HEADER.unpack(request[: kk_daemon.HEADER.size])[6]
                payload = struct.pack("<BBHH", 0, 0, 2, 1) + b"\x12\x34\xab\xcd"
                daemon_socket.sendall(
                    kk_daemon.encode_frame(kk_daemon.TYPE_DISPLAY_SNAPSHOT, sequence, payload)
                )

        server = threading.Thread(target=serve)
        server.start()
        try:
            self.assertEqual(client.display_snapshot(0), (2, 1, b"\x12\x34\xab\xcd"))
        finally:
            client.close()
            server.join(timeout=2)

    def test_display_barrier_uses_display_channel_and_parses_metrics(self):
        client_socket, daemon_socket = socket.socketpair()
        client = kk_daemon.DaemonControlClient("unused")
        client._display_socket = client_socket

        def serve():
            with daemon_socket:
                request = daemon_socket.recv(4096)
                fields = kk_daemon.HEADER.unpack(request[: kk_daemon.HEADER.size])
                self.assertEqual(fields[2], kk_daemon.CHANNEL_DISPLAY)
                self.assertEqual(request[kk_daemon.HEADER.size :], b"\x01")
                message = b"display-drained encoding=adaptive writes=3 bytes=40 nanoseconds=50 failures=0"
                payload = struct.pack("<i", 0) + message
                daemon_socket.sendall(
                    kk_daemon.encode_frame(
                        kk_daemon.TYPE_ACK,
                        fields[6],
                        payload,
                        channel=kk_daemon.CHANNEL_DISPLAY,
                    )
                )

        server = threading.Thread(target=serve)
        server.start()
        try:
            self.assertEqual(
                client.begin_display_measurements(),
                {
                    "encoding": "adaptive",
                    "writes": 3,
                    "bytes": 40,
                    "nanoseconds": 50,
                    "failures": 0,
                },
            )
        finally:
            client.close()
            server.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
