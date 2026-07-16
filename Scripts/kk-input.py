#!/usr/bin/env python3
"""Interactive and scripted client for the ccd test-automation socket."""

import argparse
import difflib
import importlib
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from kk_daemon import (  # noqa: E402
    AutomationClient,
    CLIError,
    EXIT_COMMAND,
    EXIT_CONNECTION,
    EXIT_IO,
    EXIT_USAGE,
    HARDWARE_SOCKET,
    SIMULATOR_SOCKET,
    automation_path,
    automation_socket_candidates,
    resolve_automation_socket_path,
    socket_is_reachable,
)


VERSION = "1.0.0"

REMOTE_COMMAND_USAGE = {
    "button": "button <name> down|up",
    "encoder": "encoder <1-8> <delta>",
    "encodertouch": "encodertouch <1-8> on|off",
    "fourdwheel": "fourdwheel <delta>",
    "fourd": "fourd left|up|down|right|click|touch|release",
    "note": "note <midiNote 0-127> <velocity 0-127> on|off",
    "midi": "midi <statusHex> <data1Hex> <data2Hex>",
    "strip": "strip <position 0-1024|release> [timeMs]",
}
REMOTE_COMMANDS = tuple(REMOTE_COMMAND_USAGE)
LOCAL_COMMANDS = ("help", "history", "status", "reconnect", "clear", "quit", "exit")

BUTTON_NAMES = (
    "mute",
    "solo",
    *(f"function{index}" for index in range(1, 9)),
    "jogleft",
    "jogup",
    "jogdown",
    "jogright",
    "shift",
    "scale",
    "arp",
    "scene",
    "undoredo",
    "quantize",
    "auto",
    "pattern",
    "presetup",
    "track",
    "loop",
    "metro",
    "tempo",
    "presetdown",
    "keymode",
    "play",
    "record",
    "stop",
    "pageleft",
    "pageright",
    "clear",
    "browser",
    "plugin",
    "mixer",
    "instance",
    "midi",
    "setup",
    "fixedvel",
    "octavedown",
    "octaveup",
    *(f"strip{index}" for index in range(1, 26)),
)

REPL_HELP = """\
Automation commands:
  button <name> down|up
  encoder <1-8> <delta>
  encodertouch <1-8> on|off
  fourdwheel <delta>
  fourd left|up|down|right|click|touch|release
  note <midiNote 0-127> <velocity 0-127> on|off
  midi <statusHex> <data1Hex> <data2Hex>
  strip <position 0-1024|release> [timeMs]

REPL commands:
  help [command]   Show this help or one command's syntax.
  history [count]  Show recent persistent command history.
  status           Show the active automation socket.
  reconnect        Discover and reconnect to the daemon.
  clear            Clear an interactive terminal.
  quit, exit       Leave the REPL. Ctrl-D does the same.

Use Tab for contextual completion and the arrow keys to browse history.
"""


def default_history_path(environ=None):
    environ = os.environ if environ is None else environ
    state_home = environ.get("XDG_STATE_HOME")
    if not state_home:
        home = environ.get("HOME") or os.path.expanduser("~")
        state_home = os.path.join(home, ".local", "state")
    return os.path.join(state_home, "kk-input", "history")


class CommandCompleter:
    def __init__(self, readline_module=None):
        self.readline = readline_module
        self._matches = []

    def choices(self, line_buffer, begin_index):
        words = line_buffer[:begin_index].split()
        position = len(words)
        if position == 0:
            return REMOTE_COMMANDS + LOCAL_COMMANDS

        command = words[0]
        if command == "button":
            return BUTTON_NAMES if position == 1 else ("down", "up") if position == 2 else ()
        if command in ("encoder", "encodertouch") and position == 1:
            return tuple(str(index) for index in range(1, 9))
        if command == "encodertouch" and position == 2:
            return ("on", "off")
        if command == "fourd" and position == 1:
            return ("left", "up", "down", "right", "click", "touch", "release")
        if command == "note" and position == 3:
            return ("on", "off")
        if command == "strip" and position == 1:
            return ("release",)
        if command == "help" and position == 1:
            return REMOTE_COMMANDS + LOCAL_COMMANDS
        return ()

    def complete(self, text, state):
        if state == 0:
            line_buffer = self.readline.get_line_buffer()
            begin_index = self.readline.get_begidx()
            self._matches = [
                choice + " " for choice in self.choices(line_buffer, begin_index) if choice.startswith(text)
            ]
        return self._matches[state] if state < len(self._matches) else None


