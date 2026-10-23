import CoreGraphics
import Foundation
import MailModel
import OpenHumanCore
import Synchronization

public struct ReaderPlace: Codable, Equatable, Sendable {
    public var expandedMessageIDs: [String]
    public var scrollAnchorMessageID: String?
    public var scrollOffset: Double

    public init(expandedMessageIDs: [String] = [], scrollAnchorMessageID: String? = nil, scrollOffset: Double = 0) {
        self.expandedMessageIDs = expandedMessageIDs
        self.scrollAnchorMessageID = scrollAnchorMessageID
        self.scrollOffset = scrollOffset
    }
}

public struct WindowPlace: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var displayID: UInt32?
    public var isFullScreen: Bool
    public var isZoomed: Bool

    public init(frame: CGRect, displayID: UInt32? = nil, isFullScreen: Bool = false, isZoomed: Bool = false) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.size.width
        height = frame.size.height
        self.displayID = displayID
        self.isFullScreen = isFullScreen
        self.isZoomed = isZoomed
    }

    public var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func validatedFrame(screens: [CGRect], minimumVisible: CGSize = CGSize(width: 120, height: 60)) -> CGRect? {
        guard let main = screens.first else { return nil }
        let saved = frame
        guard saved.width.isFinite, saved.height.isFinite, saved.origin.x.isFinite, saved.origin.y.isFinite,
              saved.width >= 1, saved.height >= 1 else { return nil }
        for screen in screens {
            let overlap = saved.intersection(screen)
            if !overlap.isNull, overlap.width >= minimumVisible.width, overlap.height >= minimumVisible.height {
                var corrected = saved
                corrected.size.width = min(corrected.width, screen.width)
                corrected.size.height = min(corrected.height, screen.height)
                if corrected.maxY > screen.maxY { corrected.origin.y = screen.maxY - corrected.height }
                return corrected
            }
        }
        var corrected = CGRect(origin: .zero, size: CGSize(width: min(saved.width, main.width),
                                                           height: min(saved.height, main.height)))
        corrected.origin = CGPoint(x: main.midX - corrected.width / 2, y: main.midY - corrected.height / 2)
        return corrected
    }
}

public struct PanelsPlace: Codable, Equatable, Sendable {
    public var checklistOpen: Bool
    public var checklistItemID: String?
    public var feedbackOpen: Bool
    public var feedbackText: String

    public init(checklistOpen: Bool = false, checklistItemID: String? = nil, feedbackOpen: Bool = false,
                feedbackText: String = "") {
        self.checklistOpen = checklistOpen
        self.checklistItemID = checklistItemID
        self.feedbackOpen = feedbackOpen
        self.feedbackText = feedbackText
    }

    public var isDefault: Bool { self == PanelsPlace() }
}

public struct AccountPlace: Codable, Equatable, Sendable {
    public var account: AccountID
    public var location: MailLocation
    public var cursor: ThreadKey?
    public var cursorFallback: ThreadKey?
    public var checked: [ThreadKey]
    public var scrollTop: ThreadKey?
    public var scrollOffset: Double
    public var openThread: ThreadKey?
    public var reader: ReaderPlace?
    public var searchText: String
    public var searchOpen: Bool

    public init(account: AccountID, location: MailLocation, cursor: ThreadKey? = nil, scrollTop: ThreadKey? = nil,
                openThread: ThreadKey? = nil, cursorFallback: ThreadKey? = nil, checked: [ThreadKey] = [],
                scrollOffset: Double = 0, reader: ReaderPlace? = nil, searchText: String = "", searchOpen: Bool = false) {
        self.account = account
        self.location = location
        self.cursor = cursor
        self.cursorFallback = cursorFallback
        self.checked = checked
        self.scrollTop = scrollTop
        self.scrollOffset = scrollOffset
        self.openThread = openThread
        self.reader = reader
        self.searchText = searchText
        self.searchOpen = searchOpen
    }

    private enum CodingKeys: String, CodingKey {
        case account, location, cursor, cursorFallback, checked, scrollTop, scrollOffset, openThread, reader
        case searchText, searchOpen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(AccountID.self, forKey: .account)
        location = try c.decode(MailLocation.self, forKey: .location)
        cursor = try c.decodeIfPresent(ThreadKey.self, forKey: .cursor)
        cursorFallback = try c.decodeIfPresent(ThreadKey.self, forKey: .cursorFallback)
        checked = try c.decodeIfPresent([ThreadKey].self, forKey: .checked) ?? []
        scrollTop = try c.decodeIfPresent(ThreadKey.self, forKey: .scrollTop)
        scrollOffset = try c.decodeIfPresent(Double.self, forKey: .scrollOffset) ?? 0
        openThread = try c.decodeIfPresent(ThreadKey.self, forKey: .openThread)
        reader = try c.decodeIfPresent(ReaderPlace.self, forKey: .reader)
        searchText = try c.decodeIfPresent(String.self, forKey: .searchText) ?? ""
        searchOpen = try c.decodeIfPresent(Bool.self, forKey: .searchOpen) ?? false
    }

