import Foundation
import CoreMIDI
import IOKit
import IOKit.hid
import KompleteKontrol
import KontrolUSB

// Thin REPL around the reusable KompleteKontrol library. Keep protocol and
// device ownership logic in Sources/KompleteKontrol so SidStudio can use it.

nonisolated(unsafe) var midiClient = MIDIClientRef()
nonisolated(unsafe) var midiInputPort = MIDIPortRef()

// Latency benchmark state
nonisolated(unsafe) var benchmarkMode = false
nonisolated(unsafe) var benchmarkSamples: [UInt64] = []
nonisolated(unsafe) var benchmarkSampleCount = 0
nonisolated(unsafe) var benchmarkTargetSamples = 100
nonisolated(unsafe) var benchmarkSurfaceSampleCount = 0
nonisolated(unsafe) var benchmarkMIDISampleCount = 0

func midiStatus(_ status: UInt8) -> String {
    let channel = Int(status & 0x0f) + 1
    switch status & 0xf0 {
        case 0x80: return "noteOff ch\(channel)"
        case 0x90: return "noteOn ch\(channel)"
        case 0xa0: return "polyAT ch\(channel)"
        case 0xb0: return "cc ch\(channel)"
        case 0xc0: return "program ch\(channel)"
        case 0xd0: return "chanAT ch\(channel)"
        case 0xe0: return "pitch ch\(channel)"
        default: return String(format: "status 0x%02x", status)
    }
}

func midiObjectString(_ object: MIDIObjectRef, _ property: CFString) -> String {
    var value: Unmanaged<CFString>?
    let status = MIDIObjectGetStringProperty(object, property, &value)
    guard status == noErr, let name = value?.takeRetainedValue() else { return "" }
    return name as String
}

func midiObjectName(_ object: MIDIObjectRef) -> String {
    let displayName = midiObjectString(object, kMIDIPropertyDisplayName)
    return displayName.isEmpty ? midiObjectString(object, kMIDIPropertyName) : displayName
}

func midiSourceLabel(_ source: MIDIEndpointRef) -> String {
    var parts: [String] = []

    var entity = MIDIEntityRef()
    if MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0 {
        var device = MIDIDeviceRef()
        if MIDIEntityGetDevice(entity, &device) == noErr, device != 0 {
            let manufacturer = midiObjectString(device, kMIDIPropertyManufacturer)
            let model = midiObjectString(device, kMIDIPropertyModel)
            let deviceName = midiObjectName(device)
            for value in [manufacturer, model, deviceName] where !value.isEmpty && !parts.contains(value) {
                parts.append(value)
            }
        }
        let entityName = midiObjectName(entity)
        if !entityName.isEmpty && !parts.contains(entityName) {
            parts.append(entityName)
        }
    }

    let endpointName = midiObjectName(source)
    if !endpointName.isEmpty && !parts.contains(endpointName) {
        parts.append(endpointName)
    }

    return parts.isEmpty ? "unnamed source" : parts.joined(separator: " / ")
}

func midiSourceNames() -> [String] {
    (0..<MIDIGetNumberOfSources()).map { index in
        midiSourceLabel(MIDIGetSource(index))
    }
}

func midiSummary(_ bytes: [UInt8]) -> String {
    guard let status = bytes.first else { return "" }
    if status & 0xf0 == 0x90, bytes.count >= 3 {
        return "\(midiStatus(status)) note=\(bytes[1]) vel=\(bytes[2])"
    }
    if status & 0xf0 == 0x80, bytes.count >= 3 {
        return "\(midiStatus(status)) note=\(bytes[1]) vel=\(bytes[2])"
    }
    if status & 0xf0 == 0xb0, bytes.count >= 3 {
        return "\(midiStatus(status)) cc=\(bytes[1]) val=\(bytes[2])"
    }
    if status & 0xf0 == 0xe0, bytes.count >= 3 {
        let value = Int(bytes[1]) | (Int(bytes[2]) << 7)
        return "\(midiStatus(status)) value=\(value)"
    }
    return midiStatus(status)
}