class ReadlineSession:
    def __init__(self, history_path, history_size=1000, history_enabled=True):
        try:
            self.readline = importlib.import_module("readline")
        except ImportError as error:
            raise CLIError(
                "Interactive mode requires Python's readline module. Install a Python build "
                "with GNU readline or libedit support.",
                EXIT_IO,
            ) from error
        self.history_path = os.path.expanduser(history_path)
        self.history_size = history_size
        self.history_enabled = history_enabled
        self.completer = CommandCompleter(self.readline)

    def start(self):
        backend = getattr(self.readline, "backend", "")
        if backend == "editline" or "libedit" in (self.readline.__doc__ or "").lower():
            self.readline.parse_and_bind("bind ^I rl_complete")
        else:
            self.readline.parse_and_bind("tab: complete")
        self.readline.set_completer_delims(" \t\n")
        self.readline.set_completer(self.completer.complete)
        self.readline.set_history_length(self.history_size)
        if self.history_enabled:
            try:
                self.readline.read_history_file(self.history_path)
            except FileNotFoundError:
                pass
            except OSError as error:
                print("warning: can't read history %s: %s" % (self.history_path, error), file=sys.stderr)

    def save(self):
        if not self.history_enabled:
            return
        try:
            parent = os.path.dirname(self.history_path) or "."
            os.makedirs(parent, mode=0o700, exist_ok=True)
            self.readline.set_history_length(self.history_size)
            self.readline.write_history_file(self.history_path)
            os.chmod(self.history_path, 0o600)
        except OSError as error:
            print("warning: can't save history %s: %s" % (self.history_path, error), file=sys.stderr)

    def recent_history(self, count=20):
        length = self.readline.get_current_history_length()
        first = max(1, length - count + 1)
        return [(index, self.readline.get_history_item(index)) for index in range(first, length + 1)]


def iter_command_lines(stream):
    for raw in stream:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        yield line


def read_script_lines(path):
    if path == "-":
        return list(iter_command_lines(sys.stdin))
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return list(iter_command_lines(handle))
    except OSError as error:
        raise CLIError("Can't read script %s: %s" % (path, error.strerror or error), EXIT_IO) from error


def connect_client(explicit_path, timeout):
    path = resolve_automation_socket_path(explicit_path)
    client = AutomationClient(path, timeout)
    client.connect()
    return client


def command_error_message(line, response):
    command = line.split(maxsplit=1)[0] if line.split() else ""
    message = "%s -> %s" % (line, response)
    if response == "err parse" and command in REMOTE_COMMAND_USAGE:
        message += "\nusage: %s" % REMOTE_COMMAND_USAGE[command]
    elif response.startswith("err unknown command"):
        matches = difflib.get_close_matches(command, REMOTE_COMMANDS, n=1)
        if matches:
            message += "\nDid you mean '%s'?" % matches[0]
    return message


def run_batch(client, lines, plain=False):
    exit_code = 0
    for line in lines:
        try:
            response = client.send_line(line)
        except CLIError as error:
            print("error: %s" % error, file=sys.stderr)
            return error.exit_code
        if response.startswith("err"):
            print(response if plain else command_error_message(line, response), file=sys.stderr)
            exit_code = EXIT_COMMAND
        else:
            print(response if plain else "%s -> %s" % (line, response))
    return exit_code


def print_command_help(command=None):
    if command in REMOTE_COMMAND_USAGE:
        print("Usage: %s" % REMOTE_COMMAND_USAGE[command])
    elif command in LOCAL_COMMANDS:
        local_usage = {
            "help": "help [command]",
            "history": "history [count]",
            "status": "status",
            "reconnect": "reconnect",
            "clear": "clear",
            "quit": "quit",
            "exit": "exit",
        }
        print("Usage: %s" % local_usage[command])
    else:
        print(REPL_HELP, end="")


