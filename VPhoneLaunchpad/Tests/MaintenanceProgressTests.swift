import Foundation

/// How the maintenance sheet reads `cfw update-environment` output: the step
/// under way from unindented markers, and every warning at any depth, over
/// the lines a real run prints.
@main
struct MaintenanceProgressTests {
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        precondition(condition, "line \(line): \(message())")
    }

    static func main() {
        stages()
        warnings()
        notable()
        print("Maintenance progress tests passed: stages, warnings, notable lines")
    }

    /// Lines as an environment update prints them, in order.
    static let sample = [
        "$ vphone-cli cfw update-environment fz-b",
        "[*] Patch preset: standard  (126 patches on)",
        "/dev/disk8  \tGUID_partition_scheme",
        "[*] Guest Environment Update: fz-b",
        "  [·] usr/lib/libmisfix.plist: already present, left as it is",
        "      [+] 0x1BDD2: 2573 -> 4141 (\"%s/%s.gl\" -> \"%s/AA.gl\")",
        "  [+] seputil gigalocker name pinned to \"AA.gl\"",
        "  [!] system-launchd-cfw-jetsam: patch step failed, left in its prior state: not found",
        "warning: could not mark the install as in progress: EPERM",
        "  Before: pacibsp; stp x22, x21, [sp, #-0x30]!",
        "[*] Board device tree: FirmwareOriginals/iPhone17,3/DeviceTree.d47ap.im4p",
        "  [+] product/product-name: 'syscfg/prde' -> 'iPhone 16'",
        "[!] 1 guest patch(es) failed and were left in their prior state: system-launchd-cfw-jetsam",
        "[+] Guest environment updated; start the VM to pick it up",
    ]

    static func read(_ lines: [String]) -> VPhoneLaunchpadMaintenanceProgress {
        var progress = VPhoneLaunchpadMaintenanceProgress()
        for line in lines {
            progress.read(line)
        }
        return progress
    }

    static func stages() {
        expect(read([]).stage == nil, "no output has no stage")
        expect(read(Array(sample.prefix(3))).stage == "Patch preset: standard  (126 patches on)", "the first step")
        // Indented markers are detail within a step, not a step.
        expect(read(Array(sample.prefix(8))).stage == "Guest Environment Update: fz-b", "indented lines leave the step")
        expect(read(Array(sample.prefix(12))).stage?.hasPrefix("Board device tree:") == true, "a later step replaces it")
        expect(read(sample).stage == "Guest environment updated; start the VM to pick it up", "the closing line")
        expect(read(["[*] Step", "[*]   "]).stage == "Step", "an empty marker keeps the step")
    }

    static func warnings() {
        let progress = read(sample)
        expect(progress.warningCount == 3, "three warnings, got \(progress.warningCount)")
        expect(progress.warnings == [
            "system-launchd-cfw-jetsam: patch step failed, left in its prior state: not found",
            "warning: could not mark the install as in progress: EPERM",
            "1 guest patch(es) failed and were left in their prior state: system-launchd-cfw-jetsam",
        ], "warnings in order, markers removed: \(progress.warnings)")
        expect(read(["Error: Unknown option '--work-parent'"]).warningCount == 1, "an argument error warns")
        expect(read(["[!]", "  [!]   "]).warningCount == 0, "a bare marker does not warn")
        expect(read(["the warning: is not at the start"]).warningCount == 0, "only a leading warning: counts")

        let many = read((0 ..< 80).map { "[!] step \($0)" })
        expect(many.warningCount == 80, "every warning is counted")
        expect(many.warnings.count == VPhoneLaunchpadMaintenanceProgress.maximumWarnings, "only the first are kept")
        expect(many.warnings.first == "step 0", "the first is kept first")
    }

    /// Only lines that change the progress cross to the main actor; reading
    /// just those must give what reading every line gives.
    static func notable() {
        let notable = sample.filter(VPhoneLaunchpadMaintenanceProgress.isNotable)
        expect(read(notable) == read(sample), "the notable lines carry the whole progress")
        expect(notable.count == 7, "seven notable lines, got \(notable.count)")
        expect(!VPhoneLaunchpadMaintenanceProgress.isNotable("  [+] seputil gigalocker name pinned"), "detail is not notable")
    }
}
