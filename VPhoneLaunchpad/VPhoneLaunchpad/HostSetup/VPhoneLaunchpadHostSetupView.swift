import SwiftUI

struct VPhoneLaunchpadHostSetupView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VPhoneLaunchpadMenuBar.key) private var showsInMenuBar = false
    @State private var showsSkillInstall = false
    @State private var confirmsRelease = false

    private var host: VPhoneLaunchpadHostSetup {
        model.host
    }

    var body: some View {
        @Bindable var host = host
        @Bindable var leases = model.leases
        VPhoneLaunchpadSheet(Text("Host Setup")) {
            form
        } accessory: {
            Button("Check Again") {
                Task { await model.refreshHost() }
            }
            .help("Run every check again")
            .disabled(host.isChecking)
            Button("Install Skill…") { showsSkillInstall = true }
                .help("Give your coding agent the vphone skill")
        } actions: {
            // Straight on to the next stage while it is not ready.
            if host.requiredPassed, !model.bundles.isReady {
                Button("Continue") { model.present(.coreBundle) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 600, height: 600)
        .sheet(isPresented: $showsSkillInstall) {
            VPhoneLaunchpadSkillInstallView()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            host.refreshDeveloperTools()
        }
        .errorAlert($host.actionError)
        .errorAlert($leases.actionError)
        .task { await model.leases.refresh() }
        .confirmationDialog(
            "Release \(model.leases.orphans.count) Addresses?",
            isPresented: $confirmsRelease,
        ) {
            Button("Release") {
                Task { await model.leases.releaseFromUI() }
            }
        } message: {
            Text("Their leases have run out and no machine in your libraries has their MAC. A guest that comes back with one of these MACs gets a new address.")
        }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(host.required) { check in
                    row(check)
                }
            } header: {
                HStack {
                    Text("Required")
                    Spacer()
                    Text("\(host.passedRequiredCount) of \(host.required.count) passed")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if !host.requiredPassed {
                    VStack(alignment: .leading, spacing: 4) {
                        if host.checks.contains(where: { $0.kind == .developerTools && $0.status != .passed }) {
                            Text("Allow vphone-launchpad in Privacy & Security → Developer Tools, then click Reopen.")
                        }
                        Text("A Core Bundle can be installed once every required check passes.")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(host.advisory) { check in
                    row(check)
                }
            } header: {
                Text("Advisory")
            } footer: {
                Text("Advisory checks do not block setup.")
                    .foregroundStyle(.secondary)
            }

            Section {
                leasesRow
            } header: {
                Text("NAT Network")
            } footer: {
                Text("The Mac’s DHCP server keeps an address for every guest MAC it has seen, even after the lease runs out. Release frees the addresses of iOS guests no machine uses any more, such as deleted machines. It needs an administrator.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep in Menu Bar", isOn: $showsInMenuBar)
            } footer: {
                Text("Closing the window keeps Launchpad in the menu bar, where you can start and stop machines. The Dock icon appears only while a window or the menu is open.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Icon, title, then detail and any action pinned to the trailing edge.
    /// A plain HStack rather than LabeledContent: LabeledContent splits the
    /// row into columns and truncated the detail while leaving the button
    /// short of the edge.
    private func row(_ check: VPhoneLaunchpadHostCheck) -> some View {
        let isSkipped = host.isSkipped(check)
        return HStack(spacing: 8) {
            VPhoneLaunchpadStatusIcon(status: isSkipped ? .warning : check.status)
            Text(check.title)
                .layoutPriority(1)
            Spacer(minLength: 16)
            Text(isSkipped ? String(localized: "Skipped · \(check.detail)") : check.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(check.detail)
            action(for: check)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func action(for check: VPhoneLaunchpadHostCheck) -> some View {
        switch check.kind {
        case .developerTools where check.status != .passed:
            HStack(spacing: 8) {
                if host.canRequestDeveloperTools {
                    Button("Open Settings") {
                        Task { await host.requestDeveloperTools() }
                    }
                }
                if host.needsRelaunch {
                    Button("Reopen") {
                        // The sheet is still attached when its dismiss handler
                        // runs; relaunch on the turn after it has gone.
                        model.afterSheetDismissed { host.relaunch() }
                        dismiss()
                    }
                }
            }
        case .helper where check.status == .pending:
            Button(host.helper.state == .notInstalled ? "Install…" : "Update…") {
                Task {
                    await host.installHelper()
                    await model.refreshHost()
                }
            }
        default:
            if host.isSkipped(check) {
                Button("Don’t Skip") { host.setSkipped(check.kind, false) }
            } else if host.canSkip(check) {
                Button("Skip") { host.setSkipped(check.kind, true) }
                    .help("Continue without this check. The Core Bundle still runs its own checks.")
            }
        }
    }

    // MARK: - NAT leases

    private var leasesRow: some View {
        let leases = model.leases
        let (status, detail) = leasesStatus
        return HStack(spacing: 8) {
            VPhoneLaunchpadStatusIcon(status: status)
            Text("Addresses held by old guests")
                .layoutPriority(1)
            Spacer(minLength: 16)
            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(detail)
            if !leases.orphans.isEmpty {
                Button("Release…") { confirmsRelease = true }
                    .disabled(leases.isReleasing || !model.canReleaseLeases)
                    .fixedSize()
            }
        }
    }

    private var leasesStatus: (VPhoneLaunchpadStatus, String) {
        let leases = model.leases
        if leases.isReleasing {
            return (.running, String(localized: "Waiting for administrator approval…"))
        }
        switch leases.state {
        case .unknown, .checking:
            return (.running, String(localized: "Checking…"))
        case let .unavailable(reason):
            return (.pending, reason)
        case let .failed(reason):
            return (.warning, reason)
        case .listed:
            let count = leases.orphans.count
            return count == 0
                ? (.passed, String(localized: "None"))
                : (.warning, String(localized: "\(count) addresses no machine uses"))
        }
    }
}
