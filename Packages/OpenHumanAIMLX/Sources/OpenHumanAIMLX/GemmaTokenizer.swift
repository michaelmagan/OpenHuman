import Foundation

/// Text-only tokenizer for the pinned Gemma 4 BPE vocabulary and system/user template.
public struct GemmaTokenizer: Sendable {
    private struct Pair: Hashable { let left: Int, right: Int }
    private struct Merge: Sendable { let rank: Int, token: Int }
    private let vocabulary: [Data: Int]
    private let pieces: [Int: String]
    private let merges: [Pair: Merge]
    private let byteIDs: [Int]
    private let bytesByID: [Int: UInt8]
    private let special: Set<Int>
    private let bos: Int, turn: Int, end: Int

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct Vocabulary: Decodable {
        var ids = [Data: Int]()
        var strings = [Int: String]()

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            for key in values.allKeys {
                guard let bytes = Data(base64Encoded: key.stringValue) else {
                    throw ByteLevelBPETokenizer.LoadError.unreadable
                }
                let id = try values.decode(Int.self, forKey: key)
                ids[bytes] = id
                strings[id] = String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    private struct File: Decodable {
        struct Model: Decodable { let vocab: Vocabulary, merges: [[String]] }
        struct Added: Decodable { let id: Int }
        let model: Model
        let added_tokens: [Added]
    }

    public init(data: Data) throws {
        let invalid = ByteLevelBPETokenizer.LoadError.unreadable
        let decoder = JSONDecoder()
        // Swift String equality folds canonically equivalent vocabulary keys.
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last!
            guard path.dropLast().last?.stringValue == "vocab" else { return key }
            return Key(stringValue: Data(key.stringValue.utf8).base64EncodedString())
        }
        let file = try decoder.decode(File.self, from: data)
        let ids = file.model.vocab.ids, strings = file.model.vocab.strings
        let specials = Set(file.added_tokens.map(\.id))
        let pairs = file.model.merges
        var ranks = [Pair: Merge]()
        for (rank, pair) in pairs.enumerated() {
            guard pair.count == 2, let left = ids[Data(pair[0].utf8)], let right = ids[Data(pair[1].utf8)],
                  let token = ids[Data((pair[0] + pair[1]).utf8)] else { throw invalid }
            if !specials.contains(token) { ranks[Pair(left: left, right: right)] = Merge(rank: rank, token: token) }
        }
        let bytes = try (0..<256).map { n in
            guard let id = ids[Data(String(format: "<0x%02X>", n).utf8)] else { throw invalid }
            return id
        }
        guard let bos = ids[Data("<bos>".utf8)], let turn = ids[Data("<|turn>".utf8)],
              let end = ids[Data("<turn|>".utf8)] else { throw invalid }
        self.bos = bos
        self.turn = turn
        self.end = end
        vocabulary = ids
        pieces = strings
        merges = ranks
        special = specials
        byteIDs = bytes
        bytesByID = Dictionary(uniqueKeysWithValues: bytes.enumerated().map { ($1, UInt8($0)) })
    }

    public func id(for text: String) -> Int? { vocabulary[Data(text.utf8)] }
    public func piece(for id: Int) -> String? { pieces[id] }

    public func encode(_ text: String) -> [Int] {
        var ids = [Int]()
        for scalar in text.unicodeScalars {
            let piece = scalar == " " ? "▁" : String(scalar)
            if let id = id(for: piece), !special.contains(id) {
                ids.append(id)
            } else {
                ids.append(contentsOf: piece.utf8.map { byteIDs[Int($0)] })
            }
        }
        guard ids.count > 1 else { return ids }
        // The lowest ranked adjacent pair merges first. Ties merge from the left.
        var next = Array(1...ids.count), previous = ids.indices.map { $0 - 1 }
        var queue = MergeQueue()
        func enqueue(_ left: Int) {
            guard left >= 0, next[left] < ids.count else { return }
            let right = next[left]
            if let merge = merges[Pair(left: ids[left], right: ids[right])] {
                queue.insert(.init(rank: merge.rank, left: left, right: right, token: merge.token))
            }
        }
        for index in ids.indices { enqueue(index) }
        while let entry = queue.pop() {
            let left = entry.left, right = entry.right
            guard next[left] == right, ids[left] >= 0, ids[right] >= 0,
                  merges[Pair(left: ids[left], right: ids[right])]?.rank == entry.rank else { continue }
            ids[left] = entry.token
            ids[right] = -1
            next[left] = next[right]
            if next[left] < ids.count { previous[next[left]] = left }
            enqueue(previous[left])
            enqueue(left)
        }
        return ids.filter { $0 >= 0 }
    }

    public func decode(_ ids: [Int], skipSpecial: Bool) -> String {
        var bytes = [UInt8]()
        for id in ids where !(skipSpecial && special.contains(id)) {
            if let byte = bytesByID[id] { bytes.append(byte) }
            else if let piece = pieces[id] {
                bytes.append(contentsOf: piece.replacingOccurrences(of: "▁", with: " ").utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func chat(system: String, user: String) -> [Int] {
        var ids = [bos]
        for (role, text) in [("system", system), ("user", user)] {
            ids.append(turn)
            ids += encode(role + "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines))
            ids.append(end)
            ids += encode("\n")
        }
        ids.append(turn)
        return ids + encode("model\n")
    }
}

private struct MergeQueue {
    struct Entry: Comparable {
        let rank: Int, left: Int, right: Int, token: Int
        static func < (lhs: Self, rhs: Self) -> Bool { (lhs.rank, lhs.left) < (rhs.rank, rhs.left) }
    }

    private var entries = [Entry]()

    mutating func insert(_ entry: Entry) {
        var index = entries.count
        entries.append(entry)
        while index > 0 {
            let parent = (index - 1) / 2
            guard entry < entries[parent] else { break }
            entries[index] = entries[parent]
            index = parent
        }
        entries[index] = entry
    }

    mutating func pop() -> Entry? {
        guard let first = entries.first else { return nil }
        let last = entries.removeLast()
        guard !entries.isEmpty else { return first }
        var index = 0
        while index * 2 + 1 < entries.count {
            var child = index * 2 + 1
            if child + 1 < entries.count, entries[child + 1] < entries[child] { child += 1 }
            guard entries[child] < last else { break }
            entries[index] = entries[child]
            index = child
        }
        entries[index] = last
        return first
    }
}
