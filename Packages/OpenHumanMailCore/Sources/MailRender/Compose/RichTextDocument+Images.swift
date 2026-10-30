import Foundation

extension RichTextDocument {
    public var inlineImageIDs: [String] {
        Self.imageIDs(blocks)
    }

    public func keepingImages(_ ids: Set<String>) -> RichTextDocument {
        RichTextDocument(blocks: Self.keeping(blocks, ids))
    }

    public func mappingImages(_ transform: (InlineImageRef) -> InlineImageRef) -> RichTextDocument {
        RichTextDocument(blocks: Self.mapping(blocks, transform))
    }

    static func mapping(_ blocks: [Block], _ transform: (InlineImageRef) -> InlineImageRef) -> [Block] {
        blocks.map { block in
            switch block {
            case .paragraph:
                block
            case .list(let ordered, let items, let start):
                .list(ordered: ordered, items: items.map { mapping($0, transform) }, start: start)
            case .quote(let inner):
                .quote(mapping(inner, transform))
            case .image(let ref):
                .image(transform(ref))
            }
        }
    }

    static func imageIDs(_ blocks: [Block]) -> [String] {
        var ids: [String] = []
        for block in blocks {
            switch block {
            case .paragraph:
                continue
            case .list(_, let items, _):
                for item in items { ids += imageIDs(item) }
            case .quote(let inner):
                ids += imageIDs(inner)
            case .image(let ref):
                ids.append(ref.contentID)
            }
        }
        return ids
    }

    static func keeping(_ blocks: [Block], _ ids: Set<String>) -> [Block] {
        var out: [Block] = []
        for block in blocks {
            switch block {
            case .paragraph:
                out.append(block)
            case .list(let ordered, let items, let start):
                out.append(.list(ordered: ordered, items: items.map { keeping($0, ids) }, start: start))
            case .quote(let inner):
                out.append(.quote(keeping(inner, ids)))
            case .image(let ref):
                if ids.contains(ref.contentID) { out.append(block) }
            }
        }
        return out
    }
}
