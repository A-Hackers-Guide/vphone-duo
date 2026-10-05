import AppKit
import SwiftUI

/// Name, location, Core Bundle, guest device and firmware pairing from
/// `fw catalog`, hardware and options, on three pages. Every page has
/// defaults, so Create works from any of them.
/// Create hands off to the pipeline sheet.
struct VPhoneLaunchpadNewMachineView: View {
    let onCreate: (VPhoneLaunchpadMachinePath) -> Void
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// The Core Bundle picked here; nil follows the default version.
    @State private var chosenVersion: String?
    /// The canonical library the machine is created in.
    @State private var location = VPhoneLaunchpadMachineLocations.defaultRoot
    /// A folder chosen with Other… that is not one of the library's locations.
    @State private var chosenLocation: String?
    @State private var catalog: VPhoneLaunchpadFirmwareCatalog?
    @State private var catalogError: String?
    /// The guest device's product type.
    @State private var guest: String?
    @State private var pairing: String?
    @State private var usesCustomSources = false
    @State private var iphoneSource = ""
    @State private var cloudOSSource = ""
    @State private var cpu = 8
    @State private var memoryMB = 8192
    @State private var diskSizeGB = 64
    @State private var network = "nat"
    @State private var patches = VPhoneLaunchpadPatchSelection()
    @State private var patchCatalog: VPhoneLaunchpadPatchCatalog?
    @State private var patchCatalogError: String?
    @State private var keepArtifacts = false
    @State private var page = Page.general

    enum Page: Hashable {
        case general, hardware, advanced
    }

    private var selectedGuest: VPhoneLaunchpadFirmwareCatalog.Device? {
        catalog?.guests.first { $0.id == guest }
    }

    /// The version every step of the creation runs with, and the one the
    /// firmware and patch catalogs are read from.
    private var bundleVersion: String? {
        let selectable = model.bundles.selectableVersions
        if let chosenVersion, selectable.contains(chosenVersion) {
            return chosenVersion
        }
        return model.bundles.defaultVersion ?? selectable.first
    }

    private var selectedPairing: VPhoneLaunchpadFirmwareCatalog.Pairing? {
        selectedGuest?.pairings.first { $0.id == pairing }
    }

    private var sources: (String, String)? {
        if usesCustomSources {
            let iphone = iphoneSource.trimmingCharacters(in: .whitespaces)
            let cloudOS = cloudOSSource.trimmingCharacters(in: .whitespaces)
            return iphone.isEmpty || cloudOS.isEmpty ? nil : (iphone, cloudOS)
        }
        return selectedPairing.map { ($0.ios.url, $0.recommendedCloudOS.url) }
    }

