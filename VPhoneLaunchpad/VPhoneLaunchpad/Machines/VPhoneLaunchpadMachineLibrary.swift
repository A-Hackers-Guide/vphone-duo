import Foundation
import Observation

/// The third stage: the VM library, driven entirely through `vphone-cli vm`.
///
/// Machines can live in several libraries: the default one, and folders
/// chosen in New Machine. Each library is listed with its own
/// `--library-root`, and every action on a machine passes the root it was
/// listed from.
@MainActor
@Observable
final class VPhoneLaunchpadMachineLibrary {
    enum RunState: Equatable {
        case stopped
        case running
        case busy(String)
    }

    typealias Path = VPhoneLaunchpadMachinePath

    private(set) var machines: [VPhoneLaunchpadMachine] = []
    private(set) var listError: String?
    /// False until the first `vm list` answers, so the window does not show
    /// "No Machines" before it knows.
    private(set) var hasListed = false
    private(set) var startedAt: [Path: Date] = [:]
    /// Machines whose console printed a panic since Launchpad last started
    /// them. The console text itself stays in the log file.
    private(set) var panicked: Set<Path> = []
    private(set) var creations: [Path: VPhoneLaunchpadCreationPipeline] = [:]
    /// Each listed machine's Core Bundle, read from its `launchpad.json`.
    private(set) var bindings: [Path: VPhoneLaunchpadMachineBinding] = [:]
    private(set) var globalActivity: String?
    /// Folders chosen in New Machine, in the order they were added. The
    /// default library is not among them.
    private(set) var addedRoots: [String]
    var selection: Set<Path> = []
    var actionError: VPhoneLaunchpadError?

    /// The default library, canonical. Import writes here.
    let libraryRoot: String
    private let bundles: VPhoneLaunchpadCoreBundle
    private let helper: VPhoneLaunchpadHelperClient
    private var launched: [Path: VPhoneLaunchpadChildProcess] = [:]
    private var externallyRunning: Set<Path> = []
    private var activities: [Path: String] = [:]
    private var isRefreshing = false
    private var timer: Timer?

    private static let addedRootsKey = "VPhoneLaunchpadLibraryRoots"
    private static let lastRootKey = "VPhoneLaunchpadLastLibraryRoot"

    init(bundles: VPhoneLaunchpadCoreBundle, helper: VPhoneLaunchpadHelperClient) {
        libraryRoot = VPhoneLaunchpadMachineLocations.defaultRoot
        self.bundles = bundles
        self.helper = helper
        var roots: [String] = []
        for root in UserDefaults.standard.stringArray(forKey: Self.addedRootsKey) ?? []
            where root.hasPrefix("/") && root != libraryRoot && !roots.contains(root)
        {
            roots.append(root)
        }
        addedRoots = roots
    }

    /// Every library, the default one first.
    var roots: [String] {
        [libraryRoot] + addedRoots
    }

    /// The selected machines, in list order.
    var selectedMachines: [VPhoneLaunchpadMachine] {
        machines.filter { selection.contains($0.id) }
    }

    /// The selected machine when exactly one is selected.
    var selected: VPhoneLaunchpadMachine? {
        let selected = selectedMachines
        return selected.count == 1 ? selected[0] : nil
    }

    var runningCount: Int {
        machines.count(where: { state(of: $0.path) == .running })
    }

    var hasActiveCreation: Bool {
        creations.values.contains(where: \.isRunning)
    }

    /// True while machines from more than one library are listed.
    var spansLibraries: Bool {
        Set(machines.map(\.libraryRoot)).count > 1
    }

    /// The bar the state label shows in place of its text: an export's
    /// progress, or the IPSW download of a creation.
    func progress(of machine: Path) -> Double? {
        exports[machine]?.fraction ?? creations[machine]?.downloadFraction
    }

    func state(of machine: Path) -> RunState {
        if let creation = creations[machine], creation.isRunning, let step = creation.current {
            return .busy(String(localized: "Creating: \(step.title)"))
        }
        if let activity = activities[machine] {
            return .busy(activity)
        }
        if exports[machine]?.isWaiting == true {
            return .busy(String(localized: "Waiting to export…"))
        }
        if launched[machine]?.isRunning == true || externallyRunning.contains(machine) {
            return .running
        }
        return .stopped
    }

