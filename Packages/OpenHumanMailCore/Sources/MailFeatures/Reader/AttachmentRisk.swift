import Foundation

public enum AttachmentRisk: Sendable, Hashable {
    case runsCode
    case installer
    case diskImage
    case changesSettings
    case opensLocation

    static let extensions: [String: AttachmentRisk] = {
        var map: [String: AttachmentRisk] = [:]
        for ext in ["app", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "ksh", "tcsh", "scpt", "scptd",
                    "applescript", "workflow", "action", "jar", "prefpane", "saver", "kext", "osax"] {
            map[ext] = .runsCode
        }
        for ext in ["pkg", "mpkg"] { map[ext] = .installer }
        for ext in ["dmg", "iso", "img", "sparseimage", "sparsebundle", "cdr"] { map[ext] = .diskImage }
        map["mobileconfig"] = .changesSettings
        for ext in ["webloc", "fileloc", "inetloc", "afploc", "ftploc", "vncloc", "url"] { map[ext] = .opensLocation }
        return map
    }()

    public static func of(filename: String) -> AttachmentRisk? {
        let name = ReaderFormatting.safeFilename(filename).lowercased()
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : extensions[ext]
    }
}

extension ReaderFormatting {
    public struct AttachmentWarning: Sendable, Equatable {
        public let title: String
        public let message: String
    }

    public static func openWarning(filename: String, file: URL? = nil) -> AttachmentWarning? {
        let onDisk = file.flatMap { AttachmentRisk.of(filename: $0.lastPathComponent) }
        guard let risk = AttachmentRisk.of(filename: filename) ?? onDisk else { return nil }
        let what = switch risk {
        case .runsCode: "This file can run programs on your Mac."
        case .installer: "This file installs software on your Mac."
        case .diskImage: "This disk image can contain apps."
        case .changesSettings: "This file can change your Mac's settings."
        case .opensLocation: "This file opens a web address or another file."
        }
        return AttachmentWarning(title: "Open “\(safeFilename(filename))”?",
                                 message: what + " Open it only if you expected it.")
    }
}
