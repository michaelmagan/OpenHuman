import Foundation

// Why: the app links Sparkle and hands it in, so this package names only what the menu and Settings ask of it
@MainActor
public protocol SoftwareUpdater: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    func checkForUpdates()
}
