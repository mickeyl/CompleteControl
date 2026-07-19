import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A small self-contained raw-mode line editor for the lab REPL: cursor editing, ↑/↓
/// history, Home/End, and Tab completion driven by a caller-supplied completer. No external
/// dependency (linenoise-style). Falls back to plain `readLine()` when stdin is not a TTY
/// (piped/backgrounded), so scripted use keeps working.
final class LineReader {
    static var hasInteractiveInput: Bool {
        isatty(STDIN_FILENO) != 0
    }

    /// Given the current whitespace-split tokens (with a trailing empty token if the line
    /// ends in a space), return the candidate words for the last token position.
    private let completer: ([String]) -> [String]
    private var history: [String] = []

    init(completer: @escaping ([String]) -> [String]) {
        self.completer = completer
    }

    func addHistory(_ line: String) {
        guard history.last != line else { return }
        history.append(line)
    }

    func readLine(prompt: String) -> String? {
        guard Self.hasInteractiveInput else {
            return Swift.readLine(strippingNewline: true)
        }
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON) // keep ISIG so Ctrl-C still quits
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }

        var buffer: [UInt8] = []
        var cursor = 0 // byte index, kept on UTF-8 boundaries
        var historyIndex = history.count
        redraw(prompt: prompt, buffer: buffer, cursor: cursor)

        while true {
            var byte: UInt8 = 0
            let n = read(STDIN_FILENO, &byte, 1)
            guard n == 1 else { return buffer.isEmpty ? nil : decode(buffer) }

            switch byte {
                case 0x0d, 0x0a: // Enter
                    write("\r\n")
                    return decode(buffer)

                case 0x04: // Ctrl-D
                    if buffer.isEmpty { write("\r\n"); return nil }

                case 0x7f, 0x08: // Backspace
                    if cursor > 0 {
                        let start = prevBoundary(buffer, cursor)
                        buffer.removeSubrange(start..<cursor)
                        cursor = start
                        redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                    }

                case 0x01: // Ctrl-A → home
                    cursor = 0; redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                case 0x05: // Ctrl-E → end
                    cursor = buffer.count; redraw(prompt: prompt, buffer: buffer, cursor: cursor)

                case 0x09: // Tab
                    complete(prompt: prompt, buffer: &buffer, cursor: &cursor)

                case 0x1b: // ESC — arrow / navigation sequence
                    var seq: [UInt8] = [0, 0]
                    guard read(STDIN_FILENO, &seq[0], 1) == 1, read(STDIN_FILENO, &seq[1], 1) == 1 else { break }
                    if seq[0] == 0x5b || seq[0] == 0x4f { // '[' or 'O'
                        switch seq[1] {
                            case 0x41: // up
                                if historyIndex > 0 {
                                    historyIndex -= 1
                                    buffer = Array(history[historyIndex].utf8); cursor = buffer.count
                                    redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                                }
                            case 0x42: // down
                                if historyIndex < history.count {
                                    historyIndex += 1
                                    buffer = historyIndex == history.count ? [] : Array(history[historyIndex].utf8)
                                    cursor = buffer.count
                                    redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                                }
                            case 0x43: // right
                                if cursor < buffer.count { cursor = nextBoundary(buffer, cursor); redraw(prompt: prompt, buffer: buffer, cursor: cursor) }
                            case 0x44: // left
                                if cursor > 0 { cursor = prevBoundary(buffer, cursor); redraw(prompt: prompt, buffer: buffer, cursor: cursor) }
                            case 0x48: // home
                                cursor = 0; redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                            case 0x46: // end
                                cursor = buffer.count; redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                            default: break
                        }
                    }

                default:
                    if byte >= 0x20 { // printable (incl. UTF-8 lead/continuation bytes ≥ 0x80)
                        buffer.insert(byte, at: cursor)
                        cursor += 1
                        redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                    }
            }
        }
    }

    // MARK: - Completion

    private func complete(prompt: String, buffer: inout [UInt8], cursor: inout Int) {
        guard cursor == buffer.count else { return } // complete at end of line only
        let line = decode(buffer)
        let endsInSpace = line.hasSuffix(" ")
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if endsInSpace || tokens.isEmpty { tokens.append("") }
        let partial = tokens.last ?? ""
        let candidates = completer(tokens).filter { $0.hasPrefix(partial) }
        guard !candidates.isEmpty else { return }

        let completion = commonPrefix(candidates)
        if completion.count > partial.count {
            tokens[tokens.count - 1] = completion
            var newLine = tokens.joined(separator: " ")
            if candidates.count == 1 { newLine += " " }
            buffer = Array(newLine.utf8); cursor = buffer.count
            redraw(prompt: prompt, buffer: buffer, cursor: cursor)
        } else if candidates.count > 1 {
            write("\r\n" + candidates.joined(separator: "  ") + "\r\n")
            redraw(prompt: prompt, buffer: buffer, cursor: cursor)
        }
    }

    private func commonPrefix(_ words: [String]) -> String {
        guard var prefix = words.first else { return "" }
        for word in words.dropFirst() {
            while !word.hasPrefix(prefix) { prefix = String(prefix.dropLast()) }
        }
        return prefix
    }

    // MARK: - Rendering & UTF-8 helpers

    private func redraw(prompt: String, buffer: [UInt8], cursor: Int) {
        let columns = prompt.count + decode(Array(buffer[0..<cursor])).count
        var out = "\r\u{1b}[K" + prompt + decode(buffer) + "\r"
        if columns > 0 { out += "\u{1b}[\(columns)C" }
        write(out)
    }

    private func decode(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    private func prevBoundary(_ bytes: [UInt8], _ index: Int) -> Int {
        var i = index - 1
        while i > 0, (bytes[i] & 0xc0) == 0x80 { i -= 1 } // skip UTF-8 continuation bytes
        return i
    }

    private func nextBoundary(_ bytes: [UInt8], _ index: Int) -> Int {
        var i = index + 1
        while i < bytes.count, (bytes[i] & 0xc0) == 0x80 { i += 1 }
        return i
    }

    private func write(_ string: String) {
        FileHandle.standardOutput.write(Data(string.utf8))
    }
}
