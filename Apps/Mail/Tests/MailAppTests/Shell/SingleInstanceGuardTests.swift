import Foundation
import Testing
@testable import OpenHumanMail

@MainActor
struct SingleInstanceGuardTests {
    private func instance(_ pid: Int32 = 20, path: String? = "/Applications/OpenHuman Mail.app",
                          version: String? = "1.4", build: String? = "1208", terminated: Bool = false) -> RunningInstance {
        RunningInstance(pid: pid, bundleURL: path.map { URL(fileURLWithPath: $0) },
                        version: version, build: build, isTerminated: terminated)
    }

    @Test func exemptions() {
        func exempt(_ id: String? = "dev.openhuman.mail", arguments: [String] = [],
                    environment: [String: String] = [:], developerBuild: Bool = false) -> Bool {
            SingleInstanceGuard.isExempt(bundleIdentifier: id, arguments: arguments,
                                         environment: environment, developerBuild: developerBuild)
        }
        #expect(exempt(nil))
        #expect(exempt(""))
        #expect(exempt(environment: ["XCTestConfigurationFilePath": ""]))
        for argument in ["-UseFakeData", "-UseFixtureStore", "-UseFakeGmail", "-UseFakeCalendar"] {
            #expect(exempt(arguments: [argument]))
        }
        #expect(exempt(environment: ["OPENHUMAN_HOME": "/tmp/mail"]))
        #expect(exempt(developerBuild: true))
        #expect(!exempt())
        #expect(!exempt(environment: ["OPENHUMAN_HOME": ""]))
    }

    @Test func decisions() {
        let own = instance(100)
        let same = instance()
        #expect(SingleInstanceGuard.decide(own: own, others: []) == .launch)
        #expect(SingleInstanceGuard.decide(own: own, others: [own]) == .launch)
        #expect(SingleInstanceGuard.decide(own: own, others: [instance(terminated: true)]) == .launch)
        #expect(SingleInstanceGuard.decide(own: own, others: [same]) == .switchToOpenCopy(same))
        let standardized = instance(path: "/Applications/Temporary/../OpenHuman Mail.app")
        #expect(SingleInstanceGuard.decide(own: own, others: [standardized]) == .switchToOpenCopy(standardized))
        let different = [instance(version: "1.3"), instance(build: "1207"),
                         instance(path: "/Users/example/Downloads/OpenHuman Mail.app"),
                         instance(path: "/Volumes/Mail/OpenHuman Mail.app"),
                         instance(path: nil), instance(version: nil), instance(build: nil)]
        for other in different {
            #expect(SingleInstanceGuard.decide(own: own, others: [other]) == .askUser(other))
        }
        let disk = instance(100, path: "/Volumes/Mail/OpenHuman Mail.app")
        let diskOther = instance(path: "/Volumes/Mail/OpenHuman Mail.app")
        #expect(SingleInstanceGuard.decide(own: disk, others: [diskOther]) == .askUser(diskOther))
        #expect(SingleInstanceGuard.decide(own: disk, others: [same]) == .askUser(same))
        #expect(SingleInstanceGuard.decide(own: own, others: [own, instance(30), same]) == .switchToOpenCopy(same))
        #expect(SingleInstanceGuard.isOnDiskImage(disk.bundleURL))
        #expect(!SingleInstanceGuard.isOnDiskImage(nil))
        #expect(!SingleInstanceGuard.isOnDiskImage(URL(fileURLWithPath: "/VolumesElsewhere/Mail.app")))
    }

    @Test func launchAndSwitch() {
        let own = instance(100)
        let empty = FakeInstanceHost(instances: [own])
        #expect(SingleInstanceGuard.run(own: own, host: empty) == .continueLaunch)
        #expect(empty.calls.isEmpty)
        let other = instance()
        let same = FakeInstanceHost(instances: [other])
        #expect(SingleInstanceGuard.run(own: own, host: same) == .quitThisCopy)
        #expect(same.calls == [.activate(other.pid)])
        let different = instance(version: "1.3")
        let ask = FakeInstanceHost(instances: [different])
        #expect(SingleInstanceGuard.run(own: own, host: ask) == .quitThisCopy)
        #expect(ask.calls == [.choose(different.pid), .activate(different.pid)])
    }