nonisolated(unsafe) let midiReadCallback: MIDIReadProc = { packetList, _, _ in
    var packet = packetList.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
        let length = Int(packet.length)
        let bytes = withUnsafeBytes(of: packet.data) { raw in
            Array(raw.prefix(length))
        }
        print("\rMIDI \(KKInputReportDecoder.hexDump(bytes)) | \(midiSummary(bytes))")
        print("kk> ", terminator: "")
        fflush(stdout)
        packet = MIDIPacketNext(&packet).pointee
    }
}

func startMIDIMonitor() {
    let clientStatus = MIDIClientCreate("KontrolProbe" as CFString, nil, nil, &midiClient)
    guard clientStatus == noErr else {
        print("MIDIClientCreate -> \(clientStatus)")
        return
    }
    let portStatus = MIDIInputPortCreate(midiClient, "KontrolProbe In" as CFString, midiReadCallback, nil, &midiInputPort)
    guard portStatus == noErr else {
        print("MIDIInputPortCreate -> \(portStatus)")
        return
    }

    var connected: [String] = []
    for index in 0..<MIDIGetNumberOfSources() {
        let source = MIDIGetSource(index)
        let name = midiSourceLabel(source)
        let lower = name.lowercased()
        if lower.contains("komplete") || lower.contains("kontrol") || lower.contains("native") {
            let status = MIDIPortConnectSource(midiInputPort, source, nil)
            if status == noErr {
                connected.append(name)
            } else {
                print("MIDIPortConnectSource(\(name)) -> \(status)")
            }
        }
    }

    if connected.isEmpty {
        print("MIDI monitor: no Komplete/Kontrol MIDI sources found. Use 'midi' to list sources.")
    } else {
        print("MIDI monitor: \(connected.joined(separator: ", "))")
    }
}

func printMIDISources() {
    let names = midiSourceNames()
    if names.isEmpty {
        print("MIDI sources: none")
    } else {
        print("MIDI sources:")
        for name in names {
            print("  \(name)")
        }
    }
}

func printUSBResult(_ label: String, _ result: KKUSBResult, signedStatus: Bool = false) {
    let status = UInt32(bitPattern: result.status)
    if signedStatus, result.status < 0 {
        print("\(label) -> \(result.status) / 0x\(String(format: "%08x", status))")
    } else {
        print("\(label) -> 0x\(String(format: "%08x", status))")
    }
    print("  opened=\(result.opened ? 1 : 0) pipe=\(result.pipeRef) ep=0x\(String(format: "%02x", result.endpointAddress)) endpoints=\(result.numEndpoints)")
    if !result.message.isEmpty {
        print("  \(result.message)")
    }
}

func printUSBResult(_ label: String, _ result: KontrolUSBResult, signedStatus: Bool = false) {
    printUSBResult(label, KKUSBResult(result), signedStatus: signedStatus)
}

func parseBytes(_ parts: ArraySlice<String>) -> [UInt8] {
    parts.compactMap { KKHex.parse($0).map { UInt8($0 & 0xff) } }
}

func rgbArg(_ tokens: [String], from: Int) -> KKRGB {
    let bytes = (0..<3).map { offset -> UInt8 in
        let index = from + offset
        return (index < tokens.count ? KKHex.parse(tokens[index]).map { UInt8($0 & 0xff) } : nil) ?? 0
    }
    return KKRGB(red: bytes[0], green: bytes[1], blue: bytes[2])
}

func changedIndices(previous: [UInt8]?, current: [UInt8]) -> [Int] {
    guard let previous, previous.count == current.count else { return [] }
    return (0..<current.count).filter { previous[$0] != current[$0] }
}

func printButtonLEDMap() {
    print("button LED map from cabl / report 0x80:")
    for led in KKButtonLED.allCases {
        let suffix = led.isFirmwareOwnedStatusLED ? "  (firmware status)" : ""
        print(String(format: "  %02d  %@%@", led.rawValue, led.protocolName, suffix))
    }
}

