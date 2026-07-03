import Foundation

struct SSEEvent: Equatable, Sendable {
    var name: String
    var data: String
}

/// Incremental server-sent-events parser. Byte-buffer based so chunk
/// boundaries may fall anywhere, including inside multi-byte UTF-8
/// sequences. Tolerates both LF and CRLF framing.
final class SSEParser {
    private var buffer = Data()

    func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let boundary = nextBoundary() {
            let block = buffer.subdata(in: buffer.startIndex..<boundary.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<boundary.upperBound)
            if let event = Self.parseBlock(block) {
                events.append(event)
            }
        }
        return events
    }

    /// Parses whatever remains after the stream ends (a final event without
    /// a trailing blank line).
    func flush() -> [SSEEvent] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll() }
        return Self.parseBlock(buffer).map { [$0] } ?? []
    }

    /// Earliest blank-line separator: \n\n, \r\n\r\n or \n\r\n.
    private func nextBoundary() -> Range<Data.Index>? {
        let candidates = [
            buffer.range(of: Data([0x0A, 0x0A])),
            buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])),
            buffer.range(of: Data([0x0A, 0x0D, 0x0A])),
        ]
        return candidates.compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func parseBlock(_ block: Data) -> SSEEvent? {
        var name = "message"
        var dataLines: [String] = []
        for rawLine in block.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = rawLine
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty, line.first != UInt8(ascii: ":") else { continue }
            let text = String(decoding: line, as: UTF8.self)
            if let value = fieldValue(of: "event", in: text) {
                name = value
            } else if let value = fieldValue(of: "data", in: text) {
                dataLines.append(value)
            }
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(name: name, data: dataLines.joined(separator: "\n"))
    }

    private static func fieldValue(of field: String, in line: String) -> String? {
        guard line.hasPrefix(field + ":") else { return nil }
        var value = String(line.dropFirst(field.count + 1))
        if value.hasPrefix(" ") { value.removeFirst() }
        return value
    }
}
