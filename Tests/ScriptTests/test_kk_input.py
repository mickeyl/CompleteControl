import contextlib
import importlib.util
import io
from pathlib import Path
import socket
import threading
import unittest
from unittest import mock


SCRIPT_PATH = Path(__file__).parents[2] / "Scripts" / "kk-input.py"
SPEC = importlib.util.spec_from_file_location("kk_input", SCRIPT_PATH)
kk_input = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(kk_input)


class SocketPathTests(unittest.TestCase):
    def test_explicit_base_and_automation_paths_are_accepted(self):
        self.assertEqual(
            kk_input.automation_socket_candidates("/tmp/ccd.sock"),
            ["/tmp/ccd.sock.automation"],
        )
        self.assertEqual(
            kk_input.automation_socket_candidates("/tmp/ccd.sock.automation"),
            ["/tmp/ccd.sock.automation"],
        )

    def test_environment_socket_takes_precedence_over_defaults(self):
        candidates = kk_input.automation_socket_candidates(
            environ={"KK_DAEMON_SOCKET": "/tmp/configured.sock"}
        )
        self.assertEqual(candidates, ["/tmp/configured.sock.automation"])

    def test_resolution_selects_the_first_reachable_existing_socket(self):
        reachable = mock.Mock(side_effect=lambda path: path.startswith("/tmp/"))
        with mock.patch.object(kk_input.os.path, "exists", return_value=True):
            path = kk_input.resolve_automation_socket_path(environ={}, reachable=reachable)
        self.assertEqual(path, kk_input.SIMULATOR_SOCKET + ".automation")

    def test_history_uses_xdg_state_home(self):
        self.assertEqual(
            kk_input.default_history_path({"XDG_STATE_HOME": "/tmp/state"}),
            "/tmp/state/kk-input/history",
        )


class CompletionTests(unittest.TestCase):
    def setUp(self):
        self.completer = kk_input.CommandCompleter()

    def test_top_level_completion_includes_remote_and_repl_commands(self):
        choices = self.completer.choices("bu", 0)
        self.assertIn("button", choices)
        self.assertIn("reconnect", choices)

    def test_button_completion_contains_every_button_family(self):
        choices = self.completer.choices("button p", len("button "))
        self.assertIn("play", choices)
        self.assertIn("function8", choices)
        self.assertIn("strip25", choices)

    def test_completion_is_contextual(self):
        self.assertEqual(
            self.completer.choices("button play d", len("button play ")),
            ("down", "up"),
        )
        self.assertEqual(
            self.completer.choices("encodertouch 1 o", len("encodertouch 1 ")),
            ("on", "off"),
        )
        self.assertIn(
            "release",
            self.completer.choices("fourd r", len("fourd ")),
        )


class CommandStreamTests(unittest.TestCase):
    def test_blank_lines_and_comments_are_ignored(self):
        stream = io.StringIO("\n# setup\nbutton play down\n  button play up  \n")
        self.assertEqual(
            list(kk_input.iter_command_lines(stream)),
            ["button play down", "button play up"],
        )

    def test_flags_remain_order_independent_after_the_command(self):
        args = kk_input.make_parser().parse_args(
            ["encoder", "1", "-1", "--plain", "--socket", "/tmp/ccd.sock"]
        )
        self.assertEqual(args.command, ["encoder", "1", "-1"])
        self.assertTrue(args.plain)
        self.assertEqual(args.socket, "/tmp/ccd.sock")


class AutomationClientTests(unittest.TestCase):
    def test_client_preserves_buffered_responses_between_commands(self):
        client_socket, daemon_socket = socket.socketpair()
        client = kk_input.AutomationClient("unused")
        client._socket = client_socket
        received = []

        def serve():
            with daemon_socket:
                received.append(daemon_socket.recv(4096))
                daemon_socket.sendall(b"ok first\nok second\n")
                received.append(daemon_socket.recv(4096))

        server = threading.Thread(target=serve)
        server.start()
        try:
            self.assertEqual(client.send_line("button play down"), "ok first")
            self.assertEqual(client.send_line("button play up"), "ok second")
        finally:
            client.close()
            server.join(timeout=2)

        self.assertEqual(received, [b"button play down\n", b"button play up\n"])

    def test_batch_errors_go_to_stderr_and_set_a_command_exit_code(self):
        client = mock.Mock()
        client.send_line.return_value = "err parse"
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = kk_input.run_batch(client, ["button play"], plain=False)
        self.assertEqual(result, kk_input.EXIT_COMMAND)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("usage: button <name> down|up", stderr.getvalue())


class HelpTests(unittest.TestCase):
    def test_help_command_does_not_require_a_daemon(self):
        stdout = io.StringIO()
        with mock.patch.object(kk_input, "connect_client") as connect, contextlib.redirect_stdout(stdout):
            result = kk_input.main(["help", "button"])
        self.assertEqual(result, 0)
        connect.assert_not_called()
        self.assertIn("button <name> down|up", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
