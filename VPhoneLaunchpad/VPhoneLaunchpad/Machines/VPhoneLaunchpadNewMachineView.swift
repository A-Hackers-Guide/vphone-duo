import AppKit
import SwiftUI

/// Name, location, Core Bundle, guest device and firmware pairing from
/// `fw catalog`, hardware, the template and its slimming, and options, on four
/// pages. Every page has defaults, so Create works from any of them.
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
    /// Clone the machine from a template, built first when there is none.
    @State private var usesTemplate = true
    @State private var slimming = VPhoneLaunchpadSlimming()
    @State private var page = Page.general

    enum Page: Hashable {
        case general, hardware, template, advanced
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

    /// Why the template switches stop Create, or nil.
    private var templateProblem: String? {
        guard usesTemplate else {
            return nil
        }
        if let problem = slimming.problem {
            return problem
        }
        // The template is built in a machine named like `template-1a2b3c4d`.
        if !VPhoneLaunchpadMachineLocations.socketPathFits(root: location, name: "template-00000000") {
            return String(localized: "The path is too long. Use a location with a shorter path.")
        }
        return nil
    }

    private var canCreate: Bool {
        nameProblem == nil && locationProblem == nil && templateProblem == nil && sources != nil && bundleVersion != nil
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("New Machine")) {
            VStack(spacing: 0) {
                VPhoneLaunchpadSheetPages(selection: $page) {
                    Text("General").tag(Page.general)
                    Text("Hardware").tag(Page.hardware)
                    Text("Template").tag(Page.template)
                    Text("Advanced").tag(Page.advanced)
                }
                Form {
                    switch page {
                    case .general:
                        Section {
                            TextField("Name", text: $name)
                            locationPicker
                        } footer: {
                            if let problem = nameProblem ?? locationProblem ?? templateProblem {
                                Text(problem).foregroundStyle(.red)
                            }
                        }

                        bundleSection

                        firmware

                        slimSection
                    case .hardware:
                        Section {
                            Stepper("CPU: \(cpu) cores", value: $cpu, in: 1 ... ProcessInfo.processInfo.activeProcessorCount)
                            Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2048 ... 65536, step: 1024)
                            Stepper("Disk: \(diskSizeGB) GB", value: $diskSizeGB, in: 32 ... 512, step: 16)
                        } footer: {
                            Text(spaceNote).foregroundStyle(.secondary)
                        }
                    case .template:
                        VPhoneLaunchpadSlimmingSections(usesTemplate: $usesTemplate, slimming: $slimming)
                    case .advanced:
                        VPhoneLaunchpadNewMachineAdvancedView(
                            usesTemplate: usesTemplate,
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
                    patches = VPhoneLaunchpadPreview.newMachinePatches
                }
            #endif
        }
    }

    // MARK: - Slimming

    /// The master switch. The parts are on the Template page.
    private var slimSection: some View {
        Section {
            Toggle("Slim System", isOn: $slimming.slim)
                .disabled(!usesTemplate)
        } footer: {
            Group {
                if !usesTemplate {
                    Text("Without a template the machine is not slimmed. Turn templates on in Template.")
                } else if slimming.slim {
                    Text("Trims system files, unneeded services and system apps once, in the template the machine is cloned from. Choose what goes in Template.")
                } else {
                    Text("The template keeps every file, service and app. Setup Assistant is still skipped.")
                }
            }
            .foregroundStyle(.secondary)
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
            guestPatches: patchCatalog?.guestOverrides(patches) ?? [],
            keepArtifacts: keepArtifacts,
            usesTemplate: usesTemplate,
            slimming: slimming,
        )
        let pipeline = model.machines.create(options)
        model.machines.selection = [pipeline.machine]
        onCreate(pipeline.machine)
    }
}

// MARK: - Pipeline

/// The pipeline, which keeps running when this sheet closes. A failure shows
/// on its step; the log, which records why, opens in its own sheet. A
/// template-backed creation shows the template's steps apart from the
/// machine's own.
struct VPhoneLaunchpadCreationView: View {
    typealias Step = VPhoneLaunchpadCreationStep

    let creation: VPhoneLaunchpadCreationPipeline
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsLog = false
    /// The IPSWs a template this creation built came from, once it is done.
    @State private var ipswFiles: [VPhoneLaunchpadIPSWFile] = []
    @State private var ipswDirectories: [URL] = []
    @State private var offersIPSWs = false

    private var templateSteps: [Step] {
        creation.steps.filter { $0 == .findTemplate || creation.plan.buildsTemplate($0) }
    }

    private var machineSteps: [Step] {
        creation.steps.filter { !templateSteps.contains($0) }
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Creating \(creation.options.name)")) {
            Form {
                if creation.plan.usesTemplate {
                    Section {
                        ForEach(templateSteps) { step in
                            stepRow(step)
                        }
                    } header: {
                        Text("Template")
                    } footer: {
                        Text(templateNote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(machineSteps) { step in
                        stepRow(step)
                    }
                } header: {
                    if creation.plan.usesTemplate {
                        Text("Machine")
                    }
                } footer: {
                    if creation.isRunning {
                        Text("Creation continues if you close this window.").foregroundStyle(.secondary)
                    } else if let failure = creation.failure, let detail = failure.detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }
                }
                if offersIPSWs {
                    VPhoneLaunchpadTemplateIPSWOffer(files: $ipswFiles, cacheDirectories: ipswDirectories)
                }
            }
            .formStyle(.grouped)
            .task(id: creation.isFinished && creation.builtTemplate) {
                guard creation.isFinished, creation.builtTemplate, !offersIPSWs else {
                    return
                }
                let found = await VPhoneLaunchpadTemplateIPSWOffer.scan(creation, library: model.machines)
                ipswFiles = found.files
                ipswDirectories = found.directories
                offersIPSWs = !found.files.isEmpty
            }
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
        // A template build lists fourteen steps: the form scrolls in a
        // sheet that fits a laptop screen instead of growing past it.
        .frame(height: creation.plan.usesTemplate ? 720 : nil)
        .fixedSize(horizontal: false, vertical: !creation.plan.usesTemplate)
        .sheet(isPresented: $showsLog) {
            VPhoneLaunchpadConsoleView(title: "\(creation.options.name) Creation Log", url: creation.logFile)
        }
    }

    private var templateNote: String {
        if let id = creation.templateID, creation.plan.foundTemplate == true {
            return String(localized: "Cloned from template \(id), which machines with these options share.")
        }
        if let id = creation.templateID, creation.builtTemplate {
            return String(localized: "Saved as template \(id). The next machine with these options is cloned from it in seconds.")
        }
        let build = creation.plan.buildName ?? ""
        return String(localized: "A missing template is built in \(build), set up once without a window, and saved under Templates.")
    }

    private func stepRow(_ step: Step) -> some View {
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
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(step.title)
                        if step.needsRoot {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Runs as root through the privileged helper")
                        }
                    }
                    if step == .setUpTemplate, let stage = creation.setupStage {
                        // The CLI's own words for the stage: `b. wait for first-boot work`.
                        Text(verbatim: stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

// MARK: - IPSWs a template came from

/// Offered once a creation has built a template: its clones need neither
/// IPSW, so the two downloads can go. Nothing is deleted without the
/// confirmation, and only files the IPSW cache holds.
struct VPhoneLaunchpadTemplateIPSWOffer: View {
    @Binding var files: [VPhoneLaunchpadIPSWFile]
    let cacheDirectories: [URL]
    @State private var confirming = false
    @State private var deleted = false
    @State private var error: VPhoneLaunchpadError?

    private var total: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        Section {
            if deleted {
                Label("The IPSWs were deleted.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    LabeledContent {
                        Text(verbatim: VPhoneLaunchpadIPSWCacheView.size(file.size)).monospacedDigit()
                    } label: {
                        Text(verbatim: file.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                HStack {
                    Spacer()
                    Button("Delete IPSWs…") { confirming = true }
                        .disabled(files.isEmpty)
                }
            }
        } header: {
            Text("Downloaded IPSWs")
        } footer: {
            if !deleted {
                Text("Machines from this template need neither IPSW. A machine with other options downloads them again.")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            String(localized: "Delete the IPSWs this template came from?"),
            isPresented: $confirming,
        ) {
            Button(String(localized: "Delete \(VPhoneLaunchpadIPSWCacheView.size(total))"), role: .destructive) {
                Task { await delete() }
            }
        } message: {
            Text("\(files.map(\.name).joined(separator: ", ")) are deleted from the IPSW cache.")
        }
        .errorAlert($error)
    }

    /// The cached IPSWs `creation` was given as sources and no unfinished
    /// creation still reads.
    static func scan(
        _ creation: VPhoneLaunchpadCreationPipeline,
        library: VPhoneLaunchpadMachineLibrary,
    ) async -> (files: [VPhoneLaunchpadIPSWFile], directories: [URL]) {
        let sources = [creation.options.iphoneSource, creation.options.cloudOSSource]
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                let scan = VPhoneLaunchpadPreview.ipswScan
                return (scan.ipsws.filter { file in sources.contains { VPhoneLaunchpadIPSWUse.source($0, is: file) } }, scan.cacheDirectories)
            }
        #endif
        guard let scan = try? await VPhoneLaunchpadIPSWCache.scan(libraryRoots: library.roots, machineFolders: []) else {
            return ([], [])
        }
        let busy = library.creations.values.filter { !$0.isFinished && $0 !== creation }
            .flatMap { [$0.options.iphoneSource, $0.options.cloudOSSource] }
        let files = scan.ipsws.filter { file in
            !file.isDownloading
                && sources.contains { VPhoneLaunchpadIPSWUse.source($0, is: file) }
                && !busy.contains { VPhoneLaunchpadIPSWUse.source($0, is: file) }
        }
        return (files, scan.cacheDirectories)
    }

    private func delete() async {
        var remaining = files
        for file in files {
            do {
                try await VPhoneLaunchpadIPSWCache.removeIPSW(file.url, cacheDirectories: cacheDirectories)
                remaining.removeAll { $0.id == file.id }
            } catch {
                self.error = VPhoneLaunchpadError(String(localized: "Unable to Delete \(file.name)"), detail: error.localizedDescription)
                files = remaining
                return
            }
        }
        files = []
        deleted = true
    }
}
