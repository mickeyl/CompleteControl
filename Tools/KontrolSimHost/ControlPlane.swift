import Foundation

/// JSON-Lines control plane on stdin/stdout, following the widget-lab `--control-stdin`
/// precedent. Events and command responses are single-line JSON objects; stdin EOF is a
/// clean-shutdown request so a dying test runner can never leave the host behind.
final class ControlPlane: @unchecked Sendable {
    var onCommand: (([String: Any]) -> [String: Any])?
    var onEndOfInput: (() -> Void)?

    private let writeLock = NSLock()

    func start() {
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    func emit(event: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["event"] = event
        write(object)
    }

    private func readLoop() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                write(["ok": false, "error": "malformed JSON command"])
                continue
            }
            DispatchQueue.main.sync { [weak self] in
                guard let self, let onCommand = self.onCommand else { return }
                var response = onCommand(object)
                if let id = object["id"] { response["id"] = id }
                self.write(response)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.onEndOfInput?() }
    }

    private func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        writeLock.lock()
        fputs(line + "\n", stdout)
        fflush(stdout)
        writeLock.unlock()
    }
}
