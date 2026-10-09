import ArgumentParser
import Foundation
import VPhoneCoreKit

// MARK: - rebase

/// `vm rebase`: re-share a stopped machine's disk image with another's.
struct VPhoneVirtualMachineRebaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebase",
        abstract: "Share a stopped VM's identical disk blocks with another VM",
        discussion: """
        Compares the disk images of two stopped VMs and rebuilds the first one's from an \
        APFS clone of the base's, writing only the blocks that differ. Wherever both images \
        hold the same bytes at the same offset (for VMs restored from the same IPSW, most of \
        the system volume), the blocks are then stored once for both. Every byte is checked \
        against the original before it is replaced, so the guest sees exactly the same disk; \
        SEPStorage, nvram.bin, config.plist and the device identity are not touched.

        Both VMs must be stopped and on one APFS volume. The rebase needs free space for the \
        blocks it writes until the old image is released.

        The space comes back only if nothing else holds the old image's blocks: snapshots of \
        the VM, and clones made from it, keep them. du and Finder still report the full size \
        of each image; free space on the volume is the honest measure. The two images drift \
        apart again as either VM writes to its disk, so a base that is never booted, such as \
        a freshly restored template, makes the best base.

        --dry-run only compares the images and reports what a rebase would share and write.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM whose disk image is rebased") var name: String?
    @Option(name: .long, help: "VM whose disk blocks it shares") var onto: String
    @Flag(help: "only report what would be shared and written") var dryRun = false

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let target = try lib.library.bundle(named: name)
        let base = try lib.library.bundle(named: onto)

        let clock = ContinuousClock()
        let start = clock.now
        var bar: VPhoneProgressBar?
        var phase: VPhoneDiskRebase.Phase?
        let progress: VPhoneDiskRebase.Progress = { current, done, total in
            if current != phase {
                bar?.finish()
                phase = current
                bar = VPhoneProgressBar(label: current == .comparing ? "comparing" : "verifying")
            }
            bar?.update(done: done, total: total)
        }
        let report = dryRun
            ? try VPhoneDiskRebase.plan(target, onto: base, progress: progress)
            : try VPhoneDiskRebase.rebase(target, onto: base, progress: progress)
        bar?.finish()
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let elapsedText = VPhoneProgressBar.clock(seconds)
        if dryRun {
            print("dry run: compared \(target.name) with \(base.name) in \(elapsedText); nothing was changed")
        } else {
            print("rebased \(target.name) onto \(base.name) in \(elapsedText)")
        }
        for line in Self.describe(report, base: base.name, dryRun: dryRun) {
            print("  " + line)
        }
        if !dryRun, let snapshots = try? VPhoneMachineSnapshots.list(of: target), !snapshots.isEmpty {
            print("note: \(target.name) has \(snapshots.count) snapshot(s), which keep the old image's blocks until deleted")
        }
    }

    /// The report as aligned lines, in decimal gigabytes like disk sizes.
    static func describe(_ report: VPhoneDiskRebaseReport, base: String, dryRun: Bool) -> [String] {
        let rows: [(String, Int64, String)] = [
            ("disk image", report.logicalSize, "logical size; \(gigabytes(report.comparedBytes)) holds data in either image"),
            ("shared", report.sharedBytes, dryRun
                ? "identical to \(base) at the same offset, would be shared"
                : "identical to \(base) at the same offset, now shared"),
            ("written", report.writtenBytes, dryRun ? "differs from \(base), would be written" : "differs from \(base), written"),
            ("punched", report.punchedBytes, dryRun ? "zeros where \(base) has data, would become holes" : "zeros where \(base) has data, now holes"),
        ]
        let sizes = rows.map { gigabytes($0.1) }
        let width = sizes.map(\.count).max() ?? 0
        return zip(rows, sizes).map { row, size in
            row.0.padding(toLength: 12, withPad: " ", startingAt: 0)
                + String(repeating: " ", count: width - size.count) + size + "  " + row.2
        }
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1e9)
    }
}
