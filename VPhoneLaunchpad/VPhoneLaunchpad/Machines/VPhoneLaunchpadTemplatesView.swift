import SwiftUI

// MARK: - Templates

/// Every library's machine templates, from `vm template list --json`, with
/// Delete. New Machine builds a template the first time a combination of
/// firmware, preset, disk size and slimming is asked for, and clones every
/// later machine with that combination from it.
struct VPhoneLaunchpadTemplatesView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: VPhoneLaunchpadTemplate.ID?
    @State private var deletion: VPhoneLaunchpadTemplate?
    @State private var buildDeletion: (libraryRoot: String, name: String)?
    @State private var isDeleting = false
    @State private var actionError: VPhoneLaunchpadError?

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    private var templates: [VPhoneLaunchpadTemplate] {
        library.templates ?? []
    }

    private var selected: VPhoneLaunchpadTemplate? {
        templates.first { $0.id == selection }
    }

    /// Builds no create holds any more.
    private var leftovers: [(libraryRoot: String, build: VPhoneLaunchpadTemplateList.Building)] {
        library.templateBuilds.filter { !$0.build.active }
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Templates")) {
            VStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let selected {
                    Divider()
                    detail(selected)
                }
                ForEach(leftovers, id: \.build.path) { leftover in
                    Divider()
                    HStack {
                        Label("A template build stopped before it finished: \(leftover.build.name)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Delete…") { buildDeletion = (leftover.libraryRoot, leftover.build.name) }
                            .disabled(isDeleting)
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        } accessory: {
            Button("Delete…") { deletion = selected }
                .disabled(selected == nil || isDeleting)
                .help(String(localized: "Delete the selected template. Machines created from it keep working."))
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 980, height: 480)
        .task { await reload() }
        .confirmationDialog(
            deletion.map { String(localized: "Delete template \($0.id)?") } ?? "",
            isPresented: Binding(get: { deletion != nil }, set: {
                if !$0 {
                    deletion = nil
                }
            }),
            presenting: deletion,
        ) { template in
            Button("Delete", role: .destructive) {
                Task { await delete(template.id, in: template.libraryRoot) }
            }
        } message: { template in
            Text(deletionMessage(template))
        }
        .confirmationDialog(
            String(localized: "Delete the unfinished template build?"),
            isPresented: Binding(get: { buildDeletion != nil }, set: {
                if !$0 {
                    buildDeletion = nil
                }
            }),
        ) {
            Button("Delete", role: .destructive) {
                if let build = buildDeletion {
                    Task { await delete(build.name, in: build.libraryRoot) }
                }
            }
        } message: {
            Text("Its restored disk is deleted. A machine that needs this template builds it again.")
        }
        .errorAlert($actionError)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if library.templates == nil {
            if let error = library.templatesError {
                ContentUnavailableView("Unable to List Templates", systemImage: "exclamationmark.triangle", description: Text(verbatim: error))
            } else {
                ProgressView().controlSize(.small)
            }
        } else if templates.isEmpty {
            ContentUnavailableView {
                Label("No Templates", systemImage: "square.stack.3d.up")
            } description: {
                Text("New Machine builds a template the first time it creates a machine from a firmware, and clones every later machine with the same options from it.")
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(templates, selection: $selection) {
            TableColumn("Template") { template in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: template.key.device)
                    Text(verbatim: template.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .help(template.path)
            }
            .width(min: 84, ideal: 96)
            TableColumn("OS") { template in
                Text(verbatim: "\(template.key.osName) \(template.key.iOSVersion) (\(template.key.iOSBuild))")
                    .help(Text(verbatim: "cloudOS \(template.key.cloudOSVersion) (\(template.key.cloudOSBuild))"))
            }
            .width(min: 130, ideal: 150)
            TableColumn("Preset") { template in
                Text(verbatim: "\(template.key.patchPreset), \(template.key.diskSizeGB) GB")
            }
            .width(min: 110, ideal: 120)
            TableColumn("Slimming") { template in
                Text(template.key.slimming.summary)
                    .lineLimit(1)
                    .help(slimmingHelp(template.key.slimming))
            }
            .width(min: 120, ideal: 150)
            TableColumn("Size") { template in
                Text(verbatim: VPhoneLaunchpadDiskUsage.format(template.allocatedBytes))
                    .monospacedDigit()
                    .help(sizeHelp(template))
            }
            .width(min: 60, ideal: 70)
            .alignment(.numeric)
            TableColumn("Machines") { template in
                Text(verbatim: template.machines.isEmpty ? "—" : template.machines.joined(separator: ", "))
                    .foregroundStyle(template.machines.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(template.machines.joined(separator: ", "))
            }
            .width(min: 64, ideal: 86)
            TableColumn("State") { template in
                if template.stale {
                    Label {
                        Text("Outdated")
                    } icon: {
                        VPhoneLaunchpadStatusIcon(status: .warning)
                    }
                    .help(template.staleReasons.joined(separator: "\n"))
                } else {
                    Label {
                        Text("Current")
                    } icon: {
                        VPhoneLaunchpadStatusIcon(status: .passed)
                    }
                }
            }
            .width(min: 76, ideal: 84)
            TableColumn("Created") { template in
                Text(template.created, format: .dateTime.year().month(.defaultDigits).day())
                    .help(template.created.formatted(date: .long, time: .shortened))
            }
            .width(min: 70, ideal: 84)
        }
        .onDeleteCommand { deletion = selected }
    }

    /// The selected template's details that do not fit a column.
    private func detail(_ template: VPhoneLaunchpadTemplate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if template.stale {
                Label {
                    Text("Outdated: \(template.staleReasons.joined(separator: "; ")). New machines get a new template; this one only takes space.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
            }
            if let sources = template.sources {
                Text("Built from \(URL(string: sources.iPhone)?.lastPathComponent ?? sources.iPhone) and cloudOS \(template.key.cloudOSVersion) (\(template.key.cloudOSBuild)).")
            }
            Text("Built with Core Bundle \(template.builtWithBundleVersion ?? "—"); every machine from it shares its SEP root secret and Data volume keys.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Text

    private func slimmingHelp(_ slimming: VPhoneLaunchpadTemplate.Slimming) -> String {
        var lines: [String] = []
        if slimming.tier != "none" {
            lines.append(String(localized: "Trim: \(slimming.trimTier)"))
        }
        lines.append(String(localized: "Service profile: \(slimming.serviceProfile)"))
        if !slimming.removedApps.isEmpty {
            lines.append(String(localized: "Removed: \(slimming.removedApps.map(VPhoneLaunchpadSlimming.appName).joined(separator: ", "))"))
        }
        return lines.joined(separator: "\n")
    }

    private func sizeHelp(_ template: VPhoneLaunchpadTemplate) -> String {
        guard let exclusive = library.usage(of: template)?.exclusive else {
            return String(localized: "Allocated on disk.")
        }
        return String(localized: "Allocated on disk; deleting it frees about \(VPhoneLaunchpadDiskUsage.format(exclusive)), the blocks no machine shares, once no local Time Machine snapshot keeps them.")
    }

    private func deletionMessage(_ template: VPhoneLaunchpadTemplate) -> String {
        var parts: [String] = []
        if template.machines.isEmpty {
            parts.append(String(localized: "No machine was created from it."))
        } else {
            parts.append(String(localized: "\(template.machines.joined(separator: ", ")) keep working: they share its blocks but do not need it."))
        }
        if let exclusive = library.usage(of: template)?.exclusive {
            parts.append(String(localized: "Deleting it frees about \(VPhoneLaunchpadDiskUsage.format(exclusive)), once no local Time Machine snapshot keeps those blocks; the blocks its machines share are freed once they change or are deleted."))
        }
        parts.append(String(localized: "The next machine with its options builds a new template, which takes a restore."))
        return parts.joined(separator: " ")
    }

    // MARK: - Actions

    private func reload() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                library.applyPreviewTemplates()
                selection = selection ?? VPhoneLaunchpadPreview.templates.first?.id
                return
            }
        #endif
        await library.refreshTemplates()
        if let selection, !templates.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    private func delete(_ name: String, in root: String) async {
        guard !isDeleting else {
            return
        }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await library.deleteTemplate(name, in: root)
        } catch is CancellationError {
            return
        } catch {
            actionError = VPhoneLaunchpadError(actionFailure: error)
        }
        await reload()
    }
}
