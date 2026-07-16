import Darwin
import Foundation

struct LabControlDemoDescriptor: Codable, Sendable {
    let id: String
    let title: String
    let category: String
    let summary: String
    let detail: String
    let snapshotVariants: [String]

    init(_ descriptor: DemoDescriptor) {
        id = descriptor.id
        title = descriptor.title
        category = descriptor.category.title
        summary = descriptor.summary
        detail = descriptor.detail
        snapshotVariants = descriptor.snapshotVariants
    }
}

struct LabSnapshotArtifacts: Codable, Sendable {
    let png: String
    let screensRGB565BE: [String]
}

private struct LabControlRequest: Decodable {
    let id: Int
    let command: String
    let demo: String?
    let variant: String?
    let directory: String?
    let name: String?
}

private struct LabControlResponse: Encodable {
    var id: Int?
    var event: String?
    var ok: Bool
    var error: String?
    var mode: String?
    var demo: String?
    var state: String?
    var demos: [LabControlDemoDescriptor]?
    var snapshot: LabSnapshotArtifacts?
}

enum LabControlServer {
    static func describeData(pretty: Bool) throws -> Data {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(labDemos.map { LabControlDemoDescriptor($0.descriptor) })
    }

    static func start(lab: LabShell) {
        let thread = Thread {
            emit(LabControlResponse(event: "ready", ok: true))
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let done = DispatchSemaphore(value: 0)
                Task {
                    await handle(trimmed, lab: lab)
                    done.signal()
                }
                done.wait()
            }
            exit(0)
        }
        thread.stackSize = 1 << 20
        thread.name = "widgetlab-control"
        thread.start()
    }

    private static func handle(_ line: String, lab: LabShell) async {
        let request: LabControlRequest
        do {
            request = try JSONDecoder().decode(LabControlRequest.self, from: Data(line.utf8))
        } catch {
            emit(LabControlResponse(ok: false, error: "invalid JSON request: \(error.localizedDescription)"))
            return
        }

        switch request.command {
            case "describe":
                emit(LabControlResponse(
                    id: request.id,
                    ok: true,
                    demos: labDemos.map { LabControlDemoDescriptor($0.descriptor) }
                ))

            case "status":
                let status = await lab.controlStatus()
                emit(LabControlResponse(
                    id: request.id,
                    ok: true,
                    mode: status.mode,
                    demo: status.demo,
                    state: status.state
                ))

            case "browser":
                await lab.showBrowser()
                emit(LabControlResponse(id: request.id, ok: true, mode: "browser"))

            case "open":
                guard let demo = request.demo, await lab.controlOpenDemo(id: demo) else {
                    emit(LabControlResponse(id: request.id, ok: false, error: "unknown demo id"))
                    return
                }
                emit(LabControlResponse(id: request.id, ok: true, mode: "demo", demo: demo))

            case "prepare":
                let variant = request.variant ?? ""
                guard let demo = await lab.controlPrepareSnapshot(variant: variant) else {
                    emit(LabControlResponse(
                        id: request.id,
                        ok: false,
                        error: "no active demo or unknown snapshot variant"
                    ))
                    return
                }
                emit(LabControlResponse(id: request.id, ok: true, mode: "demo", demo: demo))

            case "snapshot":
                guard let directory = request.directory, !directory.isEmpty else {
                    emit(LabControlResponse(id: request.id, ok: false, error: "snapshot requires directory"))
                    return
                }
                do {
                    let snapshot = try await lab.controlSnapshot(
                        to: directory,
                        name: request.name ?? "widgetlab-control"
                    )
                    emit(LabControlResponse(id: request.id, ok: true, snapshot: snapshot))
                } catch {
                    emit(LabControlResponse(
                        id: request.id,
                        ok: false,
                        error: "snapshot failed: \(error.localizedDescription)"
                    ))
                }

            case "quit":
                emit(LabControlResponse(id: request.id, ok: true))
                exit(0)

            default:
                emit(LabControlResponse(
                    id: request.id,
                    ok: false,
                    error: "unknown command '\(request.command)'"
                ))
        }
    }

    private static func emit(_ response: LabControlResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
}
