import SwiftUI

// MARK: - Downloaded IPSWs

/// The IPSWs `fw prepare` has downloaded, with Delete. The files are those in
/// the shared IPSW cache and in the `ipsws` folder beside each library,
/// named by their BuildManifest and, when the default Core Bundle's `fw
/// catalog` lists them, by the catalog. A machine uses an IPSW when its
/// restore-info.json names that release (and its product type is among the
/// IPSW's), or when its creation was given the IPSW as a source.
struct VPhoneLaunchpadIPSWCacheView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Nil until the first scan answers.
    @State private var scan: VPhoneLaunchpadIPSWCache.Scan?
    @State private var catalog: VPhoneLaunchpadIPSWCatalogNames?
    @State private var selection: VPhoneLaunchpadIPSWRow.ID?
    @State private var deletion: VPhoneLaunchpadIPSWRow?
    @State private var isDeleting = false
    @State private var actionError: VPhoneLaunchpadError?

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    private var rows: [VPhoneLaunchpadIPSWRow] {
        guard let scan else {
            return []
        }
        return VPhoneLaunchpadIPSWRows.rows(scan.ipsws, catalog: catalog, uses: uses(scan), isCreating: library.hasActiveCreation)
    }

    private var selected: VPhoneLaunchpadIPSWRow? {
        rows.first { $0.id == selection }
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Downloaded IPSWs")) {
            VStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let reason = selected?.blockedReason {
                    Divider()
                    Label(reason, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        } accessory: {
            Button("Delete…") { confirmDeletion() }
                .disabled(selected == nil || selected?.blockedReason != nil || isDeleting)
                .help(selected?.blockedReason ?? String(localized: "Delete the selected IPSW from the IPSW cache."))
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 760, height: 440)
        // Again whenever the machines or creations change, and every few
        // seconds while a creation runs, since its download grows.
        .task(id: scanKey) {
            await rescan()
            while library.hasActiveCreation, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await rescan()
            }
        }
        .task(id: model.bundles.defaultVersion) { await loadCatalog() }
        .confirmationDialog(
            deletion.map { String(localized: "Delete \($0.title)?") } ?? "",
            isPresented: Binding(get: { deletion != nil }, set: {
                if !$0 {
                    deletion = nil
                }
            }),
            presenting: deletion,
        ) { row in
            Button(String(localized: "Delete \(Self.size(row.size))"), role: .destructive) {
                Task { await delete(row) }
            }
        } message: { row in
            Text(VPhoneLaunchpadIPSWRows.deletionMessage(row))
        }
        .errorAlert($actionError)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if scan == nil {
            ProgressView()
                .controlSize(.small)
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label("No Downloaded IPSWs", systemImage: "externaldrive")
            } description: {
                Text("The IPSWs a machine is created from are downloaded into the IPSW cache and listed here.")
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Image") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.isDownloading ? String(localized: "\(row.fileName) (partial download)") : row.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(row.fileName)
            }
            .width(min: 200, ideal: 320)
            TableColumn("Kind") { row in
                Text(verbatim: row.kindLabel)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("Size") { row in
                Text(verbatim: Self.size(row.size))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80, max: 100)
            .alignment(.numeric)
            TableColumn("Used By") { row in
                let names = row.usedBy.joined(separator: ", ")
                Text(verbatim: names.isEmpty ? "—" : names)
                    .foregroundStyle(names.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(names)
            }
        }
        .onDeleteCommand { confirmDeletion() }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Data

    /// Changes when a scan, or the uses read from the library, would change.
    private var scanKey: [String] {
        let machines = library.machines.map { machine in
            "\(machine.libraryRoot)/\(machine.name):\(machine.restoreInfo.map { "\($0.ios.build)+\($0.cloudOS.build)" } ?? "")"
        }
        let creations = library.creations.map { path, creation in
            "\(path.libraryRoot)/\(path.name):\(creation.isRunning):\(creation.isFinished)"
        }
        return [library.hasListed ? "listed" : "unlisted"] + library.roots + machines + creations.sorted()
    }

    private func rescan() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                scan = VPhoneLaunchpadPreview.ipswScan
                selection = selection ?? VPhoneLaunchpadPreview.ipswSelection
                return
            }
        #endif
        do {
            let scan = try await VPhoneLaunchpadIPSWCache.scan(
                libraryRoots: library.roots,
                machineFolders: library.machines.map(\.path.url),
            )
            self.scan = scan
            if let selection, !scan.ipsws.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        } catch {
            // Cancelled: the sheet closed or the machines changed again.
        }
    }

    /// Each listed machine, with the sources of its creation if it has one,
    /// then each creation whose machine is not listed yet.
    private func uses(_ scan: VPhoneLaunchpadIPSWCache.Scan) -> [VPhoneLaunchpadIPSWUse] {
        var uses: [VPhoneLaunchpadIPSWUse] = []
        for machine in library.machines {
            let creation = library.creations[machine.path]
            uses.append(VPhoneLaunchpadIPSWUse(
                machine: machine.name,
                productType: scan.productTypes[machine.path.url.path],
                ios: machine.restoreInfo.map { .init(version: $0.ios.version, build: $0.ios.build) },
                cloudOS: machine.restoreInfo.map { .init(version: $0.cloudOS.version, build: $0.cloudOS.build) },
                sources: creation.map { [$0.options.iphoneSource, $0.options.cloudOSSource] } ?? [],
                isCreating: creation?.isRunning == true,
                needsSources: creation.map { !$0.isFinished } ?? false,
            ))
        }
        for (path, creation) in library.creations where !library.machines.contains(where: { $0.path == path }) {
            uses.append(VPhoneLaunchpadIPSWUse(
                machine: path.name,
                sources: [creation.options.iphoneSource, creation.options.cloudOSSource],
                isCreating: creation.isRunning,
                needsSources: !creation.isFinished,
            ))
        }
        return uses
    }

    // MARK: - Catalog

    /// The catalog names of each Core Bundle version, read once per session.
    private static var catalogs: [String: VPhoneLaunchpadIPSWCatalogNames] = [:]

    private func loadCatalog() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                catalog = VPhoneLaunchpadPreview.catalog.map(VPhoneLaunchpadIPSWCatalogNames.init)
                return
            }
        #endif
        guard let version = model.bundles.defaultVersion,
              let commandLine = model.bundles.commandLine(version: version)
        else {
            return
        }
        if let known = Self.catalogs[version] {
            catalog = known
            return
        }
        // Without a catalog the rows are named from their manifests.
        guard let result = try? await commandLine.run(["fw", "catalog", "--json"], recordInHistory: false),
              result.succeeded, let data = result.jsonData,
              let report = try? JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: data)
        else {
            return
        }
        let names = VPhoneLaunchpadIPSWCatalogNames(report)
        Self.catalogs[version] = names
        catalog = names
    }

    // MARK: - Deleting

    /// A row that cannot go says why at once; any other asks first.
    private func confirmDeletion() {
        guard let row = selected, !isDeleting else {
            return
        }
        if let reason = row.blockedReason {
            actionError = VPhoneLaunchpadError(String(localized: "Unable to Delete \(row.title)"), detail: reason)
        } else {
            deletion = row
        }
    }

    /// Checks the IPSW again at the moment of deletion: a creation may have
    /// started since the list was read.
    private func delete(_ row: VPhoneLaunchpadIPSWRow) async {
        guard !isDeleting, let scan, let file = scan.ipsws.first(where: { $0.id == row.id }) else {
            return
        }
        let failure = String(localized: "Unable to Delete \(row.title)")
        if let reason = VPhoneLaunchpadIPSWRows.deletionBlock(file, uses: uses(scan), isCreating: library.hasActiveCreation) {
            actionError = VPhoneLaunchpadError(failure, detail: reason)
            return
        }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await VPhoneLaunchpadIPSWCache.removeIPSW(file.url, cacheDirectories: scan.cacheDirectories)
        } catch {
            actionError = VPhoneLaunchpadError(failure, detail: error.localizedDescription)
        }
        await rescan()
    }
}

extension VPhoneLaunchpadIPSWCatalogNames {
    /// Every iOS, iPadOS and cloudOS image the catalog names.
    init(_ catalog: VPhoneLaunchpadFirmwareCatalog) {
        self.init(images: catalog.guests.flatMap { device in
            device.pairings.flatMap { pairing in
                [(pairing.ios.name, pairing.ios.url), (pairing.recommendedCloudOS.name, pairing.recommendedCloudOS.url)]
            }
        })
    }
}
