import Foundation
import KompleteKontrol

guard let link = DaemonLink() else {
    fputs("MK2Calibrate: daemon socket unavailable — start ccd first (make daemon-debug).\n", stderr)
    exit(1)
}
link.start()

guard let version = link.request("version"), version.hasPrefix("ok") else {
    fputs("MK2Calibrate: daemon handshake failed.\n", stderr)
    exit(1)
}
guard let status = link.request("status"), status.contains("generation=mk2") else {
    fputs("MK2Calibrate: no MK2 session (status: \(link.request("status") ?? "-")).\n", stderr)
    exit(1)
}
print("connected: \(version)")
print("session: \(status)")

let inputs = FlowInputQueue()
inputs.attach(to: link)
let log = SessionLog()

// Re-establish our LED/guide/display state after a device power cycle; runs off the
// reader thread because request() must not be called from within a push callback.
link.onDeviceEvent = { [weak link] event in
    if event.hasPrefix("device disconnected") {
        print("\ndevice disconnected — waiting for it to come back …")
        return
    }
    guard event.hasPrefix("device reconnected") else { return }
    Thread.detachNewThread {
        guard let link else { return }
        CalibrationFlows.lightCommandKeys(link: link)
        link.reshowLastText()
        print("\ndevice reconnected — command keys and display restored; repeat the current step")
    }
}

link.buttonLabels = FlowInputQueue.buttonLabelSlots
CalibrationFlows.lightCommandKeys(link: link)
link.showText("MK2 CALIBRATE", "SELECT FLOW")
print("""

Command keys are the function buttons above the displays (lit + labelled):
""")
for key in FlowInputQueue.commandKeys {
    print("  \(key.button): \(key.label)")
}

func menu() {
    print("""

    MK2 calibration flows:
      1) LED <-> button binding sweep (+ RGB verify)
      2) Encoder capture
      3) Live event monitor
      4) 4-D encoder / byte-6 capture
      5) LED remainder check (arrows, shift, octave, strip 25)
      6) Display throughput benchmark
      q) quit (writes session log)
    """)
}

var pendingFlow = CommandLine.arguments.dropFirst().first

running: while true {
    let choice: String
    if let flow = pendingFlow {
        choice = flow
        pendingFlow = nil
    } else {
        menu()
        print("> ", terminator: "")
        // echo everything while idling at the menu, so the tool doubles as a health check
        waiting: while true {
            guard let item = inputs.next(timeout: 3600) else { continue }
            switch item {
                case let .console(line):
                    choice = line
                    break waiting
                case let .surface(_, events, _):
                    for event in events {
                        print("  \(event)")
                    }
                case let .midi(text):
                    print("  midi: \(text)")
            }
        }
    }
    switch choice {
        case "1", "leds":
            CalibrationFlows.ledBindingSweep(link: link, inputs: inputs, log: log)
        case "2", "encoders":
            CalibrationFlows.encoderCapture(link: link, inputs: inputs, log: log)
        case "3", "monitor":
            CalibrationFlows.liveMonitor(link: link, inputs: inputs, log: log)
        case "4", "fourd", "4d":
            CalibrationFlows.fourDCapture(link: link, inputs: inputs, log: log)
        case "5", "remainder", "leds2":
            CalibrationFlows.ledRemainderCheck(link: link, inputs: inputs, log: log)
        case "6", "bench", "benchmark":
            CalibrationFlows.displayBenchmark(link: link, log: log)
        case "q", "quit":
            break running
        default:
            continue
    }
}

CalibrationFlows.clearCommandKeys(link: link)
link.showText("CALIBRATION", "DONE")
log.writeFile()
