import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// End-to-end display transport benchmark. Fixtures are rendered before timing;
/// each measured presentation covers reconciler diffing, daemon IPC/queueing,
/// packet encoding, and the completed physical USB transfer.
final class DisplayBenchmarkDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "display-benchmark",
        title: "Display Benchmark",
        category: .diagnostics,
        summary: "Real USB latency across typical payloads",
        detail: "Runs deterministic cursor, rotary-value, meter, large-gap, large-content, solid-full-screen, and noisy-full-screen updates. PLAY or 4-D press starts; STOP cancels. Results report physical bytes, USB median, and end-to-end P90.",
        snapshotVariants: ["results"]
    )

    private struct Fixture: Sendable {
        var id: String
        var title: String
        var first: [MK2PixelFrame?]
        var second: [MK2PixelFrame?]
    }

    private struct Sample: Sendable {
        var logicalBytes: Int
        var transportBytes: UInt64
        var transportNanoseconds: UInt64
        var wallNanoseconds: UInt64
    }

    private struct Result: Sendable {
        var id: String
        var title: String
        var samples: [Sample]

        var averageLogicalBytes: Double {
            Double(samples.reduce(0) { $0 + $1.logicalBytes }) / Double(max(1, samples.count))
        }

        var averageTransportBytes: Double {
            Double(samples.reduce(UInt64(0)) { $0 + $1.transportBytes }) / Double(max(1, samples.count))
        }

        var transportMedianMilliseconds: Double {
            percentile(samples.map(\.transportNanoseconds), fraction: 0.5)
        }

        var wallMedianMilliseconds: Double {
            percentile(samples.map(\.wallNanoseconds), fraction: 0.5)
        }

        var wallP90Milliseconds: Double {
            percentile(samples.map(\.wallNanoseconds), fraction: 0.9)
        }

        private func percentile(_ values: [UInt64], fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
            return Double(sorted[index]) / 1_000_000.0
        }
    }

    private enum State: Sendable {
        case ready
        case running
        case complete(encoding: String, iterations: Int, results: [Result])
        case failed(String)
    }

    private static let defaultIterations = 12
    private var state: State = .ready
    private var runTask: Task<Void, Never>?

    func prepareSnapshot(variant: String) {
        guard variant == "results" else {
            state = .ready
            return
        }
        let titles = [
            ("cursor", "SMALL CURSOR"),
            ("rotary", "ROTARY VALUE"),
            ("meter", "METER STEP"),
            ("large-gap", "LARGE GAP"),
            ("large", "LARGE CONTENT"),
            ("full-solid", "FULL SOLID"),
            ("full-noise", "FULL NOISE"),
        ]
        let results = titles.enumerated().map { index, entry in
            Result(
                id: entry.0,
                title: entry.1,
                samples: [Sample(
                    logicalBytes: 7_680 + index * 24_000,
                    transportBytes: UInt64(1_200 + index * 9_700),
                    transportNanoseconds: UInt64(620_000 + index * 480_000),
                    wallNanoseconds: UInt64(910_000 + index * 610_000)
                )]
            )
        }
        state = .complete(encoding: "adaptive", iterations: Self.defaultIterations, results: results)
    }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        let displays: (MK2PixelFrame, MK2PixelFrame)
        switch state {
            case .ready:
                displays = readyFrames(context.renderer)
            case .running:
                displays = runningFrames(context.renderer)
            case let .complete(encoding, iterations, results):
                displays = resultFrames(
                    encoding: encoding,
                    iterations: iterations,
                    results: results,
                    renderer: context.renderer
                )
            case let .failed(message):
                displays = failedFrames(message, renderer: context.renderer)
        }

        var scene = MK2SurfaceScene2(left: displays.0, right: displays.1)
        scene.lamps[.play] = .green
        if runTask != nil {
            scene.lamps[.stop] = .red
        }
        scene.bindings.onPress(.play) { [weak self] in
            self?.start(iterations: Self.defaultIterations, context)
        }
        scene.bindings.onPress(.stop) { [weak self] in
            self?.cancel(context)
        }
        scene.bindings.jogCenter = { [weak self] in
            self?.start(iterations: Self.defaultIterations, context)
        }
        return scene
    }

    func demoWillClose() {
        runTask?.cancel()
    }

    func testState() -> String? {
        switch state {
            case .ready: "ready"
            case .running: "running"
            case .complete: "complete"
            case .failed: "failed"
        }
    }

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(
                name: "displaybench",
                arg: "[3-50]",
                summary: "run the physical display benchmark",
                values: ["6", "12", "20"]
            ),
        ]
    }

    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool {
        guard verb == "displaybench" else { return false }
        let requested = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Self.defaultIterations
        start(iterations: min(50, max(3, requested)), context)
        return true
    }

    private func start(iterations: Int, _ context: LabContext) {
        guard runTask == nil else { return }
        state = .running
        context.update {}
        runTask = Task { [weak self] in
            await self?.run(iterations: iterations, context)
        }
    }

    private func cancel(_: LabContext) {
        guard let runTask else { return }
        runTask.cancel()
        // `ready` is also the machine-control completion signal. Publish it only
        // after `run` has closed the daemon measurement session; otherwise an
        // external runner can start its next session while cancellation cleanup
        // is still ending the previous one.
    }

    private func run(iterations: Int, _ context: LabContext) async {
        let fixtures = makeFixtures(renderer: context.renderer)
        var measurementSessionStarted = false
        do {
            let encoding = try await context.beginDisplayMeasurements()
            measurementSessionStarted = true
            var results: [Result] = []
            results.reserveCapacity(fixtures.count)

            for fixture in fixtures {
                try Task.checkCancellation()
                // Establish the fixture's exact physical and reconciler shadow;
                // setup traffic is intentionally excluded from the result.
                _ = try await context.measureDisplays(fixture.first)
                var samples: [Sample] = []
                samples.reserveCapacity(iterations)
                for index in 0..<iterations {
                    try Task.checkCancellation()
                    let displays = index.isMultiple(of: 2) ? fixture.second : fixture.first
                    let measurement = try await context.measureDisplays(displays)
                    samples.append(Sample(
                        logicalBytes: measurement.logicalPixelBytes,
                        transportBytes: measurement.transport.byteCount,
                        transportNanoseconds: measurement.transport.transportNanoseconds,
                        wallNanoseconds: measurement.wallNanoseconds
                    ))
                }
                results.append(Result(id: fixture.id, title: fixture.title, samples: samples))
            }

            _ = try await context.endDisplayMeasurements()
            measurementSessionStarted = false
            printResults(encoding: encoding, iterations: iterations, results: results)
            runTask = nil
            state = .complete(encoding: encoding, iterations: iterations, results: results)
            context.update {}
        } catch is CancellationError {
            if measurementSessionStarted {
                _ = try? await context.endDisplayMeasurements()
            }
            runTask = nil
            state = .ready
            context.update {}
        } catch {
            if measurementSessionStarted {
                _ = try? await context.endDisplayMeasurements()
            }
            let message = String(describing: error)
            labDiagnostic("BENCH display error=\(message.replacingOccurrences(of: " ", with: "_"))")
            runTask = nil
            state = .failed(message)
            context.update {}
        }
    }

    private func makeFixtures(renderer: FreeTypeTextRenderer?) -> [Fixture] {
        let base = typicalFrame(title: "SMALL CURSOR", detail: "8 × 8 marker movement")
        var cursorA = base
        var cursorB = base
        cursorA.fill(MK2PixelRect(x: 226, y: 126, width: 8, height: 8), Palette.green)
        cursorB.fill(MK2PixelRect(x: 246, y: 126, width: 8, height: 8), Palette.green)

        let rotaryA = rotaryFrame(value: "127", renderer: renderer)
        let rotaryB = rotaryFrame(value: "128", renderer: renderer)
        let meterA = meterFrame(level: 0.42, renderer: renderer)
        let meterB = meterFrame(level: 0.61, renderer: renderer)

        var gapA = typicalFrame(title: "LARGE GAP", detail: "header + footer, clean centre")
        var gapB = gapA
        gapA.fill(MK2PixelRect(x: 16, y: 42, width: 448, height: 14), Palette.blue)
        gapA.fill(MK2PixelRect(x: 16, y: 226, width: 448, height: 14), Palette.green)
        gapB.fill(MK2PixelRect(x: 16, y: 42, width: 448, height: 14), Palette.orange)
        gapB.fill(MK2PixelRect(x: 16, y: 226, width: 448, height: 14), Palette.solo)

        let largeA = noisyRegionFrame(
            title: "LARGE CONTENT",
            rect: MK2PixelRect(x: 0, y: 56, width: 480, height: 160),
            seed: 0x1357
        )
        let largeB = noisyRegionFrame(
            title: "LARGE CONTENT",
            rect: MK2PixelRect(x: 0, y: 56, width: 480, height: 160),
            seed: 0x2468
        )

        let solidA = MK2PixelFrame(fill: 0x0841)
        let solidB = MK2PixelFrame(fill: 0x39e7)
        let noisyA = noisyFrame(seed: 0x3141)
        let noisyB = noisyFrame(seed: 0x5926)

        return [
            Fixture(id: "cursor", title: "SMALL CURSOR", first: [cursorA, nil], second: [cursorB, nil]),
            Fixture(id: "rotary", title: "ROTARY VALUE", first: [rotaryA, nil], second: [rotaryB, nil]),
            Fixture(id: "meter", title: "METER STEP", first: [meterA, nil], second: [meterB, nil]),
            Fixture(id: "large-gap", title: "LARGE GAP", first: [gapA, nil], second: [gapB, nil]),
            Fixture(id: "large", title: "LARGE CONTENT", first: [largeA, nil], second: [largeB, nil]),
            Fixture(id: "full-solid", title: "FULL SOLID", first: [solidA, nil], second: [solidB, nil]),
            Fixture(id: "full-noise", title: "FULL NOISE", first: [noisyA, nil], second: [noisyB, nil]),
        ]
    }

    private func typicalFrame(title: String, detail: String) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        frame.fill(MK2PixelRect(x: 0, y: 0, width: 480, height: 34), 0x1083)
        frame.fill(MK2PixelRect(x: 0, y: 252, width: 480, height: 20), 0x1083)
        for row in 0..<8 {
            let y = 52 + row * 22
            if row.isMultiple(of: 2) {
                frame.fill(MK2PixelRect(x: 12, y: y, width: 456, height: 18), Palette.rowStripe)
            }
            for column in 0..<4 {
                let x = 20 + column * 114
                frame.fill(MK2PixelRect(x: x, y: y + 6, width: 48 + (row * 7 + column * 11) % 42, height: 3), Palette.dim)
            }
        }
        BitmapLabel(title, font: .readoutBold, color: Palette.text).draw(into: &frame, x: 12, y: 9)
        BitmapLabel(detail.uppercased(), font: .label, color: Palette.dim).draw(into: &frame, x: 170, y: 11)
        return frame
    }

    private func rotaryFrame(value: String, renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("ROTARY VALUE", x: 8, color: Palette.blue),
                MK2StatusLineItem("ONE ENCODER STEP", x: 190, color: Palette.dim),
            ])
        ) {
            MK2ParameterPageElement(slots: [
                MK2ParameterPageSlot(label: "CUTOFF", value: value, selection: .none),
                MK2ParameterPageSlot(label: "RESONANCE", value: "64", selection: .none),
                MK2ParameterPageSlot(label: "ATTACK", value: "12 ms", selection: .none),
                MK2ParameterPageSlot(label: "RELEASE", value: "240 ms", selection: .none),
            ])
        }.build(renderer: renderer).screen.frame
    }

    private func meterFrame(level: Double, renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("METER STEP", x: 8, color: Palette.green),
                MK2StatusLineItem("4 CHANNELS", x: 210, color: Palette.dim),
            ])
        ) {
            MK2MeterElement(
                channels: [
                    MK2MeterChannel(label: "1", level: level, peak: level + 0.08),
                    MK2MeterChannel(label: "2", level: level * 0.82, peak: level + 0.04),
                    MK2MeterChannel(label: "3", level: level * 0.66, peak: level),
                    MK2MeterChannel(label: "4", level: level * 0.48, peak: level * 0.8),
                ],
                rect: MK2PixelRect(x: 18, y: 56, width: 444, height: 156),
                style: .protracker,
                relativeToContent: false
            )
        }.build(renderer: renderer).screen.frame
    }

    private func noisyRegionFrame(title: String, rect: MK2PixelRect, seed: UInt32) -> MK2PixelFrame {
        var frame = typicalFrame(title: title, detail: "contiguous noisy bitmap")
        fillNoise(&frame, rect: rect, seed: seed)
        return frame
    }

    private func noisyFrame(seed: UInt32) -> MK2PixelFrame {
        var frame = MK2PixelFrame()
        fillNoise(&frame, rect: MK2PixelFrame.bounds, seed: seed)
        return frame
    }

    private func fillNoise(_ frame: inout MK2PixelFrame, rect: MK2PixelRect, seed: UInt32) {
        var state = seed
        for y in rect.y..<rect.maxY {
            for x in rect.x..<rect.maxX {
                state = state &* 1_664_525 &+ 1_013_904_223
                frame[x, y] = UInt16(truncatingIfNeeded: state >> 8)
            }
        }
    }

    private func readyFrames(_ renderer: FreeTypeTextRenderer?) -> (MK2PixelFrame, MK2PixelFrame) {
        var left = MK2PixelFrame(fill: Palette.page)
        drawFreeTypeTitle("DISPLAY BENCHMARK", into: &left, renderer: renderer, x: 18, y: 28, size: 27, color: Palette.text, maxWidth: 444)
        drawFreeTypeBody("Deterministic real-device payload replay", into: &left, renderer: renderer, x: 18, y: 68, size: 17, color: Palette.blue, maxWidth: 444)
        drawFreeTypeBody("7 workloads × 12 measured updates", into: &left, renderer: renderer, x: 18, y: 104, size: 18, color: Palette.text, maxWidth: 444)
        drawFreeTypeBody("PLAY or 4-D press starts", into: &left, renderer: renderer, x: 18, y: 148, size: 20, color: Palette.green, maxWidth: 444)
        drawFreeTypeBody("Use the release build for comparable numbers.", into: &left, renderer: renderer, x: 18, y: 204, size: 16, color: Palette.dim, maxWidth: 444)

        var right = MK2PixelFrame(fill: Palette.page)
        drawFreeTypeTitle("MEASURED", into: &right, renderer: renderer, x: 18, y: 28, size: 24, color: Palette.text, maxWidth: 210)
        let lines = [
            "Small cursor movement",
            "Rotary encoder value",
            "Four-channel meter step",
            "Large band with clean gap",
            "Large contiguous bitmap",
            "Full-screen solid fill",
            "Full-screen noisy bitmap",
        ]
        for (index, line) in lines.enumerated() {
            drawFreeTypeBody("\(index + 1). \(line)", into: &right, renderer: renderer, x: 22, y: 68 + index * 25, size: 15, color: index < 3 ? Palette.text : Palette.dim, maxWidth: 430)
        }
        drawFreeTypeBody("STOP cancels · SCENE exits", into: &right, renderer: renderer, x: 18, y: 246, size: 14, color: Palette.orange, maxWidth: 444)
        return (left, right)
    }

    private func runningFrames(_ renderer: FreeTypeTextRenderer?) -> (MK2PixelFrame, MK2PixelFrame) {
        var left = MK2PixelFrame(fill: Palette.page)
        drawFreeTypeTitle("BENCHMARK RUNNING…", into: &left, renderer: renderer, x: 18, y: 86, size: 28, color: Palette.green, maxWidth: 444)
        drawFreeTypeBody("Fixtures will replace this screen during measurement.", into: &left, renderer: renderer, x: 18, y: 132, size: 16, color: Palette.dim, maxWidth: 444, maxLines: 2)
        var right = MK2PixelFrame(fill: Palette.page)
        drawFreeTypeTitle("DO NOT TOUCH", into: &right, renderer: renderer, x: 18, y: 86, size: 28, color: Palette.orange, maxWidth: 444)
        drawFreeTypeBody("STOP cancels after the current USB transfer.", into: &right, renderer: renderer, x: 18, y: 132, size: 16, color: Palette.dim, maxWidth: 444, maxLines: 2)
        return (left, right)
    }

    private func failedFrames(_ message: String, renderer: FreeTypeTextRenderer?) -> (MK2PixelFrame, MK2PixelFrame) {
        var left = MK2PixelFrame(fill: Palette.page)
        drawFreeTypeTitle("BENCHMARK FAILED", into: &left, renderer: renderer, x: 18, y: 54, size: 28, color: Palette.mute, maxWidth: 444)
        drawFreeTypeBody(message, into: &left, renderer: renderer, x: 18, y: 106, size: 16, color: Palette.text, maxWidth: 444, maxLines: 5)
        var right = MK2PixelFrame(fill: Palette.page)
        drawFreeTypeTitle("CHECK DAEMON", into: &right, renderer: renderer, x: 18, y: 54, size: 26, color: Palette.orange, maxWidth: 444)
        drawFreeTypeBody("Install the matching ccd build, verify the selected display encoding, then press PLAY to retry.", into: &right, renderer: renderer, x: 18, y: 106, size: 16, color: Palette.dim, maxWidth: 444, maxLines: 5)
        return (left, right)
    }

    private func resultFrames(
        encoding: String,
        iterations: Int,
        results: [Result],
        renderer: FreeTypeTextRenderer?
    ) -> (MK2PixelFrame, MK2PixelFrame) {
        let split = min(4, results.count)
        let left = resultTableFrame(
            title: "DISPLAY BENCH · \(encoding.uppercased())",
            subtitle: "\(iterations) UPDATES / PAYLOAD",
            results: Array(results.prefix(split)),
            renderer: renderer,
            totalResults: nil
        )
        let right = resultTableFrame(
            title: "PHYSICAL TRANSPORT",
            subtitle: "BYTES · USB MED · E2E P90",
            results: Array(results.dropFirst(split)),
            renderer: renderer,
            totalResults: results
        )
        return (left, right)
    }

    private func resultTableFrame(
        title: String,
        subtitle: String,
        results: [Result],
        renderer: FreeTypeTextRenderer?,
        totalResults: [Result]?
    ) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        drawFreeTypeTitle(title, into: &frame, renderer: renderer, x: 12, y: 12, size: 20, color: Palette.text, maxWidth: 456)
        BitmapLabel(subtitle, font: .label, color: Palette.dim).draw(into: &frame, x: 14, y: 42)
        BitmapLabel("PAYLOAD              KB     USB     P90", font: .label, color: Palette.blue).draw(into: &frame, x: 14, y: 68)
        frame.fill(MK2PixelRect(x: 12, y: 84, width: 456, height: 1), Palette.border)
        for (index, result) in results.enumerated() {
            drawResultRow(result, y: 96 + index * 34, into: &frame)
        }
        if let totalResults {
            let allSamples = totalResults.flatMap(\.samples)
            let total = Result(id: "total", title: "ALL PAYLOADS", samples: allSamples)
            frame.fill(MK2PixelRect(x: 12, y: 204, width: 456, height: 1), Palette.border)
            drawResultRow(total, y: 216, into: &frame, color: Palette.green)
        }
        BitmapLabel("PLAY / 4-D = RUN AGAIN", font: .label, color: Palette.dim).draw(into: &frame, x: 14, y: 254)
        return frame
    }

    private func drawResultRow(
        _ result: Result,
        y: Int,
        into frame: inout MK2PixelFrame,
        color: UInt16 = Palette.text
    ) {
        let name = String(result.title.prefix(19)).padding(toLength: 19, withPad: " ", startingAt: 0)
        let kilobytes = result.averageTransportBytes / 1024.0
        let line = String(
            format: "%@ %6.1f %7.2f %7.2f",
            name,
            kilobytes,
            result.transportMedianMilliseconds,
            result.wallP90Milliseconds
        )
        BitmapLabel(line, font: .grid, color: color).draw(into: &frame, x: 14, y: y)
    }

    private func printResults(encoding: String, iterations: Int, results: [Result]) {
        labDiagnostic("BENCH display encoding=\(encoding) iterations=\(iterations) scenarios=\(results.count)")
        for result in results {
            labDiagnostic(String(
                format: "BENCH display scenario=%@ count=%d logicalAvg=%.0f transportAvg=%.0f usbMedianMs=%.3f wallMedianMs=%.3f wallP90Ms=%.3f",
                result.id,
                result.samples.count,
                result.averageLogicalBytes,
                result.averageTransportBytes,
                result.transportMedianMilliseconds,
                result.wallMedianMilliseconds,
                result.wallP90Milliseconds
            ))
        }
        let samples = results.flatMap(\.samples)
        let total = Result(id: "total", title: "TOTAL", samples: samples)
        labDiagnostic(String(
            format: "BENCH display totalCount=%d logicalAvg=%.0f transportAvg=%.0f usbMedianMs=%.3f wallMedianMs=%.3f wallP90Ms=%.3f",
            samples.count,
            total.averageLogicalBytes,
            total.averageTransportBytes,
            total.transportMedianMilliseconds,
            total.wallMedianMilliseconds,
            total.wallP90Milliseconds
        ))
        fflush(stdout)
    }
}
