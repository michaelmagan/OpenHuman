import Foundation

struct ThreadListHover: Equatable {
    private(set) var row: Int?
    private(set) var isScrolling = false

    @discardableResult
    mutating func pointer(over row: Int?) -> Bool {
        set(isScrolling ? nil : row)
    }

    @discardableResult
    mutating func pointerExited() -> Bool {
        set(nil)
    }

    @discardableResult
    mutating func scrollBegan() -> Bool {
        isScrolling = true
        return set(nil)
    }

    @discardableResult
    mutating func scrollEnded(pointerOver row: Int?) -> Bool {
        isScrolling = false
        return set(row)
    }

    private mutating func set(_ next: Int?) -> Bool {
        guard next != row else { return false }
        row = next
        return true
    }
}
