import AppKit
import SwiftUI

// MARK: - State label

/// A machine's run state as the table and the inspector show it.
struct VPhoneLaunchpadMachineStateLabel: View {
    let state: VPhoneLaunchpadMachineLibrary.RunState
    /// An export's or a creation's IPSW download progress, shown as a bar in
    /// place of the activity text, which becomes its help tag.
    var progress: Double?

    var body: some View {
        let (status, text): (VPhoneLaunchpadStatus, String) = switch state {
        case .running: (.passed, String(localized: "Running"))
        case .stopped: (.pending, String(localized: "Stopped"))
        case let .busy(activity): (.running, activity)
        }
        if let progress {
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .controlSize(.small)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .help(text)
        } else {
            Label {
                Text(text).lineLimit(1)
            } icon: {
                VPhoneLaunchpadStatusIcon(status: status)
            }
        }
    }
}

// MARK: - Core Bundle label

/// The version a machine runs with, as the table shows it, with a warning
/// when that version is gone or the guest environment came from another.
struct VPhoneLaunchpadMachineBundleLabel: View {
    let machine: VPhoneLaunchpadMachinePath
    @Environment(VPhoneLaunchpadModel.self) private var model

    var body: some View {
        let library = model.machines
        let version = library.bundleVersion(for: machine)
        let warning: String? = if let version, !model.bundles.selectableVersions.contains(version) {
            String(localized: "VPhone.bundle \(version) is not installed. Choose Change Core Bundle… to run this machine with another version.")
        } else if let binding = library.bindings[machine], binding.hasMixedVersions, let guest = binding.guestEnvironment {
            String(localized: "The guest environment is from \(guest).") + " " + VPhoneLaunchpadMachineInspector.mixedHelp
        } else {
            nil
        }
        HStack(spacing: 4) {
            Text(verbatim: version ?? "—")
                .lineLimit(1)
                .truncationMode(.middle)
            if warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .imageScale(.small)
            }
        }
        .help(warning ?? version ?? "")
    }
}

// MARK: - Inspector