func printBenchmarkResults() {
    guard !benchmarkSamples.isEmpty else {
        print("No benchmark samples collected.")
        return
    }

    let sorted = benchmarkSamples.sorted()
    let count = benchmarkSamples.count
    let sum = benchmarkSamples.reduce(0, +)
    let avg = Double(sum) / Double(count)
    let min = sorted.first!
    let max = sorted.last!
    let medianIndex = count % 2 == 0 ? count / 2 - 1 : count / 2
    let median = sorted[medianIndex]
    let p95 = sorted[Int(Double(count) * 0.95)]
    let p99 = sorted[Int(Double(count) * 0.99)]

    print("\n=== End-to-End Latency Benchmark Results ===")
    print("Samples: \(count)")
    print("Surface: \(benchmarkSurfaceSampleCount)")
    print("MIDI:    \(benchmarkMIDISampleCount)")
    print("Min:     \(min)μs")
    print("Max:     \(max)μs")
    print("Avg:     \(String(format: "%.1f", avg))μs")
    print("Median:  \(median)μs")
    print("P95:     \(p95)μs")
    print("P99:     \(p99)μs")
    print("==========================================")

    benchmarkSamples.removeAll()
    benchmarkSampleCount = 0
    benchmarkSurfaceSampleCount = 0
    benchmarkMIDISampleCount = 0
}

func recordBenchmarkSample(source: String, latencyUs: UInt64) {
    benchmarkSamples.append(latencyUs)
    benchmarkSampleCount += 1
    if source == "surface" {
        benchmarkSurfaceSampleCount += 1
    } else if source == "midi" {
        benchmarkMIDISampleCount += 1
    }
    let progress = Double(benchmarkSampleCount) / Double(benchmarkTargetSamples) * 100
    print("\r[benchmark] \(benchmarkSampleCount)/\(benchmarkTargetSamples) (\(String(format: "%.1f", progress))%) \(source) last: \(latencyUs)μs", terminator: "")
    fflush(stdout)

    if benchmarkSampleCount >= benchmarkTargetSamples {
        benchmarkMode = false
        print("\n")
        printBenchmarkResults()
    }
}

