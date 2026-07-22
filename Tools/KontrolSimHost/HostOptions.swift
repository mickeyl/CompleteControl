import Foundation
import KompleteKontrol
import KontrolSimulatorCore

struct HostOptions {
    var kind: SimulatorDeviceKind = .kompleteKontrolS61MK2
    // Unique per invocation so parallel runs need no coordination; stable rigs
    // pass an explicit --instance.
    var instanceID = "pid\(getpid())"
    var ownsDaemon = false
    var automationEnabled = false
    var ccdPath: String?
    var firmwareOverride: UInt16?
    var nameOverride: String?

    static func parse(_ arguments: [String]) -> HostOptions {
        if arguments.contains("--help") || arguments.contains("-h") || arguments.contains("help") {
            print(help)
            exit(0)
        }
        if arguments.contains("--version") {
            print("kontrol-sim-host (CompleteControl)")
            exit(0)
        }
        var result = HostOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
                case "--device":
                    result.kind = parseKind(next(&index, arguments, for: argument))
                case _ where argument.hasPrefix("--device="):
                    result.kind = parseKind(String(argument.dropFirst("--device=".count)))
                case "--instance":
                    result.instanceID = next(&index, arguments, for: argument)
                case _ where argument.hasPrefix("--instance="):
                    result.instanceID = String(argument.dropFirst("--instance=".count))
                case "--own-daemon":
                    result.ownsDaemon = true
                case "--automation":
                    result.automationEnabled = true
                    result.ownsDaemon = true
                case "--ccd":
                    result.ccdPath = next(&index, arguments, for: argument)
                case _ where argument.hasPrefix("--ccd="):
                    result.ccdPath = String(argument.dropFirst("--ccd=".count))
                case "--firmware":
                    result.firmwareOverride = parseFirmware(next(&index, arguments, for: argument))
                case _ where argument.hasPrefix("--firmware="):
                    result.firmwareOverride = parseFirmware(String(argument.dropFirst("--firmware=".count)))
                case "--name":
                    result.nameOverride = next(&index, arguments, for: argument)
                case _ where argument.hasPrefix("--name="):
                    result.nameOverride = String(argument.dropFirst("--name=".count))
                default:
                    fail("unknown option '\(argument)'; run kontrol-sim-host --help")
            }
            index += 1
        }
        guard SimulatorInstancePaths.isValidInstanceID(result.instanceID) else {
            fail("invalid instance ID '\(result.instanceID)'; use 1-32 letters, digits, '-' or '_'")
        }
        return result
    }

    private static func next(_ index: inout Int, _ arguments: [String], for option: String) -> String {
        guard index + 1 < arguments.count else { fail("\(option) requires a value") }
        index += 1
        return arguments[index]
    }

    private static func parseKind(_ value: String) -> SimulatorDeviceKind {
        guard let kind = SimulatorDeviceKind(argument: value) else {
            fail("unknown device '\(value)'; use 'maschine-mk3' or 'komplete-kontrol-s61-mk2'")
        }
        return kind
    }

    private static func parseFirmware(_ value: String) -> UInt16 {
        guard let version = KKDeviceInfo.parseBCDVersion(value) else {
            fail("invalid firmware version '\(value)'; use major.minor.patch, e.g. 1.4.6")
        }
        return version
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("kontrol-sim-host: \(message)\n".utf8))
        exitHost(.usage)
    }

    private static let help = """
    kontrol-sim-host — deterministic headless virtual control surface

    Runs a virtual device without AppKit for end-to-end automation. All sockets,
    logs, and locks live in an isolated per-instance directory (/tmp/kksim-<id>/),
    so parallel runs never collide with each other, with the graphical simulator,
    or with a real hardware daemon.

    Examples:
      kontrol-sim-host --device maschine-mk3 --automation
      kontrol-sim-host --device komplete-kontrol-s61-mk2 --instance ci-42 --own-daemon

    Options:
      --device DEVICE     maschine-mk3 or komplete-kontrol-s61-mk2 (default)
      --instance ID       instance ID (letters, digits, '-', '_'; default pid<pid>)
      --own-daemon        start and own a user-level ccd bound to this instance
      --automation        enable the daemon test-automation socket (implies --own-daemon)
      --ccd PATH          ccd binary (default: next to this executable)
      --firmware X.Y.Z    firmware version reported to daemon clients
      --name NAME         device name reported to daemon clients
      -h, --help          show this help
      --version           show the version

    Control plane: JSON Lines on stdin/stdout. The host emits {"event":"ready",...}
    once the device socket is bound and — with --own-daemon — the daemon has
    connected. Commands: gesture, lamps, framebuffer, identity, status, quit.
    EOF on stdin performs a clean shutdown.

    Exit codes: 0 ok, 64 usage, 69 instance busy, 71 socket bind failure,
    72 daemon start failure, 73 owned daemon exited unexpectedly.
    """
}
