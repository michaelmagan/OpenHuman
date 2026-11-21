import Foundation
import GRDB

enum Labels {
    static func join(_ set: Set<String>) -> String { set.sorted().joined(separator: ",") }
    static func split(_ text: String) -> Set<String> { Set(text.split(separator: ",").map(String.init)) }
}

struct WireAddress: Codable, Equatable {
    var n: String?
    var e: String
    static func decode(_ text: String) -> [WireAddress] {
        guard text != "[]", let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WireAddress].self, from: data)) ?? []
    }
    static func encode(_ list: [WireAddress]) -> String {
        guard !list.isEmpty else { return "[]" }
        return (try? StoreJSON.encoder.encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

enum StoreJSON {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

struct WirePerson: Codable { var n: String?; var e: String; var me: Int; var u: Int }
struct WireSendAs: Codable { var email: String }

enum HTMLEntities {
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "&", let semi = text[i...].prefix(10).firstIndex(of: ";") {
                let body = text[text.index(after: i)..<semi]
                var replacement: String?
                switch body {
                case "amp": replacement = "&"
                case "lt": replacement = "<"
                case "gt": replacement = ">"
                case "quot": replacement = "\""
                case "apos": replacement = "'"
                case "nbsp": replacement = "\u{00A0}"
                default:
                    if body.hasPrefix("#x") || body.hasPrefix("#X"), let v = UInt32(body.dropFirst(2), radix: 16),
                       let s = Unicode.Scalar(v) { replacement = String(s) }
                    else if body.hasPrefix("#"), let v = UInt32(body.dropFirst()), let s = Unicode.Scalar(v) {
                        replacement = String(s)
                    }
                }
                if let replacement {
                    out += replacement
                    i = text.index(after: semi)
                    continue
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }
}

extension Database {
    // Only for SQL with a bounded set of texts, never `IN (?, ?, ...)`, or the statement cache grows without bound
    func cached(_ sql: String) throws -> Statement { try cachedStatement(sql: sql) }
}