    func launchedProcess(_ machine: Path) -> VPhoneLaunchpadChildProcess? {
        launched[machine]
    }

    // MARK: - Locations

    /// The library New Machine offers first: the one last created in, while
    /// it is mounted and usable (even once it holds no machine), else the
    /// default library.
    var preferredRoot: String {
        if let last = UserDefaults.standard.string(forKey: Self.lastRootKey), last.hasPrefix("/"),
           VPhoneLaunchpadMachineLocations.isAvailable(last),
           VPhoneLaunchpadMachineLocations.problem(with: last) == nil
        {
            return last
        }
        return libraryRoot
    }

    /// Remembers a folder so its machines are listed with the others.
    func addLocation(_ root: String) {
        guard root != libraryRoot, !addedRoots.contains(root) else {
            return
        }
        addedRoots.append(root)
        UserDefaults.standard.set(addedRoots, forKey: Self.addedRootsKey)
        Task { await refresh() }
    }

    /// Forgets added folders that were listed and hold no machine. A folder
    /// that is missing, or could not be listed, is kept: its volume may just
    /// not be mounted.
    private func forgetEmptyLocations(listed: Set<String>) {
        let kept = addedRoots.filter { root in
            !listed.contains(root)
                || machines.contains { $0.libraryRoot == root }
                || creations.keys.contains { $0.libraryRoot == root }
        }
        if kept != addedRoots {
            addedRoots = kept
            UserDefaults.standard.set(kept, forKey: Self.addedRootsKey)
        }
    }

    // MARK: - Refresh

    func startMonitoring() {
        guard timer == nil else {
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard let commandLine = bundles.commandLine(), !isRefreshing else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var found: [VPhoneLaunchpadMachine] = []
        var listed: Set<String> = []
        var errors: [String] = []
        for root in roots {
            // vm list reports an empty library for a missing default root;
            // a missing added folder is skipped, and its machines go with it.
            guard root == libraryRoot || VPhoneLaunchpadMachineLocations.isAvailable(root) else {
                continue
            }
            do {
                let result = try await commandLine.run(["vm", "list", "--json", "--library-root", root], recordInHistory: false)
                if result.succeeded, let data = result.jsonData {
                    var machines = try JSONDecoder().decode([VPhoneLaunchpadMachine].self, from: data)
                    for index in machines.indices {
                        machines[index].libraryRoot = root
                    }
                    found += machines
                    listed.insert(root)
                    continue
                }
                errors.append(result.tail)
            } catch {
                errors.append(error.localizedDescription)
            }
            // Keep what this library listed last time, as before.
            found += machines.filter { $0.libraryRoot == root }
        }
        machines = found
        listError = errors.first
        hasListed = true
        forgetEmptyLocations(listed: listed)
        selection.formIntersection(machines.map(\.id))
        if selection.isEmpty, let first = machines.first {
            selection = [first.id]
        }
        let paths = machines.map(\.path)
        externallyRunning = await Task.detached { Self.machinesHoldingDisks(paths) }.value
        await loadBindings(paths)
    }

    /// The same test `vm stop` uses: a machine runs while some process holds
    /// its disk image open. This also finds guests started outside Launchpad.
    private nonisolated static func machinesHoldingDisks(_ machines: [Path]) -> Set<Path> {
        var diskOwners: [String: Path] = [:]
        for machine in machines {
            let bundle = machine.url
            let manifest = NSDictionary(contentsOf: bundle.appendingPathComponent("config.plist"))
            // Only a plain file name inside the bundle: a crafted manifest must
            // not point lsof, and then `vm stop`, at another path.
            let disk = (manifest?["diskImage"] as? String).flatMap(Self.plainFileName) ?? "Disk.img"
            diskOwners[bundle.appendingPathComponent(disk).path] = machine
        }
        guard !diskOwners.isEmpty else {
            return []
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-F", "n", "--"] + diskOwners.keys.sorted()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return []
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var running: Set<Path> = []
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            if let machine = diskOwners[String(line.dropFirst())] {
                running.insert(machine)
            }
        }
        return running
    }

    /// `name` when it is one path component, otherwise nil.
    private nonisolated static func plainFileName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        return name
    }

