import ArgumentParser
import Foundation
import VPhoneCoreKit

// MARK: - Command group

struct VPhoneVirtualMachineTemplateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "template",
        abstract: "Manage machine templates (vm create clones new machines from them)",
        discussion: """
        A template is a complete machine that never boots, kept in <library>/.templates/<id>. \
        vm create clones a new machine from the template whose key matches what it was asked \
        for, with a new identity, in a fraction of a second and almost no disk space: the clone \
        shares every block it does not change with the template. The key is the guest device, \
        the iOS and cloudOS builds, the patch preset and the boot-chain patches it resolves to, \
        the bundle series, the disk size and what was trimmed. CPU, memory, screen and network \
        are not part of it; they are set on each clone.

        Every machine cloned from one template shares its SEP root secret and the keys of its \
        Data volume. Create a machine with --no-template when it needs keys of its own.

        A template is never listed by vm list and cannot be booted: a boot would write state \
        every later clone inherits.
        """,
        subcommands: [
            VPhoneVirtualMachineTemplateListCommand.self,
            VPhoneVirtualMachineTemplateShowCommand.self,
            VPhoneVirtualMachineTemplateAdoptCommand.self,
            VPhoneVirtualMachineTemplateDeleteCommand.self,
        ],
    )
}

// MARK: - Report

/// One template as `list --json` and `show --json` print it.
struct VPhoneMachineTemplateReport: Encodable {
    var id: String
    var path: String
    var key: VPhoneMachineTemplateKey
    var created: Date
    var builtWithBundleVersion: String?
    var bootChainBundleVersion: String?
    var sourceMachine: String?
    var steps: VPhoneMachineTemplateSteps
    var diskSizeBytes: Int64
    var stale: Bool
    var staleReasons: [String]

    init(_ template: VPhoneMachineTemplate) {
        let record = template.record
        id = record.identifier
        path = template.url.path
        key = record.key
        created = record.created
        builtWithBundleVersion = record.builtWithBundleVersion
        bootChainBundleVersion = record.bootChainBundleVersion
        sourceMachine = record.sourceMachine
        steps = record.steps
        diskSizeBytes = (try? template.bundle().diskSizeBytes) ?? 0
        staleReasons = VPhoneMachineTemplateKeys.staleReasons(template)
        stale = !staleReasons.isEmpty
    }
}

struct VPhoneMachineTemplateStagingReport: Encodable {
    var name: String
    var path: String
    var id: String?
    var active: Bool
}

struct VPhoneMachineTemplateListReport: Encodable {
    var templates: [VPhoneMachineTemplateReport]
    var building: [VPhoneMachineTemplateStagingReport]
    var damaged: [[String: String]]
}

private func encodeJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try String(decoding: encoder.encode(value), as: UTF8.self)
}

// MARK: - list

struct VPhoneVirtualMachineTemplateListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List templates")

    @OptionGroup var lib: VPhoneLibraryOption
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let listing = try VPhoneMachineTemplates.list(in: lib.library)
        let reports = listing.templates.map(VPhoneMachineTemplateReport.init)
        if json {
            try print(encodeJSON(VPhoneMachineTemplateListReport(
                templates: reports,
                building: listing.staging.map {
                    VPhoneMachineTemplateStagingReport(name: $0.name, path: $0.url.path, id: $0.identifier, active: $0.isActive)
                },
                damaged: listing.damaged.map { ["name": $0.name, "reason": $0.reason] },
            )))
            return
        }
        if reports.isEmpty, listing.staging.isEmpty, listing.damaged.isEmpty {
            print("No templates in \(VPhoneMachineTemplates.directory(in: lib.library).path).")
            return
        }
        for report in reports {
            let state = report.stale ? "  STALE" : ""
            print("\(report.id)  \(report.key.summary)\(state)")
            for reason in report.staleReasons {
                print("    stale: \(reason)")
            }
        }
        for staging in listing.staging {
            print("\(staging.name)  \(staging.isActive ? "building" : "unfinished; vm template delete \(staging.name) removes it")")
        }
        for skip in listing.damaged {
            print("\(skip.name)  damaged: \(skip.reason)")
        }
    }
}

// MARK: - show

struct VPhoneVirtualMachineTemplateShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one template")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "template id (or a unique prefix of at least 4 digits)") var id: String
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let report = try VPhoneMachineTemplateReport(VPhoneMachineTemplates.template(id, in: lib.library))
        if json {
            try print(encodeJSON(report))
            return
        }
        let key = report.key
        print("id:        \(report.id)")
        print("path:      \(report.path)")
        print("device:    \(key.device)")
        print("iOS:       \(key.iOSVersion) (\(key.iOSBuild))")
        print("cloudOS:   \(key.cloudOSVersion) (\(key.cloudOSBuild))")
        print("preset:    \(key.patchPreset)  boot chain \(key.bootChainPlanDigest.prefix(12))")
        print("bundle:    series \(key.bundleSeries), boot chain \(report.bootChainBundleVersion ?? "unknown"), "
            + "built with \(report.builtWithBundleVersion ?? "unknown")")
        print("disk:      \(key.diskSizeGB) GB")
        print("trim:      \(key.slimming.trimTier), setup boot \(key.slimming.setupBoot ? "yes" : "no"), "
            + "services \(key.slimming.serviceProfile), removed apps \(key.slimming.removedApps.isEmpty ? "none" : key.slimming.removedApps.joined(separator: ","))")
        print("steps:     snapshot deleted \(report.steps.snapshotDeleted ? "yes" : "no"), setup done \(report.steps.setupDone ? "yes" : "no")")
        print("created:   \(report.created.formatted(.iso8601))")
        if let source = report.sourceMachine {
            print("source:    \(source)")
        }
        print("state:     \(report.stale ? "stale" : "current")")
        for reason in report.staleReasons {
            print("  \(reason)")
        }
    }
}

// MARK: - adopt

struct VPhoneVirtualMachineTemplateAdoptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Freeze a stopped, newly created VM into a template",
        discussion: """
        Moves the VM's folder into <library>/.templates/<id>: it leaves vm list, can no longer \
        boot, and vm create clones new machines from it. Its key is read from its records \
        (restore-info.json, PatchPlan.plist, config.plist and the disk). Adopt a machine straight \
        after creating it: whatever it has done since its first boot, every clone inherits.

        Refused while the VM runs, while it has snapshots, or when a template with its key \
        exists. --force adopts a machine whose boot chain was built by another bundle series \
        than this vphone-cli's, or whose patch receipt differs from its plan; such a template \
        is listed as stale.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String
    @Flag(help: "adopt even when the template would be stale") var force = false

    func run() throws {
        let bundle = try lib.library.bundle(named: name)
        try VPhoneBundleActivity.requireStopped(bundle)
        let previous = try VPhoneMachineTemplates.readRecord(inBundle: bundle.url)
        let steps = previous?.steps ?? VPhoneMachineTemplateSteps()
        let recorded = try VPhoneMachineTemplateKeys.recorded(bundle, slimming: steps.slimming)
        var problems: [String] = []
        let series = VPhoneMachineTemplateKeys.currentSeries
        if recorded.key.bundleSeries != series {
            problems.append("its boot chain was built by bundle series \(recorded.key.bundleSeries); this vphone-cli is \(series)")
        }
        if !recorded.drift.isEmpty {
            problems.append("its patch receipt differs from its plan: \(recorded.drift.joined(separator: ", "))")
        }
        if !problems.isEmpty {
            guard force else {
                throw ValidationError("VM '\(name)' would be a stale template: \(problems.joined(separator: "; ")). Pass --force to adopt it anyway.")
            }
            for problem in problems {
                print("warning: \(problem)")
            }
        }
        let record = VPhoneMachineTemplateRecord(
            key: recorded.key,
            created: previous?.created ?? Date(),
            builtWithBundleVersion: VPhoneBundleVersion.current(),
            bootChainBundleVersion: recorded.bootChainBundleVersion,
            sourceMachine: name,
            steps: steps,
        )
        let template = try VPhoneMachineTemplates.adopt(machineNamed: name, in: lib.library, record: record)
        print("adopted \(name) as template \(template.identifier)")
        print("  \(template.key.summary)")
        print("create machines from it with: vphone-cli vm create <name> --template \(template.identifier)")
    }
}

// MARK: - delete

struct VPhoneVirtualMachineTemplateDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a template or an unfinished template build",
        discussion: """
        Machines cloned from the template keep working: they share its blocks but do not refer \
        to it. The space those shared blocks take is freed only when no clone uses them either.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "template id (or unique prefix), or a .building-… name from vm template list") var id: String
    @Flag(name: .shortAndLong, help: "Do not prompt") var force = false

    func run() throws {
        let library = lib.library
        if !force {
            // A damaged template has no summary to show, and is deleted all the same.
            let what = (try? VPhoneMachineTemplates.template(id, in: library)).map { "template \($0.identifier) (\($0.key.summary))" }
                ?? "'\(id)'"
            print("Delete \(what)? [y/N] ", terminator: "")
            guard (readLine() ?? "").lowercased() == "y" else {
                print("Canceled. Nothing was deleted.")
                return
            }
        }
        let removed = try VPhoneMachineTemplates.delete(id, in: library)
        print("deleted \(removed.lastPathComponent)")
        print("note: blocks still shared with machines cloned from it are freed only when those machines change or are deleted")
    }
}