    private var effectiveName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var machine: VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: location, name: effectiveName)
    }

    private func isTaken(_ machine: VPhoneLaunchpadMachinePath) -> Bool {
        model.machines.machines.contains(where: { $0.path == machine })
            || model.machines.creations[machine] != nil
            || FileManager.default.fileExists(atPath: machine.url.path)
    }

    /// The first `pcc-research-NN` free in `root`, filled into the field when
    /// the sheet opens.
    private func suggestedName(in root: String) -> String {
        let names = (1 ... 99).lazy.map { String(format: "pcc-research-%02d", $0) }
        return names.first { !isTaken(VPhoneLaunchpadMachinePath(libraryRoot: root, name: $0)) } ?? "pcc-research"
    }

    private var nameProblem: String? {
        if !VPhoneLaunchpadNames.isValidMachineName(effectiveName) {
            return String(localized: "Use letters, numbers, periods, hyphens, and underscores.")
        }
        if model.machines.machines.contains(where: { $0.path == machine }) || model.machines.creations[machine]?.isRunning == true {
            return String(localized: "A machine with this name already exists.")
        }
        if FileManager.default.fileExists(atPath: machine.url.path) {
            return String(localized: "A folder with this name already exists in this location.")
        }
        if !VPhoneLaunchpadMachineLocations.socketPathFits(root: location, name: effectiveName) {
            return String(localized: "The path is too long. Use a shorter name, or a location with a shorter path.")
        }
        return nil
    }

    private var locationProblem: String? {
        VPhoneLaunchpadMachineLocations.problem(with: location)
    }

    private var canCreate: Bool {
        nameProblem == nil && locationProblem == nil && sources != nil && bundleVersion != nil
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("New Machine")) {
            VStack(spacing: 0) {
                VPhoneLaunchpadSheetPages(selection: $page) {
                    Text("General").tag(Page.general)
                    Text("Hardware").tag(Page.hardware)
                    Text("Advanced").tag(Page.advanced)
                }
                Form {
                    switch page {
                    case .general:
                        Section {
                            TextField("Name", text: $name)
                            locationPicker
                        } footer: {
                            if let problem = nameProblem ?? locationProblem {
                                Text(problem).foregroundStyle(.red)
                            }
                        }

                        bundleSection

                        firmware
                    case .hardware:
                        Section {
                            Stepper("CPU: \(cpu) cores", value: $cpu, in: 1 ... ProcessInfo.processInfo.activeProcessorCount)
                            Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2048 ... 65536, step: 1024)
                            Stepper("Disk: \(diskSizeGB) GB", value: $diskSizeGB, in: 32 ... 512, step: 16)
                        } footer: {
                            Text(spaceNote).foregroundStyle(.secondary)
                        }
                    case .advanced:
                        VPhoneLaunchpadNewMachineAdvancedView(
                            network: $network,
                            patches: $patches,
                            keepArtifacts: $keepArtifacts,
                            patchCatalog: patchCatalog,
                            patchCatalogError: patchCatalogError,
                            reloadPatches: { Task { await loadPatchCatalog() } },
                            bundleVersion: bundleVersion,
                        )
                    }
                }
                .formStyle(.grouped)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        // Each bundle version has its own firmware pairings and patch sets.
        .task(id: bundleVersion) { await loadCatalog() }
        .task(id: bundleVersion) { await loadPatchCatalog() }
        .onAppear {
            let root = model.machines.preferredRoot
            location = root
            name = suggestedName(in: root)
            #if DEBUG
                if VPhoneLaunchpadPreview.isActive {
                    page = VPhoneLaunchpadPreview.newMachinePage
                }
            #endif
        }
    }

    // MARK: - Core Bundle

    private var bundleSection: some View {
        Section {
            if model.bundles.selectableVersions.isEmpty {
                Label("No Core Bundle is installed. Install one in Core Bundle.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Core Bundle", selection: versionBinding) {
                    ForEach(model.bundles.selectableVersions, id: \.self) { version in
                        // Store names keep their `-local.` and `-ci.` suffixes,
                        // so a build that is not a release reads as one.
                        if version == model.bundles.defaultVersion {
                            Text("\(version) (Default)").tag(Optional(version))
                        } else {
                            Text(verbatim: version).tag(Optional(version))
                        }
                    }
                }
            }
        } footer: {
            Text("The boot chain is built when the machine is created. Host programs, the guest environment and guest patches can be changed later.")
                .foregroundStyle(.secondary)
        }
    }

    /// A new version clears what was read from the old one, so Create cannot
    /// use a pairing or a preset that version never offered.
    private var versionBinding: Binding<String?> {
        Binding(
            get: { bundleVersion },
            set: { version in
                guard version != bundleVersion else {
                    return
                }
                chosenVersion = version
                catalog = nil
                catalogError = nil
                patchCatalog = nil
                patchCatalogError = nil
            },
        )
    }

    // MARK: - Location

    /// The library's locations that are mounted, the default one first, and
    /// a folder chosen with Other….
    private var locations: [String] {
        var roots = model.machines.roots.filter { $0 == model.machines.libraryRoot || VPhoneLaunchpadMachineLocations.isAvailable($0) }
        for root in [chosenLocation, location].compactMap(\.self) where !roots.contains(root) {
            roots.append(root)
        }
        return roots
    }

    private var locationPicker: some View {
        Picker("Location", selection: Binding(
            get: { location },
            set: { root in
                if root.isEmpty {
                    // Let the menu close before the open panel runs.
                    Task { @MainActor in chooseLocation() }
                } else {
                    location = root
                }
            },
        )) {
            ForEach(locations, id: \.self) { root in
                Text(verbatim: VPhoneLaunchpadHostSetup.abbreviated(URL(fileURLWithPath: root, isDirectory: true)))
                    .tag(root)
            }
            Divider()
            // Library roots are absolute, so an empty tag cannot be one.
            Text("Other…").tag("")
        }
        .help(location)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Location")
        panel.message = String(localized: "The machine is created in a folder with its name inside the folder you choose.")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: location, isDirectory: true)
        panel.present { url in
            useLocation(url)
        }
    }

    private func useLocation(_ url: URL) {
        let root = VPhoneLaunchpadMachineLocations.canonical(url)
        if !model.machines.roots.contains(root) {
            chosenLocation = root
        }
        location = root
        // Machines already in the folder join the list; a folder that cannot
        // hold machines is only shown here, with the reason.
        if VPhoneLaunchpadMachineLocations.problem(with: root) == nil {
            model.machines.addLocation(root)
        }
    }

    // MARK: - Firmware

    private var firmware: some View {
        Section {
            Picker("Source", selection: $usesCustomSources) {
                Text("Catalog").tag(false)
                Text("Custom IPSWs").tag(true)
            }
            .pickerStyle(.segmented)

            if usesCustomSources {
                sourceField("iPhone IPSW", $iphoneSource)
                sourceField("cloudOS IPSW", $cloudOSSource)
            } else if let catalog {
                if catalog.guests.count > 1 {
                    Picker("Device", selection: Binding(
                        get: { guest },
                        set: { choose($0) },
                    )) {
                        ForEach(catalog.guests) { guest in
                            Text(verbatim: guest.name).tag(Optional(guest.id))
                        }
                    }
                }
                Picker(selectedGuest?.isPad == true ? "iPadOS" : "iOS", selection: $pairing) {
                    ForEach((selectedGuest?.pairings ?? []).reversed()) { pairing in
                        Text(verbatim: "\(pairing.ios.name) (\(pairing.build))").tag(Optional(pairing.id))
                    }
                }
                LabeledContent("cloudOS", value: selectedPairing?.recommendedCloudOS.name ?? "—")
            } else if let catalogError {
                Label(catalogError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading firmware catalog…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Firmware")
        } footer: {
            if !usesCustomSources, let selectedGuest {
                Text("Recommended firmware pairings for \(selectedGuest.detailedName).")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func isIPSWFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && path.lowercased().hasSuffix(".ipsw")
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func sourceField(_ title: LocalizedStringKey, _ text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                // A chosen file shows only its name; a URL or a path still
                // being typed stays editable.
                if Self.isIPSWFile(text.wrappedValue) {
                    Text(verbatim: URL(fileURLWithPath: text.wrappedValue).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(text.wrappedValue)
                    Button {
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear")
                } else {
                    TextField(title, text: text, prompt: Text("URL or path"))
                        .labelsHidden()
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.present { url in
                        text.wrappedValue = url.path
                    }
                }
            }
        }
    }

    /// Disk plus roughly 20 GB of IPSWs and the prepared restore tree.
    private var spaceNote: String {
        let root = VPhoneLaunchpadHostSetup.existingAncestor(of: URL(fileURLWithPath: location, isDirectory: true))
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return String(localized: "Needs about \(diskSizeGB + 20) GB; \(free / 1_000_000_000) GB free.")
    }

    // MARK: - Actions

    private func loadCatalog() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                catalog = VPhoneLaunchpadPreview.catalog
                choose(catalog?.guests.first?.id)
                return
            }
        #endif
        let version = bundleVersion
        guard let commandLine = version.flatMap(model.bundles.commandLine(version:)) else {
            return
        }
        do {
            let result = try await commandLine.run(["fw", "catalog", "--json"], recordInHistory: false)
            // Another version may have been chosen meanwhile.
            guard version == bundleVersion else {
                return
            }
            guard result.succeeded, let data = result.jsonData else {
                catalogError = result.tail
                return
            }
            let catalog = try JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: data)
            self.catalog = catalog
            // The guest and pairing chosen under the previous version stay
            // when this one offers them too.
            if !catalog.guests.contains(where: { $0.id == guest }) {
                choose(catalog.guests.first?.id)
            } else if selectedGuest?.pairings.contains(where: { $0.id == pairing }) != true {
                pairing = selectedGuest?.defaultPairing?.id
            }
        } catch {
            guard version == bundleVersion else {
                return
            }
            catalogError = error.localizedDescription
        }
    }

    /// Select a guest device and its newest release.
    private func choose(_ productType: String?) {
        guest = productType
        pairing = selectedGuest?.defaultPairing?.id
    }

    /// Read again whenever the preset or the version changes: `inPreset`, which
    /// the note and the editor read the checkmarks against, is reported per
    /// preset, and each version declares its own patches.
    private func loadPatchCatalog() async {
        let version = bundleVersion
        let requested = patches.preset
        do {
            let catalog = try await VPhoneLaunchpadPatchCatalog.read(
                using: version.flatMap(model.bundles.commandLine(version:)),
                machine: nil,
                preset: requested,
            )
            // A second switch may have overtaken this read.
            guard requested == patches.preset, version == bundleVersion else {
                return
            }
            // Overrides naming a patch this version does not declare are dropped.
            patches.normalize(against: catalog)
            patchCatalog = catalog
            patchCatalogError = nil
        } catch {
            guard requested == patches.preset, version == bundleVersion else {
                return
            }
            // The first read after a version change: that version may not
            // have the chosen preset, so fall back to the default one.
            if patchCatalog == nil, requested != VPhoneLaunchpadPatchSelection.defaultPreset {
                patches = VPhoneLaunchpadPatchSelection()
                await loadPatchCatalog()
                return
            }
            patchCatalogError = VPhoneLaunchpadError.message(for: error)
        }
    }

    private func create() {
        guard let (iphone, cloudOS) = sources, let bundleVersion else {
            return
        }
        let options = VPhoneLaunchpadCreationPipeline.Options(
            name: effectiveName,
            libraryRoot: location,
            bundleVersion: bundleVersion,
            iphoneSource: iphone,
            cloudOSSource: cloudOS,
            // An iPad IPSW often covers two sizes; name the one chosen.
            device: usesCustomSources ? nil : selectedGuest.flatMap { $0.isPad ? $0.productType : nil },
            cpuCount: cpu,
            memoryMB: memoryMB,
            diskSizeGB: diskSizeGB,
            network: network,
            patches: patches,
            keepArtifacts: keepArtifacts,
        )
        let pipeline = model.machines.create(options)
        model.machines.selection = [pipeline.machine]
        onCreate(pipeline.machine)
    }
}

// MARK: - Pipeline

/// The pipeline, which keeps running when this sheet closes. A failure shows
/// on its step; the log, which records why, opens in its own sheet.
struct VPhoneLaunchpadCreationView: View {
    let creation: VPhoneLaunchpadCreationPipeline
    @Environment(\.dismiss) private var dismiss
    @State private var showsLog = false

    var body: some View {
        VPhoneLaunchpadSheet(Text("Creating \(creation.options.name)")) {
            Form {
                Section {
                    ForEach(VPhoneLaunchpadCreationPipeline.Step.allCases) { step in
                        stepRow(step)
                    }
                } footer: {
                    if creation.isRunning {
                        Text("Creation continues if you close this window.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } accessory: {
            Button("Open Log") { showsLog = true }
        } actions: {
            if creation.isRunning {
                Button("Stop Creating", role: .destructive) { creation.cancel() }
            }
            if !creation.isRunning, let step = creation.failedStep {
                Button("Retry from \(step.title)") { creation.start(from: step) }
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showsLog) {
            VPhoneLaunchpadConsoleView(title: "\(creation.options.name) Creation Log", url: creation.logFile)
        }
    }

    private func stepRow(_ step: VPhoneLaunchpadCreationPipeline.Step) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if step == .prepare, let fraction = creation.downloadFraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 120)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let duration = creation.durations[step] {
                    Text(Self.duration(duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                VPhoneLaunchpadCommandInfoButton(command: "vphone-cli \(creation.command(for: step))")
            }
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text(step.title)
                    if step.needsRoot {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Runs as root through the privileged helper")
                    }
                }
            } icon: {
                VPhoneLaunchpadStatusIcon(status: creation.status(step))
            }
        }
    }

    static func duration(_ interval: TimeInterval) -> String {
        Duration.seconds(interval).formatted(.time(pattern: interval >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