/// The trailing inspector for the selected machine. Values are split into
/// short rows, since the column is narrow, and long ones truncate in the
/// middle.
struct VPhoneLaunchpadMachineInspector: View {
    let machine: VPhoneLaunchpadMachine
    let onShowProgress: (VPhoneLaunchpadMachinePath) -> Void
    let onOpenConsole: (VPhoneLaunchpadMachinePath) -> Void
    var onChangeBundle: (VPhoneLaunchpadMachine) -> Void = { _ in }
    var onOpenGuestSystem: (VPhoneLaunchpadMachinePath) -> Void = { _ in }
    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var showsCommands = false
    @State private var patchCatalog: VPhoneLaunchpadPatchCatalog?
    @State private var patchCatalogError: String?
    /// The machine the catalogue above was read for, so another machine's
    /// patches never show while its own are read.
    @State private var patchCatalogMachine: VPhoneLaunchpadMachinePath?
    /// The choice the patch editor opens with, set when it is shown.
    @State private var editedPatches: VPhoneLaunchpadPatchSelection?
    /// Bumped after a save or an update, so the patches are read again.
    @State private var patchRevision = 0

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        Form {
            Section {
                if let creation = library.creation(for: machine.path) {
                    creationSummary(creation)
                }
                LabeledContent("State") {
                    VPhoneLaunchpadMachineStateLabel(
                        state: library.state(of: machine.path),
                        progress: library.progress(of: machine.path),
                    )
                }
                if let started = library.startedAt[machine.path] {
                    LabeledContent("Started", value: started.formatted(date: .omitted, time: .shortened))
                }
                if let firmwareName = machine.firmwareName {
                    LabeledContent("Firmware", value: firmwareName)
                }
            } header: {
                Text(machine.name)
                    .font(.headline)
            }

            Section("Firmware") {
                if let info = machine.restoreInfo {
                    LabeledContent(machine.osName, value: "\(info.ios.version) (\(info.ios.build))")
                    LabeledContent("cloudOS", value: "\(info.cloudOS.version) (\(info.cloudOS.build))")
                } else {
                    Text("Not restored").foregroundStyle(.secondary)
                }
            }

            coreBundleSection

            patchesSection

            Section("Hardware") {
                LabeledContent("CPU", value: String(localized: "\(machine.cpuCount) cores"))
                LabeledContent("Memory", value: VPhoneLaunchpadMachinesView.memory(machine.memoryMB))
                LabeledContent("Disk", value: VPhoneLaunchpadMachinesView.disk(machine.diskSizeBytes))
                if let usage = library.diskUsage[machine.path] {
                    if let exclusive = usage.exclusive {
                        LabeledContent("Exclusive") {
                            Text(VPhoneLaunchpadDiskUsage.format(exclusive))
                                .help(String(localized: "The blocks no other machine or template holds: what deleting it frees, once no local Time Machine snapshot keeps them. The rest is shared with its template or clones."))
                        }
                    }
                    LabeledContent("Allocated") {
                        Text(VPhoneLaunchpadDiskUsage.format(usage.allocated))
                            .help(String(localized: "Every block the machine's files hold, shared or not."))
                    }
                }
                LabeledContent("Network", value: machine.networkDescription)
                if let address = machine.addressDescription {
                    LabeledContent("IPv4 Address", value: address)
                }
                if !machine.network.macAddress.isEmpty {
                    LabeledContent("MAC Address", value: machine.network.macAddress)
                }
                if let name = machine.network.localHostName {
                    LabeledContent("mDNS Name", value: "\(name).local")
                }
                ForEach(machine.network.portForwards ?? [], id: \.self) { forward in
                    LabeledContent("Port Forward", value: "\(forward.transport.uppercased()) \(forward.hostAddress ?? "127.0.0.1"):\(forward.hostPort) → \(forward.guestPort)")
                }
                if machine.unlocksAtStartup == true {
                    LabeledContent("Unlock at Startup", value: String(localized: "On"))
                }
                if machine.syncsHostLocation == true {
                    LabeledContent("Sync Host Location", value: String(localized: "On"))
                }
            }

            Section("Identity") {
                if let udid = machine.udid {
                    value("UDID", udid)
                }
                if let origin = library.templateSources[machine.path] {
                    LabeledContent("Template") {
                        templateLabel(origin)
                            .textSelection(.enabled)
                    }
                }
                value(
                    "Location",
                    VPhoneLaunchpadHostSetup.abbreviated(machine.path.url),
                )
            }

            Section {
                HStack {
                    Text("Service profile and removed system apps")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Guest System…") { onOpenGuestSystem(machine.path) }
                        .disabled(library.creation(for: machine.path)?.isRunning == true)
                }
            } header: {
                Text("Guest System")
            }

            Section("Console") {
                HStack {
                    Button {
                        onOpenConsole(machine.path)
                    } label: {
                        Label("Open Console", systemImage: "arrow.up.right")
                    }
                    Spacer()
                    Button("Recent Commands") { showsCommands = true }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: patchReadKey) {
            await loadPatches()
        }
        .sheet(isPresented: $showsCommands) {
            VPhoneLaunchpadCommandHistoryView()
                .environment(model)
        }
        .sheet(item: $editedPatches) { initial in
            let path = machine.path
            VPhoneLaunchpadPatchSettingsView(
                initial: initial,
                bundleVersion: library.bundleVersion(for: path),
                machine: path,
            ) { selection in
                Task {
                    await library.setPatches(selection, for: path)
                    patchRevision += 1
                }
            }
            .environment(model)
        }
    }

    static var mixedHelp: String {
        String(localized: "The host programs and the guest environment come from different Core Bundles. Update the guest environment to match.")
    }

    // MARK: - Core Bundle

    /// The three layers a bundle provides, each from the bundle that last
    /// wrote it. A new binding reaches the host programs at the next start
    /// and the guest environment when it is updated, never the boot chain.
    private var coreBundleSection: some View {
        let binding = library.bindings[machine.path]
        let version = library.bundleVersion(for: machine.path)
        let isInstalled = version.map(model.bundles.selectableVersions.contains) ?? false
        return Section("Core Bundle") {
            layer(
                "Host Programs",
                version ?? String(localized: "Unknown"),
                warning: isInstalled ? nil : version.map { String(localized: "VPhone.bundle \($0) is not installed.") },
                help: String(localized: "vphone-cli and vphone-vm come from this bundle at every start."),
            )
            layer(
                "Guest Environment",
                binding?.guestEnvironment ?? String(localized: "Unknown"),
                warning: binding?.hasMixedVersions == true ? Self.mixedHelp : nil,
                help: String(localized: "vphoned and the hook libraries in the guest."),
            )
            layer(
                "Boot Chain",
                binding?.bootChain ?? String(localized: "Unknown"),
                help: String(localized: "The Core Bundle that built the boot chain when the machine was created."),
            )
            HStack {
                Spacer()
                Button("Change…") { onChangeBundle(machine) }
                    .disabled(model.bundles.selectableVersions.isEmpty || library.creation(for: machine.path)?.isRunning == true)
            }
        }
    }

    // MARK: - Patches

    /// What a patch read depends on: the machine, the bundle that reads it,
    /// and the run state, so a finished update or install is read again.
    private struct PatchReadKey: Equatable {
        let machine: VPhoneLaunchpadMachinePath
        let bundle: String?
        let state: VPhoneLaunchpadMachineLibrary.RunState
        let revision: Int
    }

    private var patchReadKey: PatchReadKey {
        PatchReadKey(
            machine: machine.path,
            bundle: library.bundleVersion(for: machine.path),
            state: library.state(of: machine.path),
            revision: patchRevision,
        )
    }

    /// The machine's patch choice: the preset, how many boxes differ from
    /// it, and, when the machine's bundle reports it, how many patches have
    /// not reached the guest yet. An older bundle does not report the last,
    /// and the row is left out. Edit opens the patch editor on this machine;
    /// Apply to Guest updates the guest environment, which is what brings
    /// guest patches in line. Boot-chain patches only a restore changes.
    @ViewBuilder
    private var patchesSection: some View {
        if library.creation(for: machine.path)?.isRunning != true {
            Section("Patches") {
                if let catalog = patchCatalog, patchCatalogMachine == machine.path {
                    LabeledContent(
                        "Preset",
                        value: catalog.preset(catalog.activePreset)?.displayTitle ?? catalog.activePreset,
                    )
                    LabeledContent("Overrides") {
                        Text(catalog.overrideCount == 0
                            ? String(localized: "None")
                            : String(localized: "\(catalog.overrideCount) changed from the preset"))
                            .help(overridesHelp(catalog))
                    }
                    if catalog.installed == true, let pending = catalog.pendingPatches {
                        LabeledContent("Not Applied") {
                            HStack(spacing: 4) {
                                if pending > 0 {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                        .imageScale(.small)
                                }
                                if pending == 0 {
                                    Text("None")
                                } else {
                                    Text("^[\(pending) patch](inflect: true)")
                                }
                            }
                            .help(pendingHelp(catalog, pending: pending))
                        }
                        // The kernelcache has its own button below; only the
                        // restore-only patches need this spelled-out dead-end.
                        if catalog.pendingRestorePatches > 0 {
                            Text("Boot chain: ^[\(catalog.pendingRestorePatches) patch](inflect: true) (TXM, device tree, LLB) not applied; only a restore applies them, which erases the data. Run `vphone-cli fw patches \(machine.name)` for each.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Spacer()
                        if catalog.installed == true, catalog.pendingKernelPatches > 0 {
                            Button("Update Kernel") {
                                Task {
                                    await library.updateKernel(machine.path)
                                    patchRevision += 1
                                }
                            }
                            .disabled(library.state(of: machine.path) != .stopped)
                            .help(library.state(of: machine.path) == .stopped
                                ? String(localized: "Swaps the Preboot kernelcache for the one this machine's patches resolve to, keeping the data (no restore).")
                                : String(localized: "Stop the machine to update its kernel."))
                        }
                        if catalog.installed == true, catalog.pendingGuestPatches > 0 {
                            Button("Apply to Guest") {
                                Task {
                                    await library.updateGuestEnvironment(machine.path)
                                    patchRevision += 1
                                }
                            }
                            .disabled(library.state(of: machine.path) != .stopped)
                            .help(library.state(of: machine.path) == .stopped
                                ? String(localized: "Updates the guest environment, which turns guest patches on or off to match this machine’s choice.")
                                : String(localized: "Stop the machine to apply its patch choice to the guest."))
                        }
                        Button("Edit…") { editedPatches = catalog.selection }
                    }
                } else if let patchCatalogError {
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                        .help(patchCatalogError)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func pendingHelp(_ catalog: VPhoneLaunchpadPatchCatalog, pending: Int) -> String {
        guard pending > 0 else {
            return String(localized: "The guest has every patch this machine is set to.")
        }
        var lines: [String] = []
        if catalog.pendingGuestPatches > 0 {
            lines.append(String(localized: "^[\(catalog.pendingGuestPatches) guest patch](inflect: true) to apply with Apply to Guest."))
        }
        if catalog.pendingKernelPatches > 0 {
            lines.append(String(localized: "^[\(catalog.pendingKernelPatches) kernel patch](inflect: true) to apply with Update Kernel (keeps the data)."))
        }
        if catalog.pendingRestorePatches > 0 {
            lines.append(String(localized: "^[\(catalog.pendingRestorePatches) boot chain patch](inflect: true) that only a restore applies."))
        }
        lines.append(String(localized: "vphone-cli fw patches \(machine.name) lists each one."))
        return lines.joined(separator: "\n")
    }

    private func overridesHelp(_ catalog: VPhoneLaunchpadPatchCatalog) -> String {
        var lines: [String] = []
        if !catalog.blockedPatches.isEmpty {
            lines.append(String(localized: "Off: \(catalog.blockedPatches.joined(separator: ", "))"))
        }
        if !catalog.allowedPatches.isEmpty {
            lines.append(String(localized: "On: \(catalog.allowedPatches.joined(separator: ", "))"))
        }
        return lines.joined(separator: "\n")
    }

    private func loadPatches() async {
        let path = machine.path
        if patchCatalogMachine != path {
            patchCatalog = nil
            patchCatalogError = nil
            patchCatalogMachine = path
        }
        guard library.creation(for: path)?.isRunning != true else { return }
        do {
            let catalog = try await VPhoneLaunchpadPatchCatalog.read(
                using: library.commandLine(for: path),
                machine: path,
                preset: nil,
            )
            guard path == machine.path else { return }
            patchCatalog = catalog
            patchCatalogError = nil
        } catch is CancellationError {
            return
        } catch {
            guard path == machine.path else { return }
            patchCatalog = nil
            patchCatalogError = VPhoneLaunchpadError.message(for: error)
        }
    }

    private func layer(_ title: LocalizedStringKey, _ value: String, warning: String? = nil, help: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                if warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .imageScale(.small)
                }
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .help(warning ?? help)
        }
    }

    private func value(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }

    /// The template's identifier. A clone of an earlier build of the same
    /// key, or of a deleted template, says so, and shares no key with the
    /// template that has the identifier now.
    @ViewBuilder
    private func templateLabel(_ origin: VPhoneLaunchpadTemplateOrigin) -> some View {
        switch origin.match {
        case .current:
            Text(verbatim: origin.identifier)
                .help(String(localized: "Created from this template. It shares the template's SEP root secret and Data volume keys with every machine created from it."))
        case .earlierBuild:
            Text("\(origin.identifier) (earlier build, deleted)")
                .help(String(localized: "Created from an earlier build of this template, since deleted. It shares its SEP root secret and Data volume keys only with the machines created from that build, not with the template that has this identifier now or the machines created from it."))
        case .deleted:
            Text("\(origin.identifier) (deleted)")
                .help(String(localized: "Created from this template, which was deleted. It shares the template's SEP root secret and Data volume keys with every machine created from it."))
        }
    }

    private func creationSummary(_ creation: VPhoneLaunchpadCreationPipeline) -> some View {
        LabeledContent {
            Button(creation.isRunning ? LocalizedStringKey("Show Progress") : LocalizedStringKey("View Details")) {
                onShowProgress(creation.machine)
            }
        } label: {
            if creation.isRunning {
                Label { Text("Creating: \(creation.current?.title ?? "")") } icon: { VPhoneLaunchpadStatusIcon(status: .running) }
            } else if creation.isFinished {
                Label { Text("Created") } icon: { VPhoneLaunchpadStatusIcon(status: .passed) }
            } else {
                Label { Text(creation.failure?.message ?? String(localized: "Creation stopped")) } icon: { VPhoneLaunchpadStatusIcon(status: .failed) }
            }
        }
    }
}
