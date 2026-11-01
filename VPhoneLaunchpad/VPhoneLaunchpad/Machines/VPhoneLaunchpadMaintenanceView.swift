import AppKit
import Observation
import SwiftUI

// MARK: - Run

/// One `cfw install`, `cfw update-environment` or `cfw update-kernel` the
/// helper runs on a stopped machine. Its output goes to a log of its own,
/// which the progress sheet follows, as well as to the machine's console
/// log; the model keeps only the step under way and the lines that warn.
@MainActor
@Observable
final class VPhoneLaunchpadMaintenanceRun {
    enum Kind: Sendable {
        case installCustomFirmware
        case updateGuestEnvironment
        case updateKernel

        var title: String {
            switch self {
            case .installCustomFirmware: String(localized: "Install Custom Firmware")
            case .updateGuestEnvironment: String(localized: "Update Guest Environment")
            case .updateKernel: String(localized: "Update Kernel")
            }
        }

        /// The machine's state while it runs.
        var activity: String {
            switch self {
            case .installCustomFirmware: String(localized: "Installing custom firmware…")
            case .updateGuestEnvironment: String(localized: "Updating guest environment…")
            case .updateKernel: String(localized: "Updating kernel…")
            }
        }

        var failure: String {
            switch self {
            case .installCustomFirmware: String(localized: "Unable to install custom firmware. Check the log for details.")
            case .updateGuestEnvironment: String(localized: "Unable to update the guest environment.")
            case .updateKernel: String(localized: "Unable to update the kernel.")
            }
        }

        func sheetTitle(_ machine: String) -> String {
            switch self {
            case .installCustomFirmware: String(localized: "Install Custom Firmware on \(machine)")
            case .updateGuestEnvironment: String(localized: "Update Guest Environment of \(machine)")
            case .updateKernel: String(localized: "Update Kernel of \(machine)")
            }
        }

        var command: String {
            switch self {
            case .installCustomFirmware: "cfw install"
            case .updateGuestEnvironment: "cfw update-environment"
            case .updateKernel: "cfw update-kernel"
            }
        }
    }

    let kind: Kind
    let machine: VPhoneLaunchpadMachinePath
    let startedAt = Date()
    private(set) var finishedAt: Date?
    private(set) var succeeded = false
    private(set) var progress = VPhoneLaunchpadMaintenanceProgress()
    /// Set by the caller once the run has failed, in the words the alert
    /// would use.
    var failure: VPhoneLaunchpadError?
    let log: VPhoneLaunchpadLogWriter

    init(kind: Kind, machine: VPhoneLaunchpadMachinePath) {
        self.kind = kind
        self.machine = machine
        log = VPhoneLaunchpadLogWriter(url: VPhoneLaunchpadMachineLibrary.consoleLog(machine, suffix: "-maintenance"))
    }

    var isRunning: Bool {
        finishedAt == nil
    }

    var status: VPhoneLaunchpadStatus {
        if isRunning {
            return .running
        }
        if !succeeded {
            return .failed
        }
        return progress.warningCount > 0 ? .warning : .passed
    }

    func read(_ line: String) {
        progress.read(line)
    }

    func finish(succeeded: Bool) {
        self.succeeded = succeeded
        finishedAt = Date()
    }
}

// MARK: - Sheet

/// A maintenance run's output as it arrives. It follows the machine's latest
/// run, so it stays useful when another one starts.
struct VPhoneLaunchpadMaintenanceView: View {
    let machine: VPhoneLaunchpadMachinePath
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        let run = library.maintenance[machine]
        VPhoneLaunchpadSheet(
            Text(verbatim: run?.kind.sheetTitle(machine.name) ?? machine.name),
            width: VPhoneLaunchpadSheetSize.wide,
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VPhoneLaunchpadLogTerminal(url: VPhoneLaunchpadMachineLibrary.consoleLog(machine, suffix: "-maintenance"))
                    .frame(maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } accessory: {
            Button("Open Log File") {
                NSWorkspace.shared.open(VPhoneLaunchpadMachineLibrary.consoleLog(machine, suffix: "-maintenance"))
            }
            if run?.isRunning == true {
                Text("It continues if you close this window.")
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - Elapsed

/// How long a run has taken: counting while it runs, fixed once it ends.
struct VPhoneLaunchpadMaintenanceElapsed: View {
    let run: VPhoneLaunchpadMaintenanceRun

    var body: some View {
        Group {
            if let finishedAt = run.finishedAt {
                Text(verbatim: VPhoneLaunchpadCreationView.duration(finishedAt.timeIntervalSince(run.startedAt)))
            } else {
                Text(run.startedAt, style: .timer)
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}
