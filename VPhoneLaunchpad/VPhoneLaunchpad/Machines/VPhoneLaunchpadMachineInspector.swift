import AppKit
import SwiftUI

// MARK: - State label

/// A machine's run state as the table and the inspector show it.
struct VPhoneLaunchpadMachineStateLabel: View {
    let state: VPhoneLaunchpadMachineLibrary.RunState
    /// An export's progress, shown as a bar in place of the activity text.
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
    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var showsCommands = false
    @State private var patchCatalog: VPhoneLaunchpadPatchCatalog?
    @State private var patchCatalogError: String?
    /// The machine the catalogue above was read for, so another machine's
    /// patches never show while its own are read.
    @State private var patchCatalogMachine: VPhoneLaunchpadMachinePath?

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        Form {
            Section {
                if let creation = library.creations[machine.path] {
                    creationSummary(creation)
                }
                LabeledContent("State") {
                    VPhoneLaunchpadMachineStateLabel(
                        state: library.state(of: machine.path),
                        progress: library.exports[machine.path]?.fraction,
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
                    LabeledContent("iOS", value: "\(info.ios.version) (\(info.ios.build))")
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
            }

            Section("Identity") {
                if let udid = machine.udid {
                    value("UDID", udid)
                }
                value(
                    "Location",
                    VPhoneLaunchpadHostSetup.abbreviated(machine.path.url),
                )
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
                    .disabled(model.bundles.selectableVersions.isEmpty || library.creations[machine.path]?.isRunning == true)
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
    }

    private var patchReadKey: PatchReadKey {
        PatchReadKey(
            machine: machine.path,
            bundle: library.bundleVersion(for: machine.path),
            state: library.state(of: machine.path),
        )
    }

    /// The machine's patch choice, read only. The choice is changed with
    /// `vphone-cli fw set-patches`; this shows the preset, how many boxes
    /// differ from it, and, when the machine's bundle reports it, how many
    /// patches have not reached the guest yet. An older bundle does not
    /// report the last, and the row is left out.
    @ViewBuilder
    private var patchesSection: some View {
        if library.creations[machine.path]?.isRunning != true {
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
                            .help(pending == 0
                                ? String(localized: "The guest has every patch this machine is set to.")
                                : String(localized: "The patch choice changed after the guest was built. Run vphone-cli fw patches \(machine.name) to see each patch and the step that applies it."))
                        }
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
        guard library.creations[path]?.isRunning != true else { return }
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
