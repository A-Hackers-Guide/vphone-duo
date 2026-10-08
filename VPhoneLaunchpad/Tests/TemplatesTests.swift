import Darwin
import Foundation

@main
struct TemplatesTests {
    static func main() throws {
        slimmingArguments()
        commandArguments()
        creationPlan()
        try templateList()
        try templateFind()
        notices()
        try diskUsage()
    }

    // MARK: - Switches

    static func slimmingArguments() {
        let standard = VPhoneLaunchpadSlimming()
        precondition(standard.arguments.isEmpty, "The defaults pass nothing: \(standard.arguments)")
        precondition(standard.setupArguments.isEmpty, "Setup takes the defaults too")
        precondition(standard.trimArguments == ["--tier", "standard"], "Standard trim: \(standard.trimArguments ?? [])")
        precondition(standard.removedApps.count == 10, "Ten apps go by default")
        precondition(!standard.removedApps.contains("com.apple.camera") && !standard.removedApps.contains("com.apple.mobilephone"),
                     "Camera and Phone are never removed")

        var off = VPhoneLaunchpadSlimming()
        off.slim = false
        // The other switches keep their values but count for nothing.
        off.trim = .conservative
        off.trimsServices = false
        off.accountsOff = true
        off.keptApps = ["com.apple.news"]
        precondition(off.arguments == ["--slim", "off"], "Slim off alone: \(off.arguments)")
        precondition(off.setupArguments == ["--slim", "off"], "Setup with slim off")
        precondition(off.trimArguments == nil, "Slim off trims nothing")
        precondition(off.removedApps.isEmpty, "Slim off removes no app")

        var parts = VPhoneLaunchpadSlimming()
        parts.trim = .conservative
        parts.keptLanguages = "en, ja"
        parts.trimsServices = false
        parts.accountsOff = true
        parts.keptApps = ["com.apple.Passbook", "com.apple.findmy", "com.apple.camera"]
        // Languages count only for the standard tier; accounts only with the
        // trimmed profile; Camera is not one of the apps.
        precondition(parts.arguments == ["--trim", "conservative", "--service-profile", "none",
                                         "--keep-apps", "com.apple.findmy,com.apple.Passbook"],
        "Mixed switches: \(parts.arguments)")
        precondition(parts.setupArguments == ["--service-profile", "none", "--keep-apps", "com.apple.findmy,com.apple.Passbook"],
                     "Setup drops the trim: \(parts.setupArguments)")
        precondition(parts.trimArguments == ["--tier", "conservative"], "Conservative trim keeps no languages")

        var languages = VPhoneLaunchpadSlimming()
        languages.keptLanguages = " en , ja ,"
        languages.accountsOff = true
        precondition(languages.arguments == ["--keep-languages", "en,ja", "--accounts-off"], "Languages: \(languages.arguments)")
        precondition(languages.setupArguments == ["--accounts-off"], "Setup leaves the languages to the trim")
        precondition(languages.trimArguments == ["--tier", "standard", "--keep-languages", "en,ja"], "Trim with languages")
        languages.keptLanguages = "en,zh-Hans,zh"
        precondition(languages.languagesArgument == nil, "The default languages are not passed")
        languages.keptLanguages = "en,日本語"
        precondition(languages.problem != nil, "A language that is no code is refused")
        languages.keptLanguages = "en,zh-Hant,pt-BR"
        precondition(languages.problem == nil, "Codes with a region or script pass")

        var noApps = VPhoneLaunchpadSlimming()
        noApps.removesApps = false
        noApps.keptApps = ["com.apple.news"]
        precondition(noApps.arguments == ["--remove-apps", "off"], "Remove apps off ignores the kept list")

        var none = VPhoneLaunchpadSlimming()
        none.trim = .none
        precondition(none.arguments == ["--trim", "none"] && none.trimArguments == nil, "No trim step for tier none")
        print("Slimming switch tests passed")
    }

    // MARK: - Commands

