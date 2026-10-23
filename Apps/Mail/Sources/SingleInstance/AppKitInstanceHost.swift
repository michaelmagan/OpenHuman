import AppKit

@MainActor
struct AppKitInstanceHost: InstanceHost {
    let bundleIdentifier: String

    static func snapshot(pid: Int32, bundleURL: URL?, bundle: Bundle?, isTerminated: Bool) -> RunningInstance {
        RunningInstance(pid: pid, bundleURL: bundleURL,
                        version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                        build: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                        isTerminated: isTerminated)
    }

    func runningInstances() -> [RunningInstance] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map {
            Self.snapshot(pid: $0.processIdentifier, bundleURL: $0.bundleURL,
                          bundle: $0.bundleURL.flatMap { Bundle(url: $0) }, isTerminated: $0.isTerminated)
        }
    }

    func activate(_ instance: RunningInstance) -> Bool {
        NSRunningApplication(processIdentifier: instance.pid)?.activate(from: .current, options: [.activateAllWindows]) ?? false
    }

    func requestTermination(of instance: RunningInstance) -> Bool {
        NSRunningApplication(processIdentifier: instance.pid)?.terminate() ?? false
    }

    func isStillRunning(_ instance: RunningInstance) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: instance.pid) else { return false }
        return !application.isTerminated
    }

    func chooseAction(for other: RunningInstance) -> SingleInstanceChoice {
        let application = NSApplication.shared
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = SingleInstanceGuard.alertTitle
        alert.informativeText = SingleInstanceGuard.informativeText(for: other)
        alert.addButton(withTitle: SingleInstanceGuard.switchButtonTitle)
        alert.addButton(withTitle: SingleInstanceGuard.quitOtherButtonTitle)
        application.activate()
        return alert.runModal() == .alertSecondButtonReturn ? .quitOtherAndContinue : .switchToOpenCopy
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

extension SingleInstanceGuard {
    @MainActor
    static func checkAtLaunch() -> SingleInstanceOutcome {
        let process = ProcessInfo.processInfo
        let bundle = Bundle.main
        if isExempt(bundleIdentifier: bundle.bundleIdentifier, arguments: process.arguments, environment: process.environment) {
            return .continueLaunch
        }
        guard let bundleIdentifier = bundle.bundleIdentifier else { return .continueLaunch }
        let own = AppKitInstanceHost.snapshot(pid: process.processIdentifier, bundleURL: bundle.bundleURL,
                                              bundle: bundle, isTerminated: false)
        return run(own: own, host: AppKitInstanceHost(bundleIdentifier: bundleIdentifier))
    }
}
