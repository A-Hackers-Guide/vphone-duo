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

        var finished: String {
            switch self {
            case .installCustomFirmware: String(localized: "Custom firmware installed.")
            case .updateGuestEnvironment: String(localized: "Guest environment updated.")
            case .updateKernel: String(localized: "Kernel updated.")
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

/// A maintenance run's progress: the step under way, how long it has taken,
/// the steps that warned, and its output as it arrives. It follows the
/// machine's latest run, so it stays useful when another one starts.
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
                if let run {
                    summary(run)
                    if !run.progress.warnings.isEmpty {
                        warnings(run.progress)
                    }
                }
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
        // A failure shown here is not raised as an alert as well.
        .onAppear { library.showsMaintenance.insert(machine) }
        .onDisappear { library.showsMaintenance.remove(machine) }
    }

    private func summary(_ run: VPhoneLaunchpadMaintenanceRun) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VPhoneLaunchpadStatusIcon(status: run.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: headline(run))
                if let stage = run.progress.stage, run.isRunning || !run.succeeded {
                    Text(verbatim: stage)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(stage)
                }
                if let detail = run.failure?.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
            }
            Spacer(minLength: 16)
            VPhoneLaunchpadMaintenanceElapsed(run: run)
        }
    }

    private func headline(_ run: VPhoneLaunchpadMaintenanceRun) -> String {
        if run.isRunning {
            return run.kind.activity
        }
        if run.succeeded {
            return run.kind.finished
        }
        return run.failure?.message ?? String(localized: "Unable to Complete Action")
    }

    private func warnings(_ progress: VPhoneLaunchpadMaintenanceProgress) -> some View {
        DisclosureGroup {
            ScrollView {
                Text(verbatim: progress.warnings.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        } label: {
            Label {
                Text("^[\(progress.warningCount) warning](inflect: true)")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
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