    static func commandArguments() {
        var slimming = VPhoneLaunchpadSlimming()
        slimming.trimsServices = false
        let request = VPhoneLaunchpadTemplateCommands.Request(
            iphoneSource: "https://example.invalid/iPhone17,3_27.0_24A435_Restore.ipsw",
            cloudOSSource: "https://example.invalid/cloudos",
            device: "iPad16,1",
            preset: "standard",
            blocked: ["kernel-b", "kernel-a"],
            allowed: ["dyld-x"],
            diskSizeGB: 128,
            slimming: slimming,
        )
        let find = VPhoneLaunchpadTemplateCommands.find(request)
        precondition(find == [
            "vm", "template", "find", "--json",
            "--iphone-source", "https://example.invalid/iPhone17,3_27.0_24A435_Restore.ipsw",
            "--cloudos-source", "https://example.invalid/cloudos",
            "--device", "iPad16,1", "--preset", "standard", "--disk-size", "128",
            "--block", "kernel-a", "--block", "kernel-b", "--allow", "dyld-x",
            "--service-profile", "none",
        ], "find: \(find)")

        precondition(VPhoneLaunchpadTemplateCommands.trim("template-1a2b3c4d", slimming)
            == ["vm", "template", "trim", "template-1a2b3c4d", "--tier", "standard"], "trim")
        var untrimmed = slimming
        untrimmed.trim = .none
        precondition(VPhoneLaunchpadTemplateCommands.trim("t", untrimmed) == nil, "No trim command for tier none")
        precondition(VPhoneLaunchpadTemplateCommands.setup("template-1a2b3c4d", slimming)
            == ["vm", "template", "setup", "template-1a2b3c4d", "--service-profile", "none"], "setup")
        precondition(VPhoneLaunchpadTemplateCommands.adopt("template-1a2b3c4d", iphoneSource: "i", cloudOSSource: "c")
            == ["vm", "template", "adopt", "template-1a2b3c4d", "--json", "--iphone-source", "i", "--cloudos-source", "c"], "adopt")
        precondition(VPhoneLaunchpadTemplateCommands.clone("lab-01", template: "52b1fcc75e0c", cpuCount: 6, memoryMB: 6144, network: "tunnel")
            == ["vm", "create", "lab-01", "--template", "52b1fcc75e0c", "--skip-first-boot",
                "--cpu", "6", "--memory", "6144", "--network", "tunnel"], "clone")
        precondition(VPhoneLaunchpadTemplateCommands.delete("52b1fcc75e0c") == ["vm", "template", "delete", "52b1fcc75e0c", "--force"], "delete")

        let failure = ["[setup] failed at setup-skip: refused", "Error: Setup boot failed at step setup-skip (a. skip Setup Assistant): refused"]
        precondition(VPhoneLaunchpadTemplateCommands.failureLine(failure) == "Setup boot failed at step setup-skip (a. skip Setup Assistant): refused",
                     "The error line is the reason")
        precondition(VPhoneLaunchpadTemplateCommands.failureLine(["fine"]) == nil, "No error line")
        print("Command argument tests passed")
    }

    // MARK: - Plan