    public static func isRestorable(_ location: MailLocation) -> Bool {
        switch location {
        case .search, .reviewQueue(.some): false
        default: true
        }
    }
}

public struct NavigationSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var activeAccount: AccountID?
    public var labelSidebarVisible: Bool
    public var places: [AccountPlace]
    public var window: WindowPlace?
    public var panels: PanelsPlace?
    public var openDraftIDs: [String]

    public init(activeAccount: AccountID?, labelSidebarVisible: Bool = true, places: [AccountPlace] = [],
                window: WindowPlace? = nil, panels: PanelsPlace? = nil, openDraftIDs: [String] = []) {
        self.version = Self.currentVersion
        self.activeAccount = activeAccount
        self.labelSidebarVisible = labelSidebarVisible
        self.places = places
        self.window = window
        self.panels = panels
        self.openDraftIDs = openDraftIDs
    }

    private enum CodingKeys: String, CodingKey {
        case version, activeAccount, labelSidebarVisible, places, window, panels, openDraftIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        activeAccount = try c.decodeIfPresent(AccountID.self, forKey: .activeAccount)
        labelSidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .labelSidebarVisible) ?? true
        places = try c.decodeIfPresent([AccountPlace].self, forKey: .places) ?? []
        window = try c.decodeIfPresent(WindowPlace.self, forKey: .window)
        panels = try c.decodeIfPresent(PanelsPlace.self, forKey: .panels)
        openDraftIDs = try c.decodeIfPresent([String].self, forKey: .openDraftIDs) ?? []
    }

    public func place(for account: AccountID) -> AccountPlace? { places.first { $0.account == account } }

    public static func decode(_ data: Data) -> NavigationSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(NavigationSnapshot.self, from: data),
              (1...currentVersion).contains(snapshot.version) else { return nil }
        return snapshot
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

public protocol NavigationStateStoring: Sendable {
    func load() -> NavigationSnapshot?
    func save(_ snapshot: NavigationSnapshot)
}

public final class InMemoryNavigationStore: NavigationStateStoring {
    private let value: Mutex<NavigationSnapshot?>
    private let saves = Mutex(0)

    public init(_ snapshot: NavigationSnapshot? = nil) { value = Mutex(snapshot) }

    public func load() -> NavigationSnapshot? { value.withLock { $0 } }
    public func save(_ snapshot: NavigationSnapshot) {
        value.withLock { $0 = snapshot }
        saves.withLock { $0 += 1 }
    }
    public var saveCount: Int { saves.withLock { $0 } }
}

public struct FileNavigationStore: NavigationStateStoring {
    public let url: URL
    private let legacy: (any NavigationStateStoring)?

    public init(directory: URL, scope: String, legacy: (any NavigationStateStoring)? = nil) {
        self.url = directory.appendingPathComponent("navigation.\(scope).json")
        self.legacy = legacy
    }

    public func load() -> NavigationSnapshot? {
        if let data = try? Data(contentsOf: url) { return NavigationSnapshot.decode(data) }
        return legacy?.load()
    }

    public func save(_ snapshot: NavigationSnapshot) {
        guard let data = snapshot.encoded() else { return }
        Self.writeAtomically(data, to: url)
    }

    @discardableResult
    static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        var ok = true
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 { if errno == EINTR { continue }; ok = false; return }
                offset += written
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        if ok { ok = rename(temp.path, url.path) == 0 }
        if !ok { unlink(temp.path) }
        return ok
    }
}

public struct UserDefaultsNavigationStore: NavigationStateStoring {
    public static func key(scope: String) -> String { "dev.openhuman.mail.navigation.\(scope)" }

    public let key: String
    private let suiteName: String?

    public init(scope: String, suiteName: String? = nil) {
        self.key = Self.key(scope: scope)
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> NavigationSnapshot? {
        defaults.data(forKey: key).flatMap(NavigationSnapshot.decode)
    }

    public func save(_ snapshot: NavigationSnapshot) {
        guard let data = snapshot.encoded() else { return }
        defaults.set(data, forKey: key)
    }
}