    @Test func otherQuitsAfterTwoPolls() {
        let other = instance(version: "1.3")
        let host = FakeInstanceHost(instances: [other], choice: .quitOtherAndContinue, runningPolls: 2)
        #expect(SingleInstanceGuard.run(own: instance(100), host: host, pollInterval: 0.1) == .continueLaunch)
        #expect(host.calls == [.choose(20), .terminate(20), .poll(20), .pause(0.1),
                               .poll(20), .pause(0.1), .poll(20)])
        #expect(host.paused == 0.2)
    }

    @Test func otherRefusesToQuit() {
        let host = FakeInstanceHost(instances: [instance(version: "1.3")], choice: .quitOtherAndContinue)
        #expect(SingleInstanceGuard.run(own: instance(100), host: host,
                                        terminationWait: 0.5, pollInterval: 0.25) == .quitThisCopy)
        #expect(host.calls == [.choose(20), .terminate(20), .poll(20), .pause(0.25),
                               .poll(20), .pause(0.25), .poll(20), .activate(20)])
        #expect(host.paused == 0.5)
    }

    @Test func terminationRequestFails() {
        let host = FakeInstanceHost(instances: [instance(version: "1.3")], choice: .quitOtherAndContinue,
                                    terminationAccepted: false)
        #expect(SingleInstanceGuard.run(own: instance(100), host: host) == .quitThisCopy)
        #expect(host.calls == [.choose(20), .terminate(20), .activate(20)])
        #expect(host.paused == 0)
    }

    @Test func textKeepsPathsPrivate() {
        #expect(SingleInstanceGuard.alertTitle == "OpenHuman Mail is already open")
        #expect(SingleInstanceGuard.switchButtonTitle == "Switch to the Open Copy")
        #expect(SingleInstanceGuard.quitOtherButtonTitle == "Quit the Other Copy and Continue")
        let path = "/Users/someone/a/very/long/path/Downloads/OpenHuman Mail.app"
        let text = SingleInstanceGuard.informativeText(for: instance(path: path))
        #expect(text == "Version 1.4 (1208) is running from \"OpenHuman Mail.app\" in the folder \"Downloads\". Two copies cannot use the same mail at once.")
        #expect(!text.contains(path) && !text.contains("/Users"))
        #expect(SingleInstanceGuard.informativeText(for: instance()).contains("in Applications."))
        let diskText = SingleInstanceGuard.informativeText(for: instance(path: "/Volumes/PrivateVolume/OpenHuman Mail.app"))
        #expect(diskText.contains("disk image") && !diskText.contains("PrivateVolume"))
        let unknown = SingleInstanceGuard.informativeText(for: instance(path: nil, version: nil, build: nil))
        #expect(unknown == "Another version of OpenHuman Mail is running. Two copies cannot use the same mail at once.")
    }
}

@MainActor
private final class FakeInstanceHost: InstanceHost {
    enum Call: Equatable {
        case activate(Int32), terminate(Int32), poll(Int32), choose(Int32), pause(TimeInterval)
    }

    var instances: [RunningInstance]
    var choice: SingleInstanceChoice
    var terminationAccepted: Bool
    var runningPolls: Int?
    var calls: [Call] = []
    var paused: TimeInterval = 0

    init(instances: [RunningInstance], choice: SingleInstanceChoice = .switchToOpenCopy,
         terminationAccepted: Bool = true, runningPolls: Int? = nil) {
        self.instances = instances
        self.choice = choice
        self.terminationAccepted = terminationAccepted
        self.runningPolls = runningPolls
    }

    func runningInstances() -> [RunningInstance] { instances }

    func activate(_ instance: RunningInstance) -> Bool {
        calls.append(.activate(instance.pid))
        return true
    }

    func requestTermination(of instance: RunningInstance) -> Bool {
        calls.append(.terminate(instance.pid))
        return terminationAccepted
    }

    func isStillRunning(_ instance: RunningInstance) -> Bool {
        calls.append(.poll(instance.pid))
        guard let remaining = runningPolls else { return true }
        runningPolls = max(0, remaining - 1)
        return remaining > 0
    }

    func chooseAction(for other: RunningInstance) -> SingleInstanceChoice {
        calls.append(.choose(other.pid))
        return choice
    }

    func pause(_ seconds: TimeInterval) {
        calls.append(.pause(seconds))
        paused += seconds
    }
}
