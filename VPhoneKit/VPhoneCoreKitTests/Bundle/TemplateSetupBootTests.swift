import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

// MARK: - Fake guest

/// A clock that only moves when the setup boot waits or the fake guest works.
private final class FakeClock: VPhoneTemplateSetupClock {
    var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        current
    }

    func sleep(_ seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

/// A scripted guest with the state the setup boot reads and changes: the
/// orig-fs snapshot, Setup, installed apps, the service profile and the boot.
private final class FakeGuest: VPhoneTemplateSetupMachine {
    let clock: FakeClock
    var calls: [String] = []
    var started = false
    var stopped = false
    var killed = false

    // Scripted behavior.
    var exitsAfterStart = false
    var connectDelayPolls = 2
    var snapshotBusyAnswers = 0
    var skipFailures = 0
    var unsettledAnswers = 1
    var refusedApps: Set<String> = []
    /// Apps vphoned had to unregister more than once, as it reports them.
    var unregisterAttempts: [String: Int] = [:]
    var servicesKeepRunning = false
    var rebootNeverReturns = false
    var stopsCleanly = true

    // Guest state.
    var snapshots = ["orig-fs.disabled.rn-4EC2"]
    var setupDone = false
    var installed: Set<String> = Set(VPhoneTemplateSlimmingRequest.defaultRemovedApps + [
        "com.apple.mobilephone", "com.apple.camera", "com.apple.Preferences",
    ])
    var profile = "none"
    var groups: [String] = []
    var disabled: Set<String> = []
    var running: [String] = []
    var bootTime = 1000.0
    var downCalls = 0
    var pinnedName: String? = "p4-src"

    init(clock: FakeClock) {
        self.clock = clock
    }

    func start() throws {
        started = true
    }

    func failure() -> String? {
        exitsAfterStart && started ? "vphone-vm exited with status 1" : nil
    }

    func ping() -> Bool {
        clock.sleep(0.1)
        if connectDelayPolls > 0 {
            connectDelayPolls -= 1
            return false
        }
        if downCalls > 0 {
            if !rebootNeverReturns {
                downCalls -= 1
            }
            return false
        }
        return true
    }

    private func refused(_ message: String, _ detail: [String: Any]) -> VPhoneGuestCallError {
        VPhoneGuestCallError(kind: .refused, message: message, detail: detail)
    }

    func call(_ method: String, params: [String: Any], timeout _: TimeInterval) throws -> [String: Any] {
        calls.append(method)
        clock.sleep(0.5)
        if downCalls > 0 {
            throw VPhoneGuestCallError(kind: .transport, message: "guest not connected")
        }
        switch method {
        case "apfs.snapshot.delete":
            if snapshotBusyAnswers > 0 {
                snapshotBusyAnswers -= 1
                throw refused("busy", ["code": "command_failed", "reason": "busy", "retryable": true, "errno": 16])
            }
            let deleted = snapshots
            snapshots = []
            return ["mount": "/", "before": deleted, "deleted": deleted, "already_deleted": [String](), "after": [String](), "remaining": [String]()]
        case "apfs.snapshots":
            return ["mount": "/", "snapshots": snapshots]
        case "setup.skip":
            #expect(params["force"] as? Bool == true)
            if skipFailures > 0 {
                skipFailures -= 1
                throw refused("Cannot allocate memory", ["code": "failed", "message": "Cannot allocate memory"])
            }
            setupDone = true
            return ["setup_done": true, "setup_version": 11]
        case "setup.settle":
            let wait = params["timeout_s"] as? Int ?? 90
            #expect(wait <= 110)
            if unsettledAnswers > 0 {
                unsettledAnswers -= 1
                clock.sleep(TimeInterval(wait))
                return ["settled": false, "reasons": ["staged_system_apps not empty"], "elapsed_s": wait]
            }
            return ["settled": true, "elapsed_s": 10.2, "reasons": [String]()]
        case "apps.remove_system":
            let ids = params["bundle_ids"] as? [String] ?? []
            var results: [[String: Any]] = []
            for id in ids {
                if refusedApps.contains(id) {
                    results.append(["bundle_id": id, "status": "failed", "removed": false, "error": "not in a bundle container"])
                } else if installed.remove(id) != nil {
                    var row: [String: Any] = ["bundle_id": id, "status": "removed", "removed": true]
                    row["unregister_attempts"] = unregisterAttempts[id]
                    results.append(row)
                } else {
                    results.append(["bundle_id": id, "status": "absent", "removed": false])
                }
            }
            let failed = results.count(where: { $0["status"] as? String == "failed" })
            if failed > 0 {
                throw refused("\(failed) of \(ids.count) apps were not removed; see results", [
                    "code": "command_failed", "error": "remove_incomplete", "results": results, "failed": failed,
                ])
            }
            return ["results": results, "removed": ids.count, "failed": 0]
        case "services.profile.apply":
            let wanted = params["profile"] as? String ?? ""
            profile = wanted
            if wanted == "trimmed" {
                groups = ["app_store", "base", "signin_followup"] + (params["groups"] as? [String] ?? [])
                let labels = ["com.apple.weatherd", "com.apple.followupd", "com.apple.appleidsetupd"]
                    + ((params["groups"] as? [String] ?? []).contains("accounts") ? ["com.apple.akd"] : [])
                disabled = Set(labels)
                running = ["com.apple.weatherd"]
            } else {
                groups = []
                disabled = []
                running = []
            }
            return ["profile": wanted, "disabled": Array(disabled), "enabled": [String](), "failed": [[String: Any]](), "owned": disabled.count]
        case "services.profile":
            let record: Any = profile == "none" ? NSNull() : ["profile": profile, "groups": groups, "labels": Array(disabled)]
            return ["profile": profile, "record": record, "disabled": Array(disabled), "running": running]
        case "processes.list":
            return ["processes": [["pid": 1, "start_time": bootTime], ["pid": 53, "start_time": bootTime + 4]], "count": 2]
        case "system.reboot":
            bootTime += 100
            downCalls = 3
            if !servicesKeepRunning {
                running = []
            }
            throw VPhoneGuestCallError(kind: .transport, message: "no answer from vphone.sock")
        case "setup.status":
            return ["setup_done": setupDone, "pending": !setupDone]
        case "apps.list":
            return ["apps": installed.map { ["bundle_id": $0] }]
        case "device.name.set":
            pinnedName = params["name"] as? String
            return ["name": NSNull(), "changed": true]
        default:
            throw refused("unknown method \(method)", ["code": "unknown_method"])
        }
    }

    func stop(timeout _: TimeInterval) -> Bool {
        stopped = true
        return stopsCleanly
    }

    func kill() {
        killed = true
    }
}

// MARK: - Tests

/// The setup boot as a state machine: step order, retries, deadlines and what
/// a failure leaves behind, against a scripted guest. No VM is started.
struct TemplateSetupBootTests {
    private func run(
        _ guest: FakeGuest,
        slimming: VPhoneMachineTemplateSlimming = VPhoneTemplateSlimmingRequest.defaultSlimming,
        requiresEveryApp: Bool = true,
    ) -> Result<VPhoneTemplateSetupOutcome, VPhoneTemplateSetupFailure> {
        let boot = VPhoneTemplateSetupBoot(
            machine: guest,
            plan: VPhoneTemplateSetupPlan(slimming: slimming, requiresEveryApp: requiresEveryApp),
            clock: guest.clock,
            log: { _ in },
        )
        do {
            return try .success(boot.run())
        } catch let failure as VPhoneTemplateSetupFailure {
            return .failure(failure)
        } catch {
            Issue.record("unexpected \(error)")
            return .failure(VPhoneTemplateSetupFailure(step: .boot, reason: "\(error)", outcome: .init()))
        }
    }

    /// Whether `expected` occurs in `calls` in this order (other calls may
    /// come in between).
    private func inOrder(_ calls: [String], _ expected: [String]) -> Bool {
        var index = calls.startIndex
        for method in expected {
            guard let found = calls[index...].firstIndex(of: method) else { return false }
            index = calls.index(after: found)
        }
        return true
    }

    @Test func `a full setup boot runs the steps in the fixed order and records the key's slimming`() throws {
        let guest = FakeGuest(clock: FakeClock())
        let outcome = try run(guest).get()

        #expect(inOrder(guest.calls, [
            "apfs.snapshot.delete", "setup.skip", "setup.settle", "setup.settle",
            "apps.remove_system", "services.profile.apply", "services.profile",
            "processes.list", "system.reboot", "processes.list",
            "apfs.snapshots", "setup.status", "services.profile", "apps.list",
            "device.name.set",
        ]))
        // Nothing slims before Setup is skipped and first-boot work settled.
        let firstRemoval = try #require(guest.calls.firstIndex(of: "apps.remove_system"))
        let lastSettle = try #require(guest.calls.lastIndex(of: "setup.settle"))
        #expect(lastSettle < firstRemoval)
        #expect(guest.calls.firstIndex(of: "apfs.snapshot.delete") == 0)

        #expect(outcome.isComplete)
        #expect(guest.stopped)
        #expect(!guest.killed)
        #expect(outcome.deletedSnapshots == ["orig-fs.disabled.rn-4EC2"])
        #expect(outcome.removedApps == VPhoneTemplateSlimmingRequest.defaultRemovedApps.sorted())
        #expect(guest.installed.contains("com.apple.mobilephone"))
        #expect(outcome.serviceProfile == "trimmed")
        #expect(outcome.deviceNameCleared)
        #expect(guest.pinnedName == nil)
        #expect(Set(outcome.durations.keys) == Set(VPhoneTemplateSetupStep.allCases))

        // The offline trim records its tier before the setup boot, which
        // leaves it alone.
        let trimmed = VPhoneMachineTemplateSteps(trimTier: VPhoneTemplateSlimmingRequest.defaultTrimTier)
        let steps = outcome.applying(to: trimmed)
        #expect(steps.trimTier == trimmed.trimTier)
        #expect(steps.setupDone)
        #expect(steps.snapshotDeleted)
        #expect(steps.slimming == VPhoneTemplateSlimmingRequest.defaultSlimming)
    }

    @Test func `slim off skips the setup but slims nothing`() throws {
        let guest = FakeGuest(clock: FakeClock())
        let slimming = try VPhoneTemplateSlimmingRequest(slim: false).resolve()
        let outcome = try run(guest, slimming: slimming).get()
        #expect(!guest.calls.contains("apps.remove_system"))
        #expect(!guest.calls.contains("services.profile.apply"))
        #expect(!guest.calls.contains("apps.list"))
        #expect(guest.calls.contains("setup.skip"))
        #expect(guest.calls.contains("apfs.snapshot.delete"))
        #expect(outcome.isComplete)
        #expect(outcome.applying(to: VPhoneMachineTemplateSteps()).slimming == slimming)
    }

    @Test func `accounts-off reaches the guest as an extra group`() throws {
        let guest = FakeGuest(clock: FakeClock())
        let slimming = try VPhoneTemplateSlimmingRequest(accountsOff: true).resolve()
        let outcome = try run(guest, slimming: slimming).get()
        #expect(guest.groups.contains("accounts"))
        #expect(outcome.applying(to: VPhoneMachineTemplateSteps(trimTier: slimming.trimTier)).slimming == slimming)
    }

    @Test func `a busy snapshot deletion is retried`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.snapshotBusyAnswers = 2
        let outcome = try run(guest).get()
        #expect(guest.calls.count(where: { $0 == "apfs.snapshot.delete" }) == 3)
        #expect(outcome.isComplete)
    }

    @Test func `setup skip that fails early in the boot is retried`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.skipFailures = 3
        let outcome = try run(guest).get()
        #expect(guest.calls.count(where: { $0 == "setup.skip" }) == 4)
        #expect(outcome.setupSkipped)
    }

    @Test func `setup skip that keeps failing fails its step`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.skipFailures = 1000
        let failure = try #require(run(guest).failed)
        #expect(failure.step == .skipSetup)
        #expect(failure.reason.contains("Cannot allocate memory"))
    }

    @Test func `no snapshot left is not an error`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.snapshots = []
        let outcome = try run(guest).get()
        #expect(outcome.deletedSnapshots.isEmpty)
        #expect(outcome.snapshotsGone)
    }

    @Test func `settle is called again until it settles, each call within 110 s`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.unsettledAnswers = 4
        let outcome = try run(guest).get()
        #expect(guest.calls.count(where: { $0 == "setup.settle" }) == 5)
        #expect(outcome.settled)
    }

    @Test func `settle that never settles fails at its deadline and kills the VM`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.unsettledAnswers = 1000
        let failure = try #require(run(guest).failed)
        #expect(failure.step == .settle)
        #expect(failure.reason.contains("staged_system_apps"))
        #expect(guest.killed)
        #expect(!guest.stopped)
        #expect(!failure.outcome.isComplete)
        #expect(!guest.calls.contains("apps.remove_system"))
        // Bounded: 600 s of 110 s calls.
        #expect(guest.calls.count(where: { $0 == "setup.settle" }) <= 7)
    }

    @Test func `a refused app fails a build whose key promises it`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.refusedApps = ["com.apple.findmy"]
        let failure = try #require(run(guest, requiresEveryApp: true).failed)
        #expect(failure.step == .removeApps)
        #expect(failure.reason.contains("com.apple.findmy"))
        #expect(guest.killed)
        #expect(failure.outcome.apps.count == 10)
        #expect(!guest.calls.contains("services.profile.apply"))
    }

    @Test func `a refused app is a warning for a machine to be adopted, and left out of its steps`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.refusedApps = ["com.apple.findmy"]
        let outcome = try run(guest, requiresEveryApp: false).get()
        #expect(outcome.isComplete)
        #expect(outcome.warnings.count == 1)
        #expect(!outcome.removedApps.contains("com.apple.findmy"))
        #expect(outcome.removedApps.count == 9)
        let steps = outcome.applying(to: VPhoneMachineTemplateSteps())
        #expect(steps.slimming != VPhoneTemplateSlimmingRequest.defaultSlimming)
    }

    @Test func `a strict setup boot of a machine fails where the lenient one warns`() throws {
        // vm template setup --strict: a machine Launchpad adopts under the
        // key vm template find gave must not lose an app from that key.
        let guest = FakeGuest(clock: FakeClock())
        guest.refusedApps = ["com.apple.findmy"]
        let failure = try #require(run(guest, requiresEveryApp: true).failed)
        #expect(failure.step == .removeApps)
        #expect(failure.reason.contains("com.apple.findmy"))
        // Nothing recorded: the outcome is incomplete.
        #expect(!failure.outcome.isComplete)
        #expect(!guest.calls.contains("system.reboot"))
    }

    @Test func `deviations name what fell short of the plan`() throws {
        let plan = VPhoneTemplateSetupPlan(slimming: VPhoneTemplateSlimmingRequest.defaultSlimming, requiresEveryApp: true)
        var outcome = VPhoneTemplateSetupOutcome()
        outcome.apps = plan.removedApps.map { VPhoneTemplateSetupAppResult(bundleID: $0, status: "removed") }
        outcome.serviceProfile = plan.serviceProfile
        outcome.serviceGroups = plan.serviceGroups
        #expect(outcome.deviations(from: plan).isEmpty)

        var short = outcome
        try short.apps[#require(short.apps.firstIndex { $0.bundleID == "com.apple.findmy" })] = VPhoneTemplateSetupAppResult(
            bundleID: "com.apple.findmy",
            status: "failed",
            error: "LaunchServices still lists the app after unregistration",
        )
        short.apps.removeAll { $0.bundleID == "com.apple.news" }
        let lines = short.deviations(from: plan)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("com.apple.findmy (LaunchServices still lists") == true)
        #expect(lines.first?.contains("com.apple.news") == true)

        var profile = outcome
        profile.serviceProfile = "none"
        profile.serviceGroups = ["accounts"]
        #expect(profile.deviations(from: plan) == ["service profile none, not trimmed", "service groups accounts, not "])
    }

    @Test func `an app that is already gone counts as removed`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.installed.remove("com.apple.news")
        let outcome = try run(guest).get()
        #expect(outcome.apps.first(where: { $0.bundleID == "com.apple.news" })?.status == "absent")
        #expect(outcome.removedApps.contains("com.apple.news"))
    }

    @Test func `apps unregistered after more than one attempt are logged and recorded`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.unregisterAttempts = ["com.apple.findmy": 3, "com.apple.tv": 2]
        var lines: [String] = []
        let boot = VPhoneTemplateSetupBoot(
            machine: guest,
            plan: VPhoneTemplateSetupPlan(slimming: VPhoneTemplateSlimmingRequest.defaultSlimming, requiresEveryApp: true),
            clock: guest.clock,
            log: { lines.append($0) },
        )
        let outcome = try boot.run()

        #expect(outcome.apps.first(where: { $0.bundleID == "com.apple.findmy" })?.unregisterAttempts == 3)
        #expect(outcome.apps.first(where: { $0.bundleID == "com.apple.news" })?.unregisterAttempts == 1)
        #expect(outcome.retriedUnregistrations == ["com.apple.findmy": 3, "com.apple.tv": 2])
        #expect(lines.contains("  com.apple.findmy: unregistered after 3 attempts"))
        #expect(lines.contains("  com.apple.tv: unregistered after 2 attempts"))
        #expect(!lines.contains { $0.contains("com.apple.news: unregistered") })
        // Recorded with the steps, outside the key.
        let steps = outcome.applying(to: VPhoneMachineTemplateSteps())
        #expect(steps.unregisterAttempts == ["com.apple.findmy": 3, "com.apple.tv": 2])
        var without = steps
        without.unregisterAttempts = [:]
        #expect(without.slimming == steps.slimming)
        let encoded = try PropertyListEncoder().encode(steps)
        #expect(try PropertyListDecoder().decode(VPhoneMachineTemplateSteps.self, from: encoded) == steps)
    }

    @Test func `a VM that exits fails the step it was in`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.exitsAfterStart = true
        let failure = try #require(run(guest).failed)
        #expect(failure.step == .connect)
        #expect(failure.reason.contains("exited"))
        #expect(guest.calls.isEmpty)
    }

    @Test func `vphoned that never answers fails the connect step`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.connectDelayPolls = Int.max
        let failure = try #require(run(guest).failed)
        #expect(failure.step == .connect)
        #expect(guest.killed)
    }

    @Test func `a reboot that never comes back fails the reboot step`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.rebootNeverReturns = true
        let failure = try #require(run(guest).failed)
        #expect(failure.step == .reboot)
        #expect(guest.killed)
    }

    @Test func `services still running after the reboot fail verification`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.servicesKeepRunning = true
        let failure = try #require(run(guest).failed)
        #expect(failure.step == .verify)
        #expect(failure.reason.contains("still running"))
        #expect(!failure.outcome.verified)
    }

    @Test func `an unclean shutdown fails the setup boot`() throws {
        let guest = FakeGuest(clock: FakeClock())
        guest.stopsCleanly = false
        let failure = try #require(run(guest).failed)
        #expect(failure.step == .stop)
        #expect(failure.outcome.verified)
        #expect(!failure.outcome.isComplete)
        #expect(!failure.outcome.applying(to: VPhoneMachineTemplateSteps()).setupDone)
    }

    @Test func `retryable means unreachable, busy or marked so`() {
        #expect(VPhoneGuestCallError(kind: .transport, message: "x").isRetryable)
        #expect(VPhoneGuestCallError(kind: .refused, message: "x", detail: ["retryable": true]).isRetryable)
        #expect(VPhoneGuestCallError(kind: .refused, message: "x", detail: ["reason": "busy"]).isRetryable)
        #expect(!VPhoneGuestCallError(kind: .refused, message: "x", detail: ["code": "invalid_operation"]).isRetryable)
        #expect(!VPhoneGuestCallError(kind: .refused, message: "x").isRetryable)
        #expect(VPhoneGuestCallError(kind: .refused, message: "x", detail: ["code": "c"]).code == "c")
    }

    @Test func `launchd's start time tells boots apart`() {
        #expect(VPhoneTemplateSetupBoot.bootMarker(["processes": [["pid": 1, "start_time": 12.5]]]) == 12.5)
        #expect(VPhoneTemplateSetupBoot.bootMarker(["processes": [["pid": 2, "start_time": 12.5]]]) == nil)
        #expect(VPhoneTemplateSetupBoot.bootMarker([:]) == nil)
    }
}