    // MARK: - Core Bundle

    /// Reads every machine's binding. A machine without one, created before
    /// bindings existed or outside Launchpad, is bound to the default
    /// version, so a bundle installed later does not change what it runs. A
    /// machine still being created is skipped: its pipeline binds it.
    private func loadBindings(_ paths: [Path]) async {
        let pending = Set(creations.keys)
        let fallback = bundles.defaultVersion
        let before = bindings
        var loaded = await Task.detached {
            var bindings: [Path: VPhoneLaunchpadMachineBinding] = [:]
            for path in paths {
                if let binding = VPhoneLaunchpadMachineBinding.load(path) {
                    bindings[path] = binding
                } else if !pending.contains(path), let fallback {
                    let binding = VPhoneLaunchpadMachineBinding(bundle: fallback)
                    // An unwritable folder still runs with the default.
                    if (try? binding.save(to: path)) != nil {
                        bindings[path] = binding
                    }
                }
            }
            return bindings
        }.value
        // A binding written while the files were read is newer than its file
        // was then.
        for (path, binding) in bindings where before[path] != binding {
            loaded[path] = binding
        }
        bindings = loaded
    }

    /// The version a machine runs with: its binding, else the default.
    func bundleVersion(for machine: Path) -> String? {
        bindings[machine]?.bundle ?? bundles.defaultVersion
    }

    /// `vphone-cli` of the machine's own bundle. Nil when that version is
    /// not installed, for example on a machine imported from another Mac.
    func commandLine(for machine: Path) -> VPhoneLaunchpadCommandLine? {
        bundleVersion(for: machine).flatMap(bundles.commandLine(version:))
    }

    /// Names of the listed machines bound to `version`.
    func machineNames(boundTo version: String) -> [String] {
        machines.filter { bundleVersion(for: $0.path) == version }.map(\.name)
    }

    /// The binding on disk, or the listed copy when the file cannot be read.
    private func currentBinding(of machine: Path) -> VPhoneLaunchpadMachineBinding? {
        VPhoneLaunchpadMachineBinding.load(machine) ?? bindings[machine]
    }

    /// Writes a machine's binding and keeps the listed copy in step.
    func bind(_ machine: Path, _ binding: VPhoneLaunchpadMachineBinding) throws {
        try binding.save(to: machine)
        bindings[machine] = binding
    }