func selfTest(_ kk: KompleteKontrolS25MK1) {
    print("self-test via libusb interrupt-OUT endpoint 0x02:")
    printUSBResult("init 0xa0", kk.handshake(), signedStatus: true)
    usleep(60_000)
    for index in 0..<KompleteKontrolS25MK1Protocol.keyCount {
        _ = kk.setKey(index, color: .hsv(Double(index) / Double(KompleteKontrolS25MK1Protocol.keyCount) * 360, 1, 1), flush: false)
    }
    printUSBResult("keys 0x82", kk.sendGuide(), signedStatus: true)
    if let result = kk.setAllButtonLEDs(value: 0x7f) {
        printUSBResult("btnLED 0x80", result, signedStatus: true)
    }
    _ = kk.clearDisplays(flush: false)
    _ = kk.setDisplayBar(1.0, display: 0, row: 0, flush: false)
    _ = kk.setDisplayText("SID", display: 0, row: 1, alignment: .center, flush: false)
    _ = kk.setDisplayText("READY", display: 0, row: 2, alignment: .center, flush: false)
    _ = kk.setDisplayBar(0.5, display: 1, row: 0, flush: false)
    _ = kk.setDisplayText("TEXT", display: 1, row: 1, alignment: .center, flush: false)
    _ = kk.setDisplayText("=+-/*<>", display: 1, row: 2, alignment: .center, flush: false)
    _ = kk.setDisplayBar(0.75, display: 2, row: 0, flush: false)
    _ = kk.setDisplayText("BAR", display: 2, row: 1, alignment: .center, flush: false)
    _ = kk.setDisplayText("75 PCT", display: 2, row: 2, alignment: .center, flush: false)
    _ = kk.setDisplayBox(display: 3, flush: false)
    for display in 4..<KKDisplayFrame.displayCount {
        _ = kk.setDisplayBar(Double(display) / Double(KKDisplayFrame.displayCount - 1), display: display, row: 0, flush: false)
        _ = kk.setDisplayText("LCD \(display)", display: display, row: 1, alignment: .center, flush: false)
        _ = kk.setDisplayText("TEXT", display: display, row: 2, alignment: .center, flush: false)
    }
    for (index, result) in kk.sendDisplays().enumerated() {
        printUSBResult("display row \(index) 0xe0", result, signedStatus: true)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--test-ui") || args.contains("--ui") {
    KontrolProbeTestUI.run()
}
if KompleteKontrolLibUSBServer.runIfRequested() {
    exit(0)
}

let banner = """
Komplete Kontrol S25 probe REPL — VID 0x17cc PID 0x1340
Daemon mode: uses privileged libusb daemon for all USB communication.
Light guide = report 0x82, RGB (3 bytes/key). Bytes are HEX (ff, 0x80, '#128').
Commands:
  demo                run the start self-test (rainbow + LEDs + displays)
  rainbow             rainbow across the key light guide
  disp                light all display segments (display reachability test)
  lcd D R TEXT...     display D (0..8), text row R (1..2), up to 8 chars
  lcdbar D VALUE      row-0 bar on display D, VALUE 0..1 or 0..100
  lcdbox D            simple box-drawing approximation on display D
  lcdoff              clear all LCD segments
  init                resend host-mode handshake (report 0xa0)
  all R G B           all 25 keys = colour (e.g. 'all 00 00 ff' = blue)
  key I R G B         key I (0..24) = colour    (keeps the rest)
  buttons V           all button LEDs = value    (try 7f, 01..7f)
  button I|NAME V     button LED by index/name = value
  buttonmap           show cabl-derived button LED names
  buttonoff           all button LEDs off
  walk [R G B]        sweep one lit key across   (default ff ff ff)
  off                 all key LEDs off
  libusb              privileged libusb detach + write endpoint 0x02
  libusbraw RID ...   privileged libusb detach + raw interrupt-OUT report
  libusbhold [N MS]   privileged LED animation, default 8 steps / 250 ms
  daemon              show daemon transport info
  daemonstatus        show daemon libusb session endpoints
  daemonread [MS]     one queued async input read; prints raw socket response
  daemonmidi [MS]     one queued async USB-MIDI read; prints raw socket response
  daemonraw LINE...   send a raw daemon socket request on the same session
  mon off|chg|all     input monitoring mode      (default chg)
  benchmark [N]       run surface/MIDI latency benchmark (default 100 samples)
  info                report daemon transport info
  help                this list
  quit
"""

let kk = KompleteKontrolS25MK1()
kk.log = { print($0) }
kk.onInputReport = { report in
    let clientTimestamp = KKTiming.now()
    let latencyUs = report.receptionTimestamp > 0 ? clientTimestamp - report.receptionTimestamp : 0

    if benchmarkMode && !report.events.isEmpty && latencyUs > 0 {
        recordBenchmarkSample(source: "surface", latencyUs: latencyUs)
        return
    }

    let header = String(format: "IN 0x%02x[%d]", report.reportID, report.bytes.count)
    if kk.monitorMode == .changed && !report.events.isEmpty {
        let latencyStr = latencyUs > 0 ? " [\(latencyUs)μs]" : ""
        print("\r\(report.events.map(\.description).joined(separator: " | "))\(latencyStr)")
    } else if kk.monitorMode == .changed {
        let diff = changedIndices(previous: report.previous, current: report.bytes)
            .map { String(format: "b%d:%02x", $0, report.bytes[$0]) }
            .joined(separator: " ")
        print("\r\(header) Δ \(diff)\(KKInputReportDecoder.summary(reportID: report.reportID, bytes: report.bytes))")
    } else {
        print("\r\(header) \(KKInputReportDecoder.hexDump(report.bytes))\(KKInputReportDecoder.summary(reportID: report.reportID, bytes: report.bytes))")
    }
    print("kk> ", terminator: "")
    fflush(stdout)
}

kk.onMIDIEvent = { event in
    let clientTimestamp = KKTiming.now()
    let latencyUs = event.receptionTimestamp > 0 ? clientTimestamp - event.receptionTimestamp : 0

    if benchmarkMode && latencyUs > 0 {
        recordBenchmarkSample(source: "midi", latencyUs: latencyUs)
        return
    }

    let latencyStr = latencyUs > 0 ? " [\(latencyUs)μs]" : ""
    print("\rMIDI: \(event.description)\(latencyStr)")
    print("kk> ", terminator: "")
    fflush(stdout)
}

let skipIntro = args.contains("--no-intro")
if !skipIntro {
    print("libusb LED intro: 2s, then daemon REPL ...")
    _ = kk.runIntroAnimation(steps: 8, intervalMs: 250)
    usleep(300_000)
}

print("KontrolProbe daemon-client mode: using launchd socket \(KompleteKontrolLibUSBServer.defaultDaemonSocketPath)")
guard kk.daemonRequest("status", timeoutUsec: 250_000) != nil else {
    fputs("Could not talk to Komplete Kontrol launch daemon. Run 'make install-daemon' to set up the daemon.\n", stderr)
    exit(1)
}

print(banner)
print("opened daemon transport — all USB communication via privileged daemon")
kk.startInputMonitoring()

printUSBResult("daemon init 0xa0", kk.handshake(), signedStatus: true)

usleep(150_000)
print("Surface input and output both use the privileged launch daemon.")
print("Use 'daemonread 200' and then press/turn a control to inspect raw daemon input.")

while true {
    print("kk> ", terminator: "")
    fflush(stdout)
    guard let line = readLine() else { break }
    let tokens = line.split(separator: " ").map(String.init)
    guard let command = tokens.first?.lowercased() else { continue }
    switch command {
        case "quit", "exit", "q":
            exit(0)
        case "help", "h", "?":
            print(banner)
        case "info":
            print("daemon transport: \(KompleteKontrolLibUSBServer.defaultDaemonSocketPath)")
            print("usesPrivilegedDaemonTransport=\(kk.usesPrivilegedDaemonTransport)")
        case "daemon":
            print("daemon transport active: true")
            print("socket: \(KompleteKontrolLibUSBServer.defaultDaemonSocketPath)")
            print("usesPrivilegedDaemonTransport=\(kk.usesPrivilegedDaemonTransport)")
        case "daemonstatus":
            let response = kk.daemonRequest("status", timeoutUsec: 250_000)
            print(response ?? "no daemon response")
        case "daemonread":
            let timeout = tokens.count > 1 ? max(1, min(KKHex.parse(tokens[1]) ?? 200, 1000)) : 200
            let response = kk.daemonRequest("read \(timeout)", timeoutUsec: useconds_t((timeout + 80) * 1000))
            print(response ?? "no daemon response")
        case "daemonmidi":
            let timeout = tokens.count > 1 ? max(1, min(KKHex.parse(tokens[1]) ?? 20, 1000)) : 20
            let response = kk.daemonRequest("midiread \(timeout)", timeoutUsec: useconds_t((timeout + 80) * 1000))
            print(response ?? "no daemon response")
        case "daemonraw":
            guard tokens.count > 1 else {
                print("usage: daemonraw LINE...")
                break
            }
            let request = tokens.dropFirst().joined(separator: " ")
            let response = kk.daemonRequest(request, timeoutUsec: 500_000)
            print(response ?? "no daemon response")
        case "init":
            printUSBResult("init 0xa0", kk.handshake(), signedStatus: true)
        case "demo":
            selfTest(kk)
        case "rainbow":
            for index in 0..<KompleteKontrolS25MK1Protocol.keyCount {
                _ = kk.setKey(index, color: .hsv(Double(index) / Double(KompleteKontrolS25MK1Protocol.keyCount) * 360, 1, 1), flush: false)
            }
            printUSBResult("keys 0x82", kk.sendGuide(), signedStatus: true)
        case "disp":
            for (index, result) in kk.displayAllSegmentsOn().enumerated() {
                printUSBResult("display row \(index) 0xe0", result, signedStatus: true)
            }
        case "lcd":
            guard tokens.count >= 4,
                  let display = KKHex.parse(tokens[1]),
                  let row = KKHex.parse(tokens[2]) else {
                print("usage: lcd D R TEXT...")
                break
            }
            let text = tokens.dropFirst(3).joined(separator: " ")
            if let results = kk.setDisplayText(text, display: display, row: row, alignment: .left) {
                for (index, result) in results.enumerated() {
                    printUSBResult("display row \(index) 0xe0", result, signedStatus: true)
                }
            } else {
                print("display or text row out of range; row 0 is bar-only")
            }
        case "lcdbar":
            guard tokens.count >= 3,
                  let display = KKHex.parse(tokens[1]),
                  let rawValue = Double(tokens[2]) else {
                print("usage: lcdbar D VALUE")
                break
            }
            let value = rawValue > 1 ? rawValue / 100.0 : rawValue
            if let results = kk.setDisplayBar(value, display: display, row: 0) {
                for (index, result) in results.enumerated() {
                    printUSBResult("display row \(index) 0xe0", result, signedStatus: true)
                }
            } else {
                print("display out of range")
            }
        case "lcdbox":
            guard tokens.count >= 2, let display = KKHex.parse(tokens[1]) else {
                print("usage: lcdbox D")
                break
            }
            if let results = kk.setDisplayBox(display: display) {
                for (index, result) in results.enumerated() {
                    printUSBResult("display row \(index) 0xe0", result, signedStatus: true)
                }
            } else {
                print("display out of range")
            }
        case "lcdoff":
            for (index, result) in kk.clearDisplays().enumerated() {
                printUSBResult("display row \(index) 0xe0", result, signedStatus: true)
            }
        case "mon":
            switch tokens.dropFirst().first {
                case "off": kk.monitorMode = .off
                case "all": kk.monitorMode = .all
                default: kk.monitorMode = .changed
            }
            print("monitor = \(["off", "changed", "all"][kk.monitorMode.rawValue])")
        case "benchmark":
            let targetCount = tokens.count > 1 ? max(10, min(KKHex.parse(tokens[1]) ?? 100, 1000)) : 100
            benchmarkMode = true
            benchmarkTargetSamples = targetCount
            benchmarkSamples.removeAll()
            benchmarkSampleCount = 0
            benchmarkSurfaceSampleCount = 0
            benchmarkMIDISampleCount = 0
            print("Starting benchmark: use buttons, encoders, touch controls, keys, pitch, or mod wheel.")
            print("Target: \(targetCount) samples. Use any control to begin...")
            print("(Type 'quit' to cancel)")
        case "benchmark-midi":
            print("benchmark-midi was folded into benchmark. Use: benchmark [N]")
        case "all":
            let rgb = rgbArg(tokens, from: 1)
            _ = kk.setAllKeys(color: rgb)
        case "key":
            if tokens.count >= 5, let index = KKHex.parse(tokens[1]) {
                _ = kk.setKey(index, color: rgbArg(tokens, from: 2))
            } else {
                print("usage: key I R G B")
            }
        case "buttons", "btns":
            if tokens.count >= 2, let value = KKHex.parse(tokens[1]) {
                _ = kk.setAllButtonLEDs(value: UInt8(value & 0xff))
            } else {
                print("usage: buttons V")
            }
        case "button", "btn":
            if tokens.count >= 3, let value = KKHex.parse(tokens[2]), kk.setButtonLED(name: tokens[1], value: UInt8(value & 0xff)) != nil {
                break
            } else {
                print("usage: button I|NAME V")
            }
        case "buttonmap", "btnmap":
            printButtonLEDMap()
        case "buttonoff", "btnoff":
            _ = kk.clearButtonLEDs()
        case "walk":
            let rgb = tokens.count >= 4 ? rgbArg(tokens, from: 1) : KKRGB(red: 0xff, green: 0xff, blue: 0xff)
            for index in 0..<KompleteKontrolS25MK1Protocol.keyCount {
                var keys = [UInt8](repeating: 0, count: 3 * KompleteKontrolS25MK1Protocol.keyCount)
                keys[3 * index] = rgb.red
                keys[3 * index + 1] = rgb.green
                keys[3 * index + 2] = rgb.blue
                _ = kk.sendInterruptOutput(reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: keys)
                usleep(120_000)
            }
            _ = kk.sendGuide()
        case "off":
            _ = kk.clearKeys()
        case "libusb":
            selfTest(kk)
        case "libusbhold":
            let steps = tokens.count > 1 ? UInt32((KKHex.parse(tokens[1]) ?? 8) & 0xffff) : 8
            let intervalMs = tokens.count > 2 ? UInt32((KKHex.parse(tokens[2]) ?? 250) & 0xffff) : 250
            for (index, result) in kk.runIntroAnimation(steps: steps, intervalMs: intervalMs).enumerated() {
                if !result.succeeded {
                    printUSBResult("libusbhold step \(index)", result, signedStatus: true)
                }
            }
        case "libusbraw":
            if tokens.count > 1, let reportID = KKHex.parse(tokens[1]) {
                printUSBResult(
                    "libusbraw 0x\(String(reportID, radix: 16))",
                    kk.sendInterruptOutput(reportID: UInt8(reportID & 0xff), payload: parseBytes(tokens[2...])),
                    signedStatus: true
                )
            } else {
                print("usage: libusbraw RID b0 b1 ...")
            }
        default:
            print("? \(command) — try 'help'")
    }
}