// MARK: - Recording

/// A setup boot's outcome in `Template.plist`: a complete one lets the build
/// freeze, a failed one is never recorded and the build stays unfrozen.
struct TemplateSetupRecordingTests {
    private func makeBuild(slimming: VPhoneMachineTemplateSlimming) throws -> (root: URL, build: VPhoneMachineTemplateBuild, lock: VPhoneMachineTemplateLock) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let library = VPhoneLibrary(root: root.appendingPathComponent("machines"))
        let key = MachineTemplateKeyTests.key(slimming: slimming)
        let lock = try VPhoneMachineTemplates.lock(key.identifier, in: library, wait: false)
        let build = try VPhoneMachineTemplates.beginBuild(key, in: library)
        let bundle = try VPhoneBundleOperations.create(
            .init(name: key.identifier, cpuCount: 4, memoryMB: 4096, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: build.library,
        )
        try Data([0xD1]).write(to: bundle.url.appendingPathComponent("Disk.img"))
        try VPhoneMachineTemplates.writeRecord(VPhoneMachineTemplateRecord(key: key, sourceMachine: "p4-a"), inBundle: build.bundleURL)
        return (root, build, lock)
    }

    private func outcome(complete: Bool) throws -> VPhoneTemplateSetupOutcome {
        let guest = FakeGuest(clock: FakeClock())
        guest.stopsCleanly = complete
        let boot = VPhoneTemplateSetupBoot(
            machine: guest,
            plan: VPhoneTemplateSetupPlan(slimming: VPhoneTemplateSlimmingRequest.defaultSlimming, requiresEveryApp: true),
            clock: guest.clock,
            log: { _ in },
        )
        do {
            return try boot.run()
        } catch let failure as VPhoneTemplateSetupFailure {
            return failure.outcome
        }
    }

