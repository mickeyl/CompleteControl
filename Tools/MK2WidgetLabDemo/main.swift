import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

// A lab bench for the KontrolSurfaceKit2 widget layer. Everything on screen is composed
// exclusively from kit2 public APIs (BitmapLabel, MK2PixelFrame, MK2SurfaceScene2,
// PixelSnapshot) — no private drawing helpers, no legacy placeholder font. If a demo
// needs something the kit can't express yet, that capability goes into the kit first.
//
// Navigation (rework 2026-07-12): the top level is a
// filterable demo browser — 4-D selects and opens a demo, which then owns every
// control except SCENE, the reserved exit back to the browser.
@main
struct MK2WidgetLabDemo {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            printHelp()
            return
        }
        if arguments == ["--describe-json"] {
            do {
                FileHandle.standardOutput.write(try LabControlServer.describeData(pretty: true))
                print()
            } catch {
                fputs("MK2WidgetLabDemo: cannot encode demo catalogue: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        let controlEnabled = arguments == ["--control-stdin"]
        guard arguments.isEmpty || controlEnabled else {
            fputs("MK2WidgetLabDemo: unknown option. Run with --help.\n", stderr)
            exit(2)
        }

        let surface = MK2Surface2(options: .init(tickHz: 60))
        let lab = LabShell(surface: surface)
        if let snapshotDir = ProcessInfo.processInfo.environment["WIDGETLAB_SNAPSHOT_DIR"] {
            await lab.snapshotAll(to: snapshotDir)
            return
        }
        let runner = MK2SurfaceEventRunner(
            name: "surface",
            surface: surface,
            log: controlEnabled ? stderrLog : MK2SurfaceEventRunner.stdoutLog
        )
        await runner.run { _ in
            await lab.showBrowser()
            if controlEnabled {
                fputs("MK2WidgetLabDemo control mode — JSON Lines on stdin/stdout.\n", stderr)
                LabControlServer.start(lab: lab)
                return
            }
            let replEnabled = LineReader.hasInteractiveInput
            printBanner(replEnabled: replEnabled)
            if replEnabled {
                startREPL(lab)
            }
        }
    }

    private static let stderrLog: MK2SurfaceEventRunner.LogHandler = { message in
        fputs(message + "\n", stderr)
        fflush(stderr)
    }

    private static func printHelp() {
        print("""
        Exercise the KontrolSurfaceKit2 widget catalogue.

        Usage:
          MK2WidgetLabDemo
          MK2WidgetLabDemo --control-stdin
          MK2WidgetLabDemo --describe-json

        Options:
          -h, --help       Show this help.
          --control-stdin  Read JSON-Line control requests from stdin.
          --describe-json Print the demo catalogue as JSON and exit.

        Control mode is intended for kk-widgetlab-test. Hardware input still travels
        exclusively through ccd's opt-in automation socket.
        """)
    }

    private static func printBanner(replEnabled: Bool) {
        if replEnabled {
            print("MK2WidgetLabDemo — 4-D browses and opens demos, SCENE exits. Type 'help' or press Tab.")
        } else {
            print("MK2WidgetLabDemo — 4-D browses and opens demos, SCENE exits. REPL disabled: stdin is not a TTY.")
        }
    }

    private static func startREPL(_ lab: LabShell) {
        let reader = Thread {
            let editor = LineReader(completer: replComplete)
            while let line = editor.readLine(prompt: "› ") {
                let command = line.trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty else { continue }
                editor.addHistory(command)
                // Run the command to completion before reading the next line so its output
                // never interleaves with the live line editor.
                let done = DispatchSemaphore(value: 0)
                Task { await lab.command(command); done.signal() }
                done.wait()
            }
        }
        reader.stackSize = 1 << 20
        reader.name = "widgetlab-repl"
        reader.start()
    }
}