def run_repl(client, args):
    readline_session = ReadlineSession(args.history_file, args.history_size, not args.no_history)
    readline_session.start()
    if not args.quiet:
        print("Connected to %s" % client.path, file=sys.stderr)
        print("Tab completes commands; type 'help' for help; Ctrl-D exits.", file=sys.stderr)

    try:
        while True:
            try:
                line = input("kk-input> ").strip()
            except EOFError:
                if not args.quiet:
                    print(file=sys.stderr)
                break
            except KeyboardInterrupt:
                print("^C", file=sys.stderr)
                continue

            if not line or line.startswith("#"):
                continue
            words = line.split()
            command = words[0]

            if command in ("quit", "exit"):
                break
            if command == "help":
                print_command_help(words[1] if len(words) > 1 else None)
                continue
            if command == "status":
                state = "connected" if client.connected else "disconnected"
                print("%s — %s" % (state, client.path))
                continue
            if command == "history":
                try:
                    count = int(words[1]) if len(words) > 1 else 20
                    if count < 1:
                        raise ValueError
                except (ValueError, IndexError):
                    print("error: usage: history [positive count]", file=sys.stderr)
                    continue
                for index, item in readline_session.recent_history(count):
                    print("%5d  %s" % (index, item))
                continue
            if command == "clear":
                if sys.stderr.isatty() and os.environ.get("TERM") != "dumb":
                    print("\033[2J\033[H", end="", file=sys.stderr)
                else:
                    print(file=sys.stderr)
                continue
            if command == "reconnect":
                try:
                    replacement = connect_client(args.socket, args.timeout)
                except CLIError as error:
                    print("error: %s" % error, file=sys.stderr)
                else:
                    client.close()
                    client = replacement
                    print("Connected to %s" % client.path, file=sys.stderr)
                continue

            try:
                response = client.send_line(line)
            except KeyboardInterrupt:
                client.close()
                print(
                    "\nInterrupted while waiting for the daemon. The command may have been delivered; "
                    "run 'reconnect' before continuing.",
                    file=sys.stderr,
                )
                continue
            except CLIError as error:
                print("error: %s" % error, file=sys.stderr)
                continue

            if response.startswith("err"):
                print(command_error_message(line, response), file=sys.stderr)
            else:
                print(response)
    finally:
        readline_session.save()
        client.close()
    return 0


def make_parser():
    parser = argparse.ArgumentParser(
        description="""\
Inject synthetic Komplete Kontrol MK2 input through ccd's opt-in automation socket.

Examples:
  kk-input.py                         Open the interactive REPL
  kk-input.py button play down       Send one command
  kk-input.py --script scenario.txt  Send commands from a file
  printf 'button play down\\n' | kk-input.py
""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Socket selection:
  --socket, then KK_DAEMON_SOCKET, then the hardware and simulator defaults.
  The daemon must have been started with CCD_ENABLE_AUTOMATION=1.

Use `kk-input.py help <command>` for command syntax.
""",
    )
    parser.add_argument(
        "--socket",
        metavar="PATH",
        help="daemon base or automation socket path",
    )
    parser.add_argument(
        "--script",
        metavar="PATH",
        help="read commands from PATH; use - for stdin",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=3.0,
        metavar="SECONDS",
        help="socket timeout (default: 3)",
    )
    parser.add_argument(
        "--history-file",
        default=default_history_path(),
        metavar="PATH",
        help="REPL history file (default: %(default)s)",
    )
    parser.add_argument(
        "--history-size",
        type=int,
        default=1000,
        metavar="COUNT",
        help="maximum saved REPL entries (default: 1000)",
    )
    parser.add_argument("--no-history", action="store_true", help="do not load or save REPL history")
    parser.add_argument("--plain", action="store_true", help="print only daemon responses in batch mode")
    parser.add_argument("-q", "--quiet", action="store_true", help="suppress the REPL connection banner")
    parser.add_argument("--version", action="version", version="kk-input %s" % VERSION)
    parser.add_argument("command", nargs="*", help="one automation command and its arguments")
    return parser


def main(argv=None):
    parser = make_parser()
    args = parser.parse_args(argv)
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    if args.history_size <= 0:
        parser.error("--history-size must be greater than zero")
    if args.script and args.command:
        parser.error("--script cannot be combined with a command")
    if args.command and args.command[0] == "help":
        if len(args.command) == 1:
            parser.print_help()
            return 0
        command = args.command[1]
        if command not in REMOTE_COMMANDS + LOCAL_COMMANDS:
            parser.error("unknown command for help: %s" % command)
        print_command_help(command)
        return 0

    if args.script:
        try:
            lines = read_script_lines(args.script)
        except CLIError as error:
            print("error: %s" % error, file=sys.stderr)
            return error.exit_code
        interactive = False
    elif args.command:
        lines = [" ".join(args.command)]
        interactive = False
    elif sys.stdin.isatty():
        lines = None
        interactive = True
    else:
        lines = list(iter_command_lines(sys.stdin))
        interactive = False

    if not interactive and not lines:
        return 0

    try:
        client = connect_client(args.socket, args.timeout)
    except CLIError as error:
        print("error: %s" % error, file=sys.stderr)
        return error.exit_code

    if interactive:
        try:
            return run_repl(client, args)
        except CLIError as error:
            client.close()
            print("error: %s" % error, file=sys.stderr)
            return error.exit_code
    try:
        return run_batch(client, lines, args.plain)
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
