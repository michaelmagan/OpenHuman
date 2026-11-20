import Foundation

extension OutputGuard {
    /// Extracts one object, preserving quoted text and accepting a missing final object delimiter.
    static func replyJSON(from text: String) -> Data? {
        guard let start = text.utf8.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var content = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasSuffix("```") { content.removeLast(3) }
        var bytes = [UInt8]()
        var closers = [UInt8]()
        var inString = false
        var escaped = false
        var trailingComma: Int?
        for byte in content.utf8 {
            if inString {
                bytes.append(byte)
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                bytes.append(byte)
                continue
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): closers.append(UInt8(ascii: "}"))
            case UInt8(ascii: "["): closers.append(UInt8(ascii: "]"))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard closers.popLast() == byte else { return nil }
                if let trailingComma { bytes[trailingComma] = 0x20 }
            case UInt8(ascii: ","):
                // An empty collection or a doubled comma is still invalid JSON.
                guard let previous = bytes.last(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }),
                      ![UInt8(ascii: "{"), UInt8(ascii: "["), UInt8(ascii: ",")].contains(previous) else { return nil }
                trailingComma = bytes.count
                bytes.append(byte)
                continue
            default: break
            }
            trailingComma = nil
            bytes.append(byte)
            if closers.isEmpty { return Data(bytes) }
        }
        guard !inString, closers == [UInt8(ascii: "}")] else { return nil }
        if let trailingComma { bytes[trailingComma] = 0x20 }
        bytes.append(UInt8(ascii: "}"))
        return Data(bytes)
    }
}