    @Test func `a complete setup boot is recorded and the build freezes`() throws {
        let (root, build, lock) = try makeBuild(slimming: VPhoneTemplateSlimmingRequest.defaultSlimming)
        defer {
            lock.release()
            try? FileManager.default.removeItem(at: root)
        }
        // Before the setup boot the key's promise is not kept.
        #expect(throws: VPhoneMachineTemplateError.self) { try VPhoneMachineTemplates.freeze(build) }
        // The default trim runs first and records its tier; its snapshot is
        // still there, so the build still does not freeze.
        try VPhoneMachineTemplates.recordSteps(inBundle: build.bundleURL) {
            $0.trimTier = VPhoneTemplateSlimmingRequest.defaultTrimTier
        }
        #expect(throws: VPhoneMachineTemplateError.self) { try VPhoneMachineTemplates.freeze(build) }

        try VPhoneMachineTemplates.recordSetupBoot(outcome(complete: true), inBundle: build.bundleURL)
        let record = try #require(try VPhoneMachineTemplates.readRecord(inBundle: build.bundleURL))
        #expect(record.steps.setupDone)
        #expect(record.steps.snapshotDeleted)
        #expect(record.steps.serviceProfile == "trimmed")
        #expect(record.steps.removedApps.count == 10)
        #expect(record.steps.trimTier == VPhoneTemplateSlimmingRequest.defaultTrimTier)

        let template = try VPhoneMachineTemplates.freeze(build)
        #expect(template.record.frozen)
        #expect(template.record.steps.slimming == template.key.slimming)
    }

