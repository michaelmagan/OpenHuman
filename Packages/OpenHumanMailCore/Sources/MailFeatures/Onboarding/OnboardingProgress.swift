import Foundation
import OpenHumanCore
import Synchronization

public enum OnboardingStep: String, Sendable, Hashable, Codable, CaseIterable {
    case welcome
    case calendar
    case inboxes = "secondAccount"
    case connectEmail
    case permissions, look, keys, ai, ready

    public var title: String {
        switch self {
        case .welcome: "Welcome to OpenHuman Mail"
        case .calendar: "Connect calendar"
        case .inboxes: "Your inboxes"
        case .connectEmail: "Connect another inbox"
        case .permissions: "Notifications and startup"
        case .look: "Choose a look"
        case .keys: "The keys that matter most"
        case .ai: "Draft replies with AI?"
        case .ready: "All set"
        }
    }

    public var isSkippable: Bool {
        switch self {
        case .welcome, .ready, .inboxes, .connectEmail: false
        case .calendar, .permissions, .look, .keys, .ai: true
        }
    }

    public var laterNote: String? {
        switch self {
        case .welcome, .ready, .inboxes, .connectEmail: nil
        case .calendar: "Connect it later in Settings › Calendar."
        case .permissions: "Change these later in System Settings and in Mail's Settings › Notifications and General."
        case .look: "Change the look any time in Settings › Appearance."
        case .keys: "Shortcuts are listed under Settings › Shortcuts, or press ? in Mail."
        case .ai: "Change this any time in Settings › AI."
        }
    }
}

public struct OnboardingProgress: Sendable, Hashable, Codable {
    public var step: OnboardingStep
    public var completed: Bool
    public var skipped: Set<OnboardingStep>
    public var aiAnswered: Bool
    public var shown: Bool
    public var setupAccount: AccountID?
    public var isOpen: Bool

    public init(step: OnboardingStep = .welcome, completed: Bool = false, skipped: Set<OnboardingStep> = [],
                aiAnswered: Bool = false, shown: Bool = false, setupAccount: AccountID? = nil, isOpen: Bool = false) {
        self.step = step
        self.completed = completed
        self.skipped = skipped
        self.aiAnswered = aiAnswered
        self.shown = shown
        self.setupAccount = setupAccount
        self.isOpen = isOpen
    }

    private enum CodingKeys: String, CodingKey { case step, completed, skipped, aiAnswered, shown, setupAccount, isOpen }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = try c.decode(OnboardingStep.self, forKey: .step)
        completed = try c.decode(Bool.self, forKey: .completed)
        skipped = try c.decode(Set<OnboardingStep>.self, forKey: .skipped)
        aiAnswered = try c.decode(Bool.self, forKey: .aiAnswered)
        shown = try c.decode(Bool.self, forKey: .shown)
        setupAccount = try c.decodeIfPresent(AccountID.self, forKey: .setupAccount)
        isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
    }
}

public protocol OnboardingProgressStoring: Sendable {
    func load() -> OnboardingProgress
    func save(_ progress: OnboardingProgress)
}

public final class InMemoryOnboardingProgress: OnboardingProgressStoring, Sendable {
    private let value: Mutex<OnboardingProgress>
    public init(_ initial: OnboardingProgress = OnboardingProgress()) { value = Mutex(initial) }
    public func load() -> OnboardingProgress { value.withLock { $0 } }
    public func save(_ progress: OnboardingProgress) { value.withLock { $0 = progress } }
}

public struct UserDefaultsOnboardingProgress: OnboardingProgressStoring {
    public static let key = "onboarding.progress.v1"
    public let suite: String?

    public init(suite: String? = nil) { self.suite = suite }

    private var defaults: UserDefaults { suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    public func load() -> OnboardingProgress {
        guard let data = defaults.data(forKey: Self.key),
              let progress = try? JSONDecoder().decode(OnboardingProgress.self, from: data) else { return OnboardingProgress() }
        return progress
    }

    public func save(_ progress: OnboardingProgress) {
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: Self.key) }
    }
}