    /// Binds machines to another installed version. The host programs change
    /// on the next start. With `updateEnvironment`, each stopped machine also
    /// gets that version's guest environment; a running one keeps its own
    /// until it is updated later. Boot chain and patches stay as created.
    func setBundle(_ version: String, for machines: [Path], updateEnvironment: Bool) async {
        guard bundles.commandLine(version: version) != nil else {
            actionError = VPhoneLaunchpadError(String(localized: "VPhone.bundle \(version) is not installed."))
            return
        }
        for machine in machines {
            var binding = currentBinding(of: machine)
                ?? VPhoneLaunchpadMachineBinding(bundle: version)
            binding.bundle = version
            do {
                try bind(machine, binding)
            } catch {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to Change the Core Bundle of \(machine.name)"),
                    detail: error.localizedDescription,
                )
                continue
            }
            // A machine not restored yet, or whose custom firmware install
            // did not finish, has no guest environment to update.
            let listed = self.machines.first { $0.path == machine }
            if updateEnvironment, state(of: machine) == .stopped,
               listed?.restoreInfo != nil, listed?.customFirmwareInstalled != false
            {
                await updateGuestEnvironment(machine)
            }
        }
    }

    /// Records the bundle whose guest environment a machine now has.
    func recordGuestEnvironment(_ machine: Path, _ version: String) {
        var binding = VPhoneLaunchpadMachineBinding.load(machine) ?? VPhoneLaunchpadMachineBinding(bundle: version)
        binding.guestEnvironment = version
        try? bind(machine, binding)
    }

    // MARK: - Console

    /// Machines in the default library keep their log names. Elsewhere the
    /// name gains a digest of the library, since two libraries may each hold
    /// a machine with the same name.
    static func consoleLog(_ machine: Path, suffix: String = "") -> URL {
        let stem = machine.libraryRoot == VPhoneLaunchpadMachineLocations.defaultRoot
            ? machine.name
            : "\(machine.name)-\(VPhoneLaunchpadMachineLocations.digest(machine.libraryRoot))"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/vphone-launchpad", isDirectory: true)
            .appendingPathComponent("\(stem)\(suffix).log")
    }

    /// Adds a line of Launchpad's own to the console log, after the process
    /// that wrote it has exited.
    private func appendConsoleLog(_ machine: Path, _ line: String) {
        guard let handle = try? FileHandle(forWritingTo: Self.consoleLog(machine)) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\n\(line)\n".utf8))
    }

    /// One line of helper output, from the XPC queue. Creates the log if the
    /// machine has never been started from Launchpad.
    private nonisolated static func append(_ line: String, to log: URL) {
        if !FileManager.default.fileExists(atPath: log.path) {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: log) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(line)\n".utf8))
    }

    // MARK: - Start and stop

    /// Starts a machine with its own bundle, after checking that bundle in
    /// this session (policy exception, host preflight and AMFI admission).
    func start(_ machine: Path, headless: Bool = false) async {
        guard let version = bundleVersion(for: machine) else {
            actionError = VPhoneLaunchpadError(String(localized: "No Core Bundle version is installed. Install one in Core Bundle."))
            return
        }
        let isChecking = !bundles.isChecked(version)
        if isChecking {
            activities[machine] = String(localized: "Checking Core Bundle…")
        }
        do {
            try await bundles.prepare(version)
            if isChecking {
                activities[machine] = nil
            }
        } catch {
            if isChecking {
                activities[machine] = nil
            }
            actionError = VPhoneLaunchpadError(
                String(localized: "Unable to Start \(machine.name)"),
                detail: VPhoneLaunchpadError.message(for: error),
            )
            return
        }
        guard let commandLine = bundles.commandLine(version: version) else {
            return
        }
        // `vm launch` refuses these too, but only into the console log.
        guard !VPhoneLaunchpadMachine.customFirmwareIncomplete(at: machine) else {
            actionError = VPhoneLaunchpadError(
                String(localized: "Unable to Start \(machine.name)"),
                detail: String(localized: "Custom firmware installation on this machine did not complete, so it cannot boot. Choose Install Custom Firmware from the machine's menu, then start it again."),
            )
            return
        }
        var arguments = ["vm", "launch", machine.name] + machine.libraryArguments
        if headless {
            arguments.append("--headless")
        }
        panicked.remove(machine)
        do {
            let child = try commandLine.start(arguments, logFile: Self.consoleLog(machine)) { [weak self] line in
                if VPhoneLaunchpadCreationPipeline.isPanic(line) {
                    Task { @MainActor in self?.panicked.insert(machine) }
                }
            }
            launched[machine] = child
            startedAt[machine] = Date()
            Task {
                let status = await child.wait()
                if launched[machine] === child {
                    launched[machine] = nil
                    startedAt[machine] = nil
                    appendConsoleLog(machine, "vm launch exited with status \(status)")
                }
                await refresh()
            }
        } catch {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Start \(machine.name)"), detail: error.localizedDescription)
        }
    }

    /// Runs `cfw install` again through the helper, for a machine whose last
    /// install did not finish. Output goes to the machine's console log.
    func installCustomFirmware(_ machine: Path) async {
        guard let version = bundleVersion(for: machine) else {
            actionError = VPhoneLaunchpadError(String(localized: "No Core Bundle version is installed. Install one in Core Bundle."))
            return
        }
        activities[machine] = String(localized: "Installing custom firmware…")
        defer { activities[machine] = nil }
        appendConsoleLog(machine, "$ vphone-cli cfw install \(machine.name)")
        let log = Self.consoleLog(machine)
        do {
            let status = try await helper.installCustomFirmware(
                bundleVersion: version,
                machineName: machine.name,
                libraryRoot: machine.libraryRoot,
                keepArtifacts: true,
                onLine: { line in Self.append(line, to: log) },
            )
            if status != 0 {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to install custom firmware. Check the log for details."),
                    detail: String(localized: "Choose Show Console Log for the full output."),
                )
            } else {
                recordGuestEnvironment(machine, version)
            }
        } catch {
            if !(error is CancellationError) {
                actionError = error as? VPhoneLaunchpadError
                    ?? VPhoneLaunchpadError(String(localized: "Unable to install custom firmware. Check the log for details."), detail: error.localizedDescription)
            }
        }
        await refresh()
    }

    /// Redeploys the guest resources (vphoned and the hook dylibs) of the
    /// machine's own bundle into it while it is stopped, through the helper,
    /// and nothing else. This is how a machine created by an older bundle
    /// gets newer hooks, since its restore tree is gone after the first boot.
    func updateGuestEnvironment(_ machine: Path) async {
        guard let version = bundleVersion(for: machine) else {
            actionError = VPhoneLaunchpadError(String(localized: "No Core Bundle version is installed. Install one in Core Bundle."))
            return
        }
        activities[machine] = String(localized: "Updating guest environment…")
        defer { activities[machine] = nil }
        appendConsoleLog(machine, "$ vphone-cli cfw update-environment \(machine.name)")
        let log = Self.consoleLog(machine)
        do {
            let status = try await helper.updateGuestEnvironment(
                bundleVersion: version,
                machineName: machine.name,
                libraryRoot: machine.libraryRoot,
                onLine: { line in Self.append(line, to: log) },
            )
            if status != 0 {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to update the guest environment."),
                    detail: String(localized: "Choose Show Console Log for the full output."),
                )
            } else {
                recordGuestEnvironment(machine, version)
            }
        } catch {
            if !(error is CancellationError) {
                actionError = error as? VPhoneLaunchpadError
                    ?? VPhoneLaunchpadError(String(localized: "Unable to update the guest environment."), detail: error.localizedDescription)
            }
        }
        await refresh()
    }

    /// Replaces the machine's Preboot kernelcache with the one its current
    /// patch selection resolves to, keeping the guest's data (no restore). The
    /// data-preserving way to apply a kernel patch change to an installed VM.
    func updateKernel(_ machine: Path) async {
        guard let version = bundleVersion(for: machine) else {
            actionError = VPhoneLaunchpadError(String(localized: "No Core Bundle version is installed. Install one in Core Bundle."))
            return
        }
        activities[machine] = String(localized: "Updating kernel…")
        defer { activities[machine] = nil }
        appendConsoleLog(machine, "$ vphone-cli cfw update-kernel \(machine.name)")
        let log = Self.consoleLog(machine)
        do {
            let status = try await helper.updateKernel(
                bundleVersion: version,
                machineName: machine.name,
                libraryRoot: machine.libraryRoot,
                onLine: { line in Self.append(line, to: log) },
            )
            if status != 0 {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to update the kernel."),
                    detail: String(localized: "Choose Show Console Log for the full output."),
                )
            }
        } catch {
            if !(error is CancellationError) {
                actionError = error as? VPhoneLaunchpadError
                    ?? VPhoneLaunchpadError(String(localized: "Unable to update the kernel."), detail: error.localizedDescription)
            }
        }
        await refresh()
    }

    /// Stops a machine. The guest is asked to shut down first, so it quits its
    /// apps and unmounts its volumes. `vm stop`, which ends the virtual
    /// machine the way cutting the power would, follows only when the guest
    /// cannot be asked or has not stopped in time.
    func stop(_ machine: Path) async {
        if await shutDownGuest(machine) {
            await refresh()
            return
        }
        await perform(String(localized: "Stopping…"), on: machine, ["vm", "stop", machine.name] + machine.libraryArguments)
        launched[machine]?.interrupt()
    }

    /// How long a guest gets to shut down before `vm stop` takes over.
    private static let guestShutdownTimeout: TimeInterval = 30

    /// Sends vphoned's `system.shutdown` over the machine's vphone.sock and
    /// waits for the virtual machine to stop. False when the guest could not
    /// be asked (not started up yet, in DFU, or a vphoned older than the
    /// method) or is still running when the time is up.
    private func shutDownGuest(_ machine: Path) async -> Bool {
        // A panicked guest has no vphoned left to ask.
        guard !panicked.contains(machine) else {
            return false
        }
        activities[machine] = String(localized: "Shutting down…")
        defer { activities[machine] = nil }
        let request: [String: Any] = ["t": "rpc", "method": "system.shutdown", "params": ["force": true]]
        let socket = machine.url.appendingPathComponent("vphone.sock").path
        do {
            _ = try await VPhoneLaunchpadGuestSocket.send(request, socketPath: socket, timeout: 10)
        } catch {
            return await !isRunning(machine)
        }
        let deadline = Date().addingTimeInterval(Self.guestShutdownTimeout)
        while Date() < deadline {
            if await !isRunning(machine) {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Whether the machine's virtual machine is still up: the process
    /// Launchpad started, or for one started elsewhere, whoever holds its disk.
    private func isRunning(_ machine: Path) async -> Bool {
        if let child = launched[machine] {
            return child.isRunning
        }
        return await Task.detached { !Self.machinesHoldingDisks([machine]).isEmpty }.value
    }

    // MARK: - Edits

    /// `networkArguments` are further `vm config` options (address, MAC, forwards),
    /// passed as the Settings sheet built them.
    func configure(
        _ machine: Path,
        cpu: Int?,
        memoryMB: Int?,
        network: String?,
        bridgeInterface: String?,
        networkArguments: [String] = [],
        unlocksAtStartup: Bool? = nil,
        syncsHostLocation: Bool? = nil,
    ) async {
        var arguments = ["vm", "config", machine.name] + machine.libraryArguments
        if let cpu {
            arguments += ["--cpu", String(cpu)]
        }
        if let memoryMB {
            arguments += ["--memory", String(memoryMB)]
        }
        if let network {
            arguments += ["--network", network]
        }
        if let bridgeInterface, !bridgeInterface.isEmpty {
            arguments += ["--bridge-interface", bridgeInterface]
        }
        arguments += networkArguments
        if let unlocksAtStartup {
            arguments += ["--unlock-at-startup", unlocksAtStartup ? "on" : "off"]
        }
        if let syncsHostLocation {
            arguments += ["--sync-host-location", syncsHostLocation ? "on" : "off"]
        }
        await perform(String(localized: "Saving settings…"), on: machine, arguments)
    }

    /// Records a new patch choice for the machine with its own bundle's
    /// `fw set-patches`. Nothing in the guest changes until the guest
    /// environment is updated, or, for the boot chain, the machine restored.
    @discardableResult
    func setPatches(_ selection: VPhoneLaunchpadPatchSelection, for machine: Path) async -> Bool {
        await perform(
            String(localized: "Saving patches…"),
            on: machine,
            ["fw", "set-patches", machine.name] + selection.setPatchesArguments + machine.libraryArguments,
        )
    }

    func rename(_ machine: Path, to newName: String) async {
        if await perform(String(localized: "Renaming…"), on: machine, ["vm", "rename", machine.name, newName] + machine.libraryArguments) {
            selection = [Path(libraryRoot: machine.libraryRoot, name: newName)]
        }
    }

    /// With `newIdentity` the clone gets its own ECID, UDID and MAC address,
    /// so both machines can run at once; a plain clone is the same device.
    func clone(_ machine: Path, as newName: String, newIdentity: Bool) async {
        if await perform(String(localized: "Cloning…"), on: machine, machine.cloneArguments(as: newName, newIdentity: newIdentity)) {
            selection = [Path(libraryRoot: machine.libraryRoot, name: newName)]
        }
    }

    /// Removing the folder needs nothing version-specific, so a machine whose
    /// own bundle is gone or from an unsupported series is deleted with the
    /// default one instead of having to be rebound first.
    func delete(_ machine: Path) async {
        await perform(
            String(localized: "Deleting…"),
            on: machine,
            ["vm", "delete", machine.name, "--force"] + machine.libraryArguments,
            anyBundle: true,
        )
    }

    // MARK: - Export

    /// An export queued or under way. `fraction` is nil until the command
    /// reports progress; `task` is nil while the export waits its turn.
    struct Export {
        var fraction: Double?
        fileprivate var task: Task<Void, Never>?

        var isWaiting: Bool {
            task == nil
        }
    }

    private(set) var exports: [Path: Export] = [:]

    /// Exports each machine to its destination file, one at a time: each
    /// export reads a whole disk image.
    func export(_ items: [(machine: Path, destination: URL)], densest: Bool, includeIPSW: Bool) async {
        for item in items {
            exports[item.machine] = Export()
        }
        for item in items {
            // Cancelled while it waited.
            guard exports[item.machine] != nil else {
                continue
            }
            let task = Task {
                await runExport(item.machine, to: item.destination, densest: densest, includeIPSW: includeIPSW)
            }
            exports[item.machine]?.task = task
            await task.value
            exports[item.machine] = nil
        }
    }

    /// Stops an export under way, or takes a waiting one out of the queue.
    func cancelExport(_ machine: Path) {
        guard let export = exports[machine] else {
            return
        }
        if let task = export.task {
            task.cancel()
        } else {
            exports[machine] = nil
        }
    }

    private func runExport(_ machine: Path, to destination: URL, densest: Bool, includeIPSW: Bool) async {
        var arguments = ["vm", "export", machine.name, "--out", destination.path] + machine.libraryArguments
        if densest {
            arguments.append("--max")
        }
        if includeIPSW {
            arguments.append("--include-ipsw")
        }
        await perform(String(localized: "Exporting…"), on: machine, arguments) { [weak self] fraction in
            Task { @MainActor in self?.exports[machine]?.fraction = fraction }
        }
        // `vm export` writes the archive in place, so a cancelled one leaves
        // a partial file behind.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    func importArchive(_ archive: URL) async {
        await perform(
            String(localized: "Importing \(archive.lastPathComponent)"),
            on: nil,
            ["vm", "import", archive.path, "--library-root", libraryRoot],
        )
    }

    /// Runs one command with `activity` shown as the machine's state. False
    /// when it failed, or was cancelled, which is not reported as an error.
    @discardableResult
    private func perform(
        _ activity: String,
        on machine: Path?,
        _ arguments: [String],
        anyBundle: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async -> Bool {
        do {
            try await performChecked(activity, on: machine, arguments, anyBundle: anyBundle, onProgress: onProgress)
            return true
        } catch {
            if !(error is CancellationError) {
                actionError = VPhoneLaunchpadError(actionFailure: error)
            }
            return false
        }
    }

    /// `perform` for a sheet that reports its own errors: throws what failed,
    /// or `CancellationError` when the command was cancelled.
    private func performChecked(
        _ activity: String,
        on machine: Path?,
        _ arguments: [String],
        anyBundle: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async throws {
        // A machine's commands run with its own bundle; `anyBundle` lets one
        // that needs no particular version fall back to the default.
        let commandLine: VPhoneLaunchpadCommandLine? = if let machine {
            self.commandLine(for: machine) ?? (anyBundle ? bundles.commandLine() : nil)
        } else {
            bundles.commandLine()
        }
        guard let commandLine else {
            if let machine {
                throw Self.missingBundle(machine)
            }
            throw CancellationError()
        }
        if let machine {
            activities[machine] = activity
        } else {
            globalActivity = activity
        }
        defer {
            if let machine {
                activities[machine] = nil
            } else {
                globalActivity = nil
            }
        }
        do {
            try await commandLine.runChecked(arguments, onProgress: onProgress)
            await refresh()
        } catch {
            await refresh()
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private static func missingBundle(_ machine: Path) -> VPhoneLaunchpadError {
        VPhoneLaunchpadError(
            String(localized: "Unable to Complete Action"),
            detail: String(localized: "The Core Bundle of \(machine.name) is not installed. Choose another Core Bundle for it."),
        )
    }

    // MARK: - Snapshots

    /// The machine's snapshots, oldest first, from its own bundle's
    /// `vm snapshot list --json`. Errors go to the caller, the Snapshots
    /// sheet, which shows them itself.
    func snapshots(of machine: Path) async throws -> [VPhoneLaunchpadMachineSnapshot] {
        guard let commandLine = commandLine(for: machine) else {
            throw Self.missingBundle(machine)
        }
        let result = try await commandLine.run(machine.snapshotListArguments, recordInHistory: false)
        guard result.succeeded, let data = result.jsonData else {
            throw VPhoneLaunchpadError(String(localized: "Unable to List Snapshots"), detail: result.tail)
        }
        return try VPhoneLaunchpadMachineSnapshot.list(from: data)
    }

    /// Takes a snapshot of a stopped machine, then saves its binding with it
    /// so a revert can tell which bundles built what the snapshot holds.
    func createSnapshot(of machine: Path, name: String, note: String?) async throws {
        try await performChecked(
            String(localized: "Taking snapshot…"),
            on: machine,
            machine.snapshotCreateArguments(name, note: note),
        )
        // The snapshot is taken either way; without the copy a revert can
        // only mark the guest environment and boot chain unknown.
        if let binding = currentBinding(of: machine) {
            try? binding.save(to: machine, snapshot: name)
        }
    }

    /// Puts a snapshot's disk, SEP storage and NVRAM back in place of the
    /// machine's own. What was there is gone unless it was snapshotted too.
    func revertSnapshot(of machine: Path, to name: String) async throws {
        try await performChecked(
            String(localized: "Reverting to snapshot…"),
            on: machine,
            machine.snapshotRevertArguments(name),
        )
        // The guest environment and the boot chain are on the disk and in
        // the NVRAM the revert just replaced, so the binding takes them from
        // the copy saved with the snapshot, or become unknown when there is
        // none to read (a snapshot taken with vphone-cli, or a copy that was
        // not written). The bundle is not on the disk: the machine keeps
        // running with the one chosen now.
        if let current = currentBinding(of: machine) {
            let saved = VPhoneLaunchpadMachineBinding.load(machine, snapshot: name)
            try? bind(machine, current.reverted(to: saved))
        }
    }

    func deleteSnapshot(of machine: Path, name: String) async throws {
        try await performChecked(
            String(localized: "Deleting snapshot…"),
            on: machine,
            machine.snapshotDeleteArguments(name),
        )
    }

    // MARK: - Create

    func create(_ options: VPhoneLaunchpadCreationPipeline.Options) -> VPhoneLaunchpadCreationPipeline {
        let pipeline = VPhoneLaunchpadCreationPipeline(
            options: options,
            bundles: bundles,
            helper: helper,
            library: self,
        )
        creations[pipeline.machine] = pipeline
        UserDefaults.standard.set(options.libraryRoot, forKey: Self.lastRootKey)
        addLocation(options.libraryRoot)
        pipeline.start()
        return pipeline
    }

    func discardCreation(_ machine: Path) {
        if creations[machine]?.isRunning == false {
            creations[machine] = nil
        }
    }
}

#if DEBUG
    extension VPhoneLaunchpadMachineLibrary {
        func applyPreview(creation: VPhoneLaunchpadCreationPipeline) {
            machines = VPhoneLaunchpadPreview.machines
            hasListed = true
            externallyRunning = [VPhoneLaunchpadPreview.path("research-01")]
            startedAt = [VPhoneLaunchpadPreview.path("research-01"): Date().addingTimeInterval(-6130)]
            creations = [creation.machine: creation]
            selection = [VPhoneLaunchpadPreview.path("research-01")]
            // One machine on an older bundle whose guest environment was not
            // updated with it, so the inspector shows mixed versions.
            let current = VPhoneLaunchpadPreview.releases[1].version
            let older = VPhoneLaunchpadPreview.releases[2].version
            bindings = Dictionary(uniqueKeysWithValues: machines.map { machine in
                let binding = machine.name == "research-01"
                    ? VPhoneLaunchpadMachineBinding(bundle: current, bootChain: older, guestEnvironment: older)
                    : VPhoneLaunchpadMachineBinding(bundle: current, bootChain: current, guestEnvironment: current)
                return (machine.path, binding)
            })
        }

        /// The mock list without one machine, as a refresh leaves it after
        /// the machine is deleted.
        func applyPreview(removing machine: Path) {
            machines.removeAll { $0.path == machine }
            selection.remove(machine)
        }
    }
#endif