    @Test func `a failed setup boot records nothing and the build never freezes`() throws {
        let (root, build, lock) = try makeBuild(slimming: VPhoneTemplateSlimmingRequest.defaultSlimming)
        defer {
            lock.release()
            try? FileManager.default.removeItem(at: root)
        }
        let failed = try outcome(complete: false)
        #expect(!failed.isComplete)
        #expect(throws: VPhoneMachineTemplateError.self) {
            try VPhoneMachineTemplates.recordSetupBoot(failed, inBundle: build.bundleURL)
        }
        let record = try #require(try VPhoneMachineTemplates.readRecord(inBundle: build.bundleURL))
        #expect(record.steps == VPhoneMachineTemplateSteps())
        #expect(throws: VPhoneMachineTemplateError.self) { try VPhoneMachineTemplates.freeze(build) }
        #expect(try VPhoneMachineTemplates.readRecord(inBundle: build.bundleURL)?.frozen == false)
    }

    @Test func `a file trim recorded before the setup boot survives it`() throws {
        var slimming = VPhoneTemplateSlimmingRequest.defaultSlimming
        slimming.trimTier = "conservative/1"
        let (root, build, lock) = try makeBuild(slimming: slimming)
        defer {
            lock.release()
            try? FileManager.default.removeItem(at: root)
        }
        try VPhoneMachineTemplates.recordSteps(inBundle: build.bundleURL) { $0.trimTier = "conservative/1" }
        try VPhoneMachineTemplates.recordSetupBoot(outcome(complete: true), inBundle: build.bundleURL)
        #expect(try VPhoneMachineTemplates.freeze(build).record.steps.trimTier == "conservative/1")
    }
}

// MARK: - Socket paths

/// A machine in a template build lives deeper than `sun_path` reaches; its
/// control socket is bound and reached through a short link.
struct UnixSocketLongPathTests {
    @Test func `a socket path longer than sun_path is bound and connected through a link`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(".templates-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".building-0123456789ab-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("0123456789ab", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let path = root.appendingPathComponent("vphone.sock").path
        #expect(path.utf8CString.count > VPhoneUnixSocket.maximumPathLength)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { close(listener) }
        let bound = VPhoneUnixSocket.withAddressablePath(path) { short -> Int32 in
            #expect(short.utf8CString.count <= VPhoneUnixSocket.maximumPathLength)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in short.utf8CString.enumerated() {
                    buffer[index] = UInt8(bitPattern: byte)
                }
            }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        // The socket is where the long path says.
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK)

        switch VPhoneUnixSocket.connect(to: path) {
        case let .success(fd):
            close(fd)
        case let .failure(error):
            Issue.record("connect failed: \(error)")
        }
        // A short path is used as it is.
        #expect(VPhoneUnixSocket.withAddressablePath("/tmp/x.sock") { $0 } == "/tmp/x.sock")
    }
}

private extension Result {
    var failed: Failure? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}