    static func creationPlan() {
        let alone = VPhoneLaunchpadCreationPlan(name: "lab-01", buildName: nil, slimming: VPhoneLaunchpadSlimming())
        precondition(alone.steps == [.create, .prepare, .patch, .bootDFU, .waitDFU, .restore, .stopDFU, .installCFW, .firstBoot],
                     "Without a template: \(alone.steps)")
        precondition(alone.machineName(for: .create) == "lab-01" && alone.machineName(for: .installCFW) == "lab-01", "One machine")

        let build = VPhoneLaunchpadCreationPlan.newBuildName()
        precondition(build.wholeMatch(of: /template-[0-9a-f]{8}/) != nil, "Build name: \(build)")
        precondition(VPhoneLaunchpadNames.isValidMachineName(build), "The build name is a machine name")

        var plan = VPhoneLaunchpadCreationPlan(name: "lab-01", buildName: build, slimming: VPhoneLaunchpadSlimming())
        let full: [VPhoneLaunchpadCreationStep] = [.findTemplate, .create, .prepare, .patch, .bootDFU, .waitDFU, .restore, .stopDFU,
                                                   .installCFW, .trimTemplate, .setUpTemplate, .adoptTemplate, .cloneTemplate, .firstBoot]
        precondition(plan.steps == full, "Until Find answers, the build is listed: \(plan.steps)")
        plan.foundTemplate = false
        precondition(plan.steps == full, "A template to build")
        precondition(plan.step(after: .installCFW) == .trimTemplate, "Trim follows CFW")
        precondition(plan.machineName(for: .installCFW) == build, "CFW goes into the build")
        precondition(plan.machineName(for: .adoptTemplate) == build, "The build is adopted")
        precondition(plan.machineName(for: .cloneTemplate) == "lab-01" && plan.machineName(for: .firstBoot) == "lab-01",
                     "The clone and its boot are the new machine")
        precondition(plan.machineName(for: .findTemplate) == "lab-01", "Find names the new machine")
        precondition(plan.steps.allSatisfy { $0.needsRoot == ($0 == .installCFW) }, "Only CFW needs root")

        plan.slimming.slim = false
        precondition(!plan.steps.contains(.trimTemplate), "Slim off: no trim step")
        precondition(plan.step(after: .installCFW) == .setUpTemplate, "Setup follows CFW without a trim")

        plan.foundTemplate = true
        precondition(plan.steps == [.findTemplate, .cloneTemplate, .firstBoot], "A template found: \(plan.steps)")
        precondition(plan.step(after: .findTemplate) == .cloneTemplate, "Straight to the clone")
        precondition(plan.step(after: .firstBoot) == nil, "First boot is last")
        print("Creation plan tests passed")
    }

    // MARK: - JSON

