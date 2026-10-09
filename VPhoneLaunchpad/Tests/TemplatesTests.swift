import Darwin
import Foundation

@main
struct TemplatesTests {
    static func main() async throws {
        slimmingArguments()
        commandArguments()
        patchOverrides()
        creationPlan()
        guestRestart()
        try templateList()
        try templateFind()
        notices()
        try await diskUsage()
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
        // Strict: an app the setup boot cannot remove fails the step.
        precondition(VPhoneLaunchpadTemplateCommands.setup("template-1a2b3c4d", slimming)
            == ["vm", "template", "setup", "template-1a2b3c4d", "--strict", "--service-profile", "none"], "setup")
        precondition(VPhoneLaunchpadTemplateCommands.setup("t", VPhoneLaunchpadSlimming()) == ["vm", "template", "setup", "t", "--strict"],
                     "setup with the defaults")
        // The adopt expects the id Find Template computed.
        precondition(VPhoneLaunchpadTemplateCommands.adopt("template-1a2b3c4d", iphoneSource: "i", cloudOSSource: "c", expect: "2847ec2a3e3e")
            == ["vm", "template", "adopt", "template-1a2b3c4d", "--json", "--iphone-source", "i", "--cloudos-source", "c",
                "--expect", "2847ec2a3e3e"], "adopt")
        precondition(VPhoneLaunchpadTemplateCommands.adopt("t", iphoneSource: "i", cloudOSSource: "c", expect: nil)
            == ["vm", "template", "adopt", "t", "--json", "--iphone-source", "i", "--cloudos-source", "c"], "adopt without an id")
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

    // MARK: - Patch overrides

    static func patchOverrides() {
        let overrides = VPhoneLaunchpadPatchOverrides(
            preset: "standard",
            blocked: ["ibss-cfw-serial_label", "system-debugserver-cfw-install"],
            allowed: ["dyld-cfw-camera", "external-x"],
            guestPatches: ["system-debugserver-cfw-install", "dyld-cfw-camera"],
        )
        precondition(overrides.bootChainBlocked == ["ibss-cfw-serial_label"], "Boot-chain blocks: \(overrides.bootChainBlocked)")
        // One the catalog does not know counts as boot chain, as the key counts it.
        precondition(overrides.bootChainAllowed == ["external-x"], "Boot-chain allows: \(overrides.bootChainAllowed)")
        precondition(overrides.hasBootChainOverrides && overrides.hasGuestOverrides, "Both kinds")

        // The template build records the boot chain's; the clone gets all.
        precondition(VPhoneLaunchpadTemplateCommands.setPatches("template-1a2b3c4d", overrides, includingGuest: false)
            == ["fw", "set-patches", "template-1a2b3c4d", "--preset", "standard",
                "--block", "ibss-cfw-serial_label", "--allow", "external-x"], "Build overrides")
        precondition(VPhoneLaunchpadTemplateCommands.setPatches("lab-01", overrides, includingGuest: true)
            == ["fw", "set-patches", "lab-01", "--preset", "standard",
                "--block", "ibss-cfw-serial_label", "--block", "system-debugserver-cfw-install",
                "--allow", "dyld-cfw-camera", "--allow", "external-x"], "Clone overrides")

        // Find keys on what the template is built with.
        var request = VPhoneLaunchpadTemplateCommands.Request(
            iphoneSource: "i", cloudOSSource: "c", preset: overrides.preset,
            blocked: overrides.bootChainBlocked, allowed: overrides.bootChainAllowed,
            diskSizeGB: 64, slimming: VPhoneLaunchpadSlimming(),
        )
        let find = VPhoneLaunchpadTemplateCommands.find(request)
        precondition(!find.contains("system-debugserver-cfw-install") && !find.contains("dyld-cfw-camera"), "Find leaves guest overrides out: \(find)")
        precondition(find.contains("ibss-cfw-serial_label") && find.contains("external-x"), "Find keeps boot-chain overrides")

        let guestOnly = VPhoneLaunchpadPatchOverrides(preset: "standard", blocked: ["dyld-cfw-camera"], guestPatches: ["dyld-cfw-camera"])
        precondition(!guestOnly.hasBootChainOverrides && guestOnly.hasGuestOverrides, "Guest only")
        request.blocked = guestOnly.bootChainBlocked
        request.allowed = guestOnly.bootChainAllowed
        precondition(!VPhoneLaunchpadTemplateCommands.find(request).contains("--block"), "Guest-only overrides find the plain template")
        let none = VPhoneLaunchpadPatchOverrides(preset: "experimental", guestPatches: ["dyld-cfw-camera"])
        precondition(!none.hasGuestOverrides && !none.hasBootChainOverrides, "A guest patch not overridden is no override")
        print("Patch override tests passed")
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
        precondition(plan.buildingName == build, "A build is under way")

        plan.slimming.slim = false
        precondition(!plan.steps.contains(.trimTemplate), "Slim off: no trim step")
        precondition(plan.step(after: .installCFW) == .setUpTemplate, "Setup follows CFW without a trim")

        plan.foundTemplate = true
        precondition(plan.steps == [.findTemplate, .cloneTemplate, .firstBoot], "A template found: \(plan.steps)")
        precondition(plan.step(after: .findTemplate) == .cloneTemplate, "Straight to the clone")
        precondition(plan.step(after: .firstBoot) == nil, "First boot is last")
        // A found template builds nothing: the create report names no build machine.
        precondition(plan.buildingName == nil, "No build when a template is found")
        plan.foundTemplate = nil
        precondition(plan.buildingName == nil, "No build before Find answers")
        precondition(alone.buildingName == nil, "No build without a template")

        // Guest patch overrides: a step of the new machine's, after the clone.
        var guest = VPhoneLaunchpadCreationPlan(name: "lab-01", buildName: build, slimming: VPhoneLaunchpadSlimming(), appliesGuestPatches: true)
        guest.foundTemplate = true
        precondition(guest.steps == [.findTemplate, .cloneTemplate, .applyGuestPatches, .firstBoot], "Found, with guest patches: \(guest.steps)")
        precondition(guest.machineName(for: .applyGuestPatches) == "lab-01" && !guest.buildsTemplate(.applyGuestPatches),
                     "Guest patches go to the clone")
        precondition(Step.applyGuestPatches.needsRoot, "cfw update-environment runs through the helper")
        guest.foundTemplate = false
        precondition(Array(guest.steps.suffix(4)) == [.adoptTemplate, .cloneTemplate, .applyGuestPatches, .firstBoot],
                     "Built, with guest patches: \(guest.steps)")
        let withoutTemplate = VPhoneLaunchpadCreationPlan(name: "lab-01", buildName: nil, slimming: VPhoneLaunchpadSlimming(), appliesGuestPatches: true)
        precondition(!withoutTemplate.steps.contains(.applyGuestPatches), "cfw install applies them without a template")
        print("Creation plan tests passed")
    }

    typealias Step = VPhoneLaunchpadCreationStep

    // MARK: - Guest restart

    static func guestRestart() {
        let processes: [String: Any] = ["processes": [
            ["pid": 412, "name": "launchd_sim", "start_time": 1_791_500_000.5],
            ["pid": 1, "name": "launchd", "start_time": 1_791_453_600.25],
        ]]
        let boot = VPhoneLaunchpadPendingRestart.boot(fromProcesses: processes)
        precondition(boot == 1_791_453_600.25, "launchd's start time: \(String(describing: boot))")
        precondition(VPhoneLaunchpadPendingRestart.boot(fromProcesses: ["processes": []]) == nil, "No launchd")

        // Switching to None: the apply says a restart is needed, the profile
        // read afterwards does not.
        let applyNone: [String: Any] = ["enabled": Array(repeating: "label", count: 141), "failed": [], "reboot_required": true]
        let profile = VPhoneLaunchpadServiceProfile(["profile": "none", "supported": true, "running": [], "reboot_required": false])
        precondition(!profile.rebootRequired && profile.profile == "none" && profile.groups.isEmpty, "The profile forgets")
        guard let pending = VPhoneLaunchpadPendingRestart.afterApply(applyNone, pending: nil, boot: boot) else {
            preconditionFailure("The apply's answer is kept")
        }
        precondition(pending.boot == boot, "Made in this boot")
        precondition(!pending.hasRestarted(currentBoot: boot), "Same boot: still pending")
        precondition(!pending.hasRestarted(currentBoot: boot.map { $0 + 0.4 }), "Rounding is not a boot")
        precondition(!pending.hasRestarted(currentBoot: nil), "A guest that does not answer has not restarted")
        precondition(pending.hasRestarted(currentBoot: 1_791_457_200), "A later boot")

        // A second change keeps the first one's boot; one needing no restart clears it.
        let older = VPhoneLaunchpadPendingRestart(boot: 10)
        precondition(VPhoneLaunchpadPendingRestart.afterApply(["reboot_required": true], pending: older, boot: 20) == older,
                     "The earliest boot counts")
        precondition(VPhoneLaunchpadPendingRestart.afterApply(["reboot_required": false], pending: older, boot: 20) == nil,
                     "Nothing to restart for")
        precondition(VPhoneLaunchpadPendingRestart.afterApply([:], pending: nil, boot: 20) == nil, "An older guest says nothing")
        precondition(!VPhoneLaunchpadPendingRestart(boot: nil).hasRestarted(currentBoot: 20), "Unknown boot: wait for a stop")

        let trimmed = VPhoneLaunchpadServiceProfile([
            "profile": "trimmed", "supported": true, "running": ["a", "b"], "reboot_required": true,
            "record": ["groups": ["base", "accounts"], "allow": ["com.apple.x"]],
        ])
        precondition(trimmed.rebootRequired && trimmed.running == 2 && trimmed.groups == ["base", "accounts"] && trimmed.allow == ["com.apple.x"],
                     "Trimmed profile")
        print("Guest restart tests passed")
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

    static func diskUsage() async throws {
        let english = Locale(identifier: "en_US")
        precondition(VPhoneLaunchpadDiskUsage.format(17_580_000_000, locale: english) == "17.58 GB",
                     VPhoneLaunchpadDiskUsage.format(17_580_000_000, locale: english))
        precondition(VPhoneLaunchpadDiskUsage.format(610_000_000, locale: english) == "610 MB",
                     VPhoneLaunchpadDiskUsage.format(610_000_000, locale: english))
        let partial = VPhoneLaunchpadDiskUsage(allocated: 17_580_000_000, exclusive: 610_000_000)
        precondition(partial.summary(locale: english).contains("610 MB") && partial.summary(locale: english).contains("17.58 GB"),
                     partial.summary(locale: english))
        precondition(VPhoneLaunchpadDiskUsage(allocated: 1_000_000_000, exclusive: nil).summary(locale: english) == "1 GB", "Without an exclusive size")
        extentArithmetic()
        try await sharedExtents()
        print("Disk use tests passed")
    }

    /// The sweep on made-up extents.
    static func extentArithmetic() {
        typealias Extents = VPhoneLaunchpadDiskExtents
        func extents(_ ranges: [(Int64, Int64)], device: Int64 = 1) -> Extents {
            Extents(device: device, ranges: ranges.map { Extents.Range(start: $0.0, end: $0.1) })
        }
        let merged = extents([(30, 40), (0, 10), (10, 20), (35, 50), (60, 60)])
        precondition(merged.ranges == [Extents.Range(start: 0, end: 20), Extents.Range(start: 30, end: 50)], "Normalized: \(merged.ranges)")
        precondition(merged.bytes == 40, "Bytes \(merged.bytes)")

        // A template and two clones: each clone rewrote a part, one of them
        // also wrote where the template has a hole.
        let template = extents([(0, 1000)])
        let first = extents([(0, 100), (2000, 2100), (200, 1000)])
        let second = extents([(0, 500), (3000, 3050), (600, 1000)])
        precondition(Extents.exclusiveBytes(of: [[template], [first], [second]]) == [0, 100, 50],
                     "Clones: \(Extents.exclusiveBytes(of: [[template], [first], [second]]))")
        // Once the clones are gone, all of it is the template's own.
        precondition(Extents.exclusiveBytes(of: [[template]]) == [1000], "Alone")
        // What only the template and one clone share is neither's own.
        precondition(Extents.exclusiveBytes(of: [[extents([(0, 100)])], [extents([(50, 150)])]]) == [50, 50], "Overlap")
        // Two files of one folder sharing blocks count them once, as its own.
        precondition(Extents.exclusiveBytes(of: [[extents([(0, 100)]), extents([(0, 100)])], [extents([(500, 600)])]]) == [100, 100],
                     "Own clones")
        // The same offsets on another device are other blocks.
        precondition(Extents.exclusiveBytes(of: [[extents([(0, 100)], device: 1)], [extents([(0, 100)], device: 2)]]) == [100, 100],
                     "Devices")
        precondition(Extents.exclusiveBytes(of: [[], [extents([(0, 10)])]]) == [0, 10], "An empty folder")
    }

    /// Real clones on APFS (the temporary directory is on the boot volume).
    /// The images are 256 MiB and sparse, as a disk image is: APFS fills a
    /// small file's holes with zeros when it writes into one, which would
    /// count as written.
    static func sharedExtents() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("disk-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let library = folder.appendingPathComponent("library", isDirectory: true)
        let template = library.appendingPathComponent(".templates/0123456789ab", isDirectory: true)
        let first = library.appendingPathComponent("first", isDirectory: true)
        let second = library.appendingPathComponent("second", isDirectory: true)
        for directory in [template, first, second] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: library.appendingPathComponent(".templates/.building-0123456789ab-1"), withIntermediateDirectories: true)
        precondition(VPhoneLaunchpadDiskMeter.templateFolders(in: library.path) == [template.path],
                     "Template folders: \(VPhoneLaunchpadDiskMeter.templateFolders(in: library.path))")

        let disk = template.appendingPathComponent("Disk.img")
        precondition(fm.createFile(atPath: disk.path, contents: nil), "Disk.img")
        try write(disk, at: 0, count: 8 << 20, byte: 0x11)
        try write(disk, at: 32 << 20, count: 8 << 20, byte: 0x22)
        try truncate(disk, to: 256 << 20)

        let mapped = try VPhoneLaunchpadDiskExtents.map(disk.path).get()
        let allocated = try allocatedBytes(disk)
        precondition(mapped.bytes == allocated && allocated >= 16 << 20 && allocated < 24 << 20,
                     "Holes are not mapped: \(mapped.bytes) of \(allocated)")
        precondition(VPhoneLaunchpadDiskExtents.map(folder.path) == .failure(.unsupported), "A directory is not mapped")

        let meter = VPhoneLaunchpadDiskMeter()
        let alone = await meter.measure([.init(path: template.path)])
        precondition(alone[template.path] == VPhoneLaunchpadDiskUsage(allocated: allocated, exclusive: allocated),
                     "A template alone: \(String(describing: alone[template.path]))")

        for machine in [first, second] {
            precondition(clonefile(disk.path, machine.appendingPathComponent("Disk.img").path, 0) == 0, "clonefile")
        }
        // The first clone rewrites 2 MiB of the template's data and writes
        // 4 MiB into a hole; the second rewrites the same 2 MiB.
        try write(first.appendingPathComponent("Disk.img"), at: 1 << 20, count: 2 << 20, byte: 0x33)
        try write(first.appendingPathComponent("Disk.img"), at: 128 << 20, count: 4 << 20, byte: 0x44)
        try write(second.appendingPathComponent("Disk.img"), at: 1 << 20, count: 2 << 20, byte: 0x55)
        let folders: [VPhoneLaunchpadDiskMeter.Folder] = [.init(path: template.path), .init(path: first.path), .init(path: second.path)]
        let usage = await meter.measure(folders)
        let templateUsage = try require(usage[template.path]?.exclusive, "Template measured")
        let firstUsage = try require(usage[first.path]?.exclusive, "First measured")
        let secondUsage = try require(usage[second.path]?.exclusive, "Second measured")
        // The template keeps the 2 MiB both clones rewrote to itself.
        precondition(templateUsage == 2 << 20, "Template: \(templateUsage)")
        precondition(firstUsage == 6 << 20, "First: \(firstUsage)")
        precondition(secondUsage == 2 << 20, "Second: \(secondUsage)")
        let firstAllocated = try allocatedBytes(first.appendingPathComponent("Disk.img"))
        precondition(usage[first.path]?.allocated == firstAllocated, "Allocated")

        // A folder that may not be opened keeps the extents last mapped; one
        // never mapped is unknown, and does not open its files.
        let third = library.appendingPathComponent("third", isDirectory: true)
        try fm.createDirectory(at: third, withIntermediateDirectories: true)
        precondition(clonefile(disk.path, third.appendingPathComponent("Disk.img").path, 0) == 0, "clonefile")
        try write(first.appendingPathComponent("Disk.img"), at: 192 << 20, count: 1 << 20, byte: 0x66)
        let busy = await meter.measure([.init(path: template.path), .init(path: first.path, mayOpen: false), .init(path: second.path), .init(path: third.path, mayOpen: false)])
        precondition(busy[first.path]?.exclusive == 6 << 20, "Last mapped: \(String(describing: busy[first.path]))")
        precondition(busy[third.path]?.exclusive == nil && (busy[third.path]?.allocated ?? 0) >= 16 << 20,
                     "Never mapped: \(String(describing: busy[third.path]))")
        let open = await meter.measure([.init(path: template.path), .init(path: first.path), .init(path: second.path), .init(path: third.path)])
        precondition(open[first.path]?.exclusive == 7 << 20, "Mapped again once changed: \(String(describing: open[first.path]))")
        // The third clone shares everything it holds.
        precondition(open[third.path]?.exclusive == 0, "Third: \(String(describing: open[third.path]))")
        precondition(open[template.path]?.exclusive == 0, "Template with a clone that wrote nothing: \(String(describing: open[template.path]))")

        // Links are not followed.
        try fm.createSymbolicLink(at: second.appendingPathComponent("link.img"), withDestinationURL: disk)
        let linked = await meter.measure([.init(path: second.path)])
        precondition(linked[second.path]?.allocated == usage[second.path]?.allocated, "A link is not followed")
    }

    static func write(_ file: URL, at offset: UInt64, count: Int, byte: UInt8) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(repeating: byte, count: count))
        try handle.synchronize()
        try handle.close()
    }

    static func truncate(_ file: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: size)
        try handle.close()
    }

    static func allocatedBytes(_ file: URL) throws -> Int64 {
        var status = stat()
        precondition(lstat(file.path, &status) == 0, "lstat \(file.path)")
        return Int64(status.st_blocks) * 512
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            preconditionFailure(message)
        }
        return value
    }
}