    /// `vm template list --json` as 2.9.0 prints it: pretty, keys sorted,
    /// slashes escaped, empty arrays over two lines.
    static let listJSON = #"""
    {
      "building" : [
        {
          "active" : false,
          "id" : "0e44975ff833",
          "name" : ".building-0e44975ff833-7A1C",
          "path" : "\/Users\/me\/.vphone\/machines\/.templates\/.building-0e44975ff833-7A1C"
        }
      ],
      "damaged" : [

      ],
      "templates" : [
        {
          "allocatedBytes" : 17580000000,
          "bootChainBundleVersion" : "2.9.0",
          "builtWithBundleVersion" : "2.9.0",
          "created" : "2026-10-08T10:00:00Z",
          "diskSizeBytes" : 64000000000,
          "id" : "52b1fcc75e0c",
          "key" : {
            "BootChainPlanDigest" : "01e930903b5c6b6dd87e0a3a20a2d3a5fe1813645577d6e14f6ead8fdbc49153",
            "BundleSeries" : "2.9",
            "CloudOSBuild" : "23E5207q",
            "CloudOSVersion" : "26.4",
            "Device" : "iPhone17,3",
            "DiskSizeGB" : 64,
            "FormatVersion" : 2,
            "IOSBuild" : "24A435",
            "IOSVersion" : "27.0",
            "PatchPreset" : "standard",
            "Slimming" : {
              "RemovedApps" : [
                "com.apple.AppStore",
                "com.apple.news"
              ],
              "ServiceGroups" : [
                "accounts"
              ],
              "ServiceProfile" : "trimmed",
              "SetupBoot" : true,
              "TrimTier" : "standard\/1\/en,zh,zh-Hans"
            }
          },
          "machines" : [
            "e2e-a",
            "e2e-b"
          ],
          "path" : "\/Users\/me\/.vphone\/machines\/.templates\/52b1fcc75e0c",
          "sourceMachine" : "template-1a2b3c4d",
          "sources" : {
            "CloudOS" : "https:\/\/example.invalid\/cloudos",
            "IPhone" : "https:\/\/example.invalid\/iPhone17,3_27.0_24A435_Restore.ipsw"
          },
          "stale" : true,
          "staleReasons" : [
            "built by bundle series 2.8; this vphone-cli is 2.9"
          ],
          "steps" : {
            "RemovedApps" : [

            ],
            "ServiceGroups" : [

            ],
            "ServiceProfile" : "trimmed",
            "SetupDone" : true,
            "SnapshotDeleted" : true,
            "TrimTier" : "standard\/1\/en,zh,zh-Hans"
          }
        },
        {
          "allocatedBytes" : 18920000000,
          "created" : "2026-10-07T10:00:00Z",
          "diskSizeBytes" : 64000000000,
          "id" : "2246f982776c",
          "key" : {
            "BootChainPlanDigest" : "ab",
            "BundleSeries" : "2.9",
            "CloudOSBuild" : "23E5207q",
            "CloudOSVersion" : "26.4",
            "Device" : "iPad16,1",
            "DiskSizeGB" : 64,
            "FormatVersion" : 2,
            "IOSBuild" : "24A446",
            "IOSVersion" : "27.0.1",
            "PatchPreset" : "standard",
            "Slimming" : {
              "RemovedApps" : [

              ],
              "ServiceProfile" : "none",
              "SetupBoot" : true,
              "TrimTier" : "none"
            }
          },
          "machines" : [

          ],
          "path" : "\/Users\/me\/.vphone\/machines\/.templates\/2246f982776c",
          "stale" : false,
          "staleReasons" : [

          ],
          "steps" : {
            "SetupDone" : true
          }
        }
      ]
    }
    """#

    static func templateList() throws {
        // A warning on stderr may come first; the document is found the
        // way every other --json output is.
        let lines = ["warning: something"] + listJSON.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.lastIndex(where: { $0.hasPrefix("[") || $0.hasPrefix("{") }) else {
            preconditionFailure("No document")
        }
        let data = Data(lines[start...].joined(separator: "\n").utf8)
        let list = try VPhoneLaunchpadTemplateList.decode(data, libraryRoot: "/Users/me/.vphone/machines")
        precondition(list.templates.count == 2 && list.building.count == 1 && list.damaged.isEmpty, "Counts")
        let first = list.templates[0]
        precondition(first.id == "52b1fcc75e0c" && first.libraryRoot == "/Users/me/.vphone/machines", "Identity")
        precondition(first.key.device == "iPhone17,3" && first.key.iOSBuild == "24A435" && first.key.diskSizeGB == 64, "Key")
        precondition(first.key.slimming.tier == "standard" && first.key.slimming.keptLanguages == "en,zh,zh-Hans", "Tier")
        precondition(first.machines == ["e2e-a", "e2e-b"] && first.allocatedBytes == 17_580_000_000, "Usage")
        precondition(first.stale && first.staleReasons.count == 1, "Stale")
        precondition(first.sources?.iPhone == "https://example.invalid/iPhone17,3_27.0_24A435_Restore.ipsw", "Sources")
        precondition(first.created == Date(timeIntervalSince1970: 1_791_453_600), "Created \(first.created)")
        precondition(first.key.slimming.isSlimmed, "Slimmed")

        let second = list.templates[1]
        precondition(second.key.osName == "iPadOS" && second.key.slimming.serviceGroups.isEmpty, "Format 1 slimming has no groups")
        precondition(!second.key.slimming.isSlimmed && second.sources == nil && second.bootChainBundleVersion == nil, "Plain template")
        precondition(list.building[0].id == "0e44975ff833" && !list.building[0].active, "Unfinished build")
        print("Template list decoding tests passed")
    }

    static func templateFind() throws {
        let unresolved = #"{"building":false,"reason":"the IPSWs are not downloaded and no template records these sources","resolved":false,"usable":false}"#
        let none = try VPhoneLaunchpadTemplateFind.decode(Data(unresolved.utf8))
        precondition(!none.resolved && none.id == nil && none.template == nil && none.reason != nil, "Unresolved")

        let templateJSON = listJSON
            .components(separatedBy: "\"templates\" : [")[1]
            .components(separatedBy: "},\n    {")[0] + "}"
        let found = """
        {"building":false,"id":"52b1fcc75e0c","resolved":true,"resolvedBy":"template","summary":"…","template":\(templateJSON),"usable":false}
        """
        let match = try VPhoneLaunchpadTemplateFind.decode(Data(found.utf8))
        precondition(match.resolved && match.resolvedBy == "template" && match.id == "52b1fcc75e0c", "Resolved")
        precondition(match.template?.stale == true && !match.usable, "A stale template is not usable")
        print("Template find decoding tests passed")
    }

    // MARK: - Delete note

    static func notices() {
        let lines = [
            "deleted e2e-b",
            "note: template 52b1fcc75e0c (~17.58 GB) is no longer used by any machine; remove it with `vphone-cli vm template delete 52b1fcc75e0c`",
        ]
        let notice = VPhoneLaunchpadTemplateNotice.parse(lines, libraryRoot: "/lib")
        precondition(notice == VPhoneLaunchpadTemplateNotice(id: "52b1fcc75e0c", size: "17.58 GB", libraryRoot: "/lib"), "Notice: \(String(describing: notice))")
        precondition(VPhoneLaunchpadTemplateNotice.parse(["deleted e2e-a"], libraryRoot: "/lib") == nil, "No note, no notice")
        precondition(VPhoneLaunchpadTemplateNotice.parse(["note: template ../x (~1 GB) is no longer used by any machine"], libraryRoot: "/lib") == nil,
                     "Only a template identifier")
        print("Delete note tests passed")
    }

    // MARK: - Disk use

    static func diskUsage() throws {
        let english = Locale(identifier: "en_US")
        precondition(VPhoneLaunchpadDiskUsage.format(17_580_000_000, locale: english) == "17.58 GB",
                     VPhoneLaunchpadDiskUsage.format(17_580_000_000, locale: english))
        precondition(VPhoneLaunchpadDiskUsage.format(610_000_000, locale: english) == "610 MB",
                     VPhoneLaunchpadDiskUsage.format(610_000_000, locale: english))
        let partial = VPhoneLaunchpadDiskUsage(allocated: 17_580_000_000, exclusive: 610_000_000)
        precondition(partial.summary(locale: english).contains("610 MB") && partial.summary(locale: english).contains("17.58 GB"),
                     partial.summary(locale: english))
        precondition(VPhoneLaunchpadDiskUsage(allocated: 1_000_000_000, exclusive: nil).summary(locale: english) == "1 GB", "Without a private size")

        // A clone shares its blocks until it writes: on APFS (the temporary
        // directory is on the boot volume) the original keeps its blocks to
        // itself only once the clone has rewritten them.
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("disk-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let machine = folder.appendingPathComponent("machine", isDirectory: true)
        try fm.createDirectory(at: machine, withIntermediateDirectories: true)
        let disk = machine.appendingPathComponent("Disk.img")
        let block = Data((0 ..< (8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try block.write(to: disk)
        let alone = try require(VPhoneLaunchpadDiskUsage.privateSize(of: disk.path), "A private size on APFS")
        precondition(alone >= 8 << 20, "A file shares nothing yet: \(alone)")

        let clone = folder.appendingPathComponent("clone.img")
        precondition(clonefile(disk.path, clone.path, 0) == 0, "clonefile")
        let shared = try require(VPhoneLaunchpadDiskUsage.privateSize(of: disk.path), "Private size after a clone")
        precondition(shared < 1 << 20, "A cloned file shares its blocks: \(shared)")

        let handle = try FileHandle(forWritingTo: clone)
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 2 << 20))
        try handle.synchronize()
        try handle.close()
        let written = try require(VPhoneLaunchpadDiskUsage.privateSize(of: clone.path), "Private size of the written clone")
        precondition(written >= 2 << 20 && written < 4 << 20, "Only rewritten blocks are its own: \(written)")

        // The folder's own walk: everything allocated, little of it exclusive.
        let usage = VPhoneLaunchpadDiskUsage.measure(machine)
        precondition(usage.allocated >= 8 << 20, "Allocated \(usage.allocated)")
        precondition((usage.exclusive ?? .max) <= 3 << 20, "Exclusive \(String(describing: usage.exclusive))")
        let link = machine.appendingPathComponent("link.img")
        try fm.createSymbolicLink(at: link, withDestinationURL: clone)
        precondition(VPhoneLaunchpadDiskUsage.measure(machine).allocated == usage.allocated, "A link is not followed")
        print("Disk use tests passed")
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            preconditionFailure(message)
        }
        return value
    }
}
