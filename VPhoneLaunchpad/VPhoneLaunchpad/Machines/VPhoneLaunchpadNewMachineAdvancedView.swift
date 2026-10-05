import SwiftUI

/// New Machine's Advanced page: network, patches and restore options, as
/// sections of New Machine's form. It edits New Machine's own state.
struct VPhoneLaunchpadNewMachineAdvancedView: View {
    @Binding var network: String
    @Binding var patches: VPhoneLaunchpadPatchSelection
    @Binding var keepArtifacts: Bool
    let patchCatalog: VPhoneLaunchpadPatchCatalog?
    let patchCatalogError: String?
    /// New Machine owns the catalog, which is read again for each preset.
    let reloadPatches: () -> Void
    /// The Core Bundle chosen in New Machine, whose patches the editor lists.
    /// Nil reads the default version's.
    var bundleVersion: String?

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var showsPatchSettings = false

    var body: some View {
        Section("Network") {
            Picker("Mode", selection: $network) {
                Text("NAT").tag("nat")
                Text("Bridged").tag("bridged")
                Text("Tunnel").tag("tunnel")
                Text("None").tag("none")
            }
            if network == "tunnel" {
                Text("Traffic leaves through this Mac's own connections, so it follows the Mac's VPN.")
                    .foregroundStyle(.secondary)
            }
        }

        patchSection

        Section("Options") {
            Toggle("Keep prepared restore files", isOn: $keepArtifacts)
        }
    }

    // MARK: - Patches

    private var patchSection: some View {
        Section {
            if let patchCatalog {
                Picker("Preset", selection: presetBinding) {
                    ForEach(patchCatalog.presets) { preset in
                        Text(verbatim: preset.displayTitle).tag(preset.identifier)
                    }
                }
                LabeledContent("Patches") {
                    Button("Patch Settings…") { showsPatchSettings = true }
                        .sheet(isPresented: $showsPatchSettings) {
                            VPhoneLaunchpadPatchSettingsView(initial: patches, bundleVersion: bundleVersion) { selection in
                                patches = selection
                                reloadPatches()
                            }
                            .environment(model)
                        }
                }
            } else if let patchCatalogError {
                Label(patchCatalogError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading the bundle's patches…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Patches")
        } footer: {
            patchNote
        }
    }

    @ViewBuilder
    private var patchNote: some View {
        let essentialOff = patchCatalog.map { patches.bootEssentialOff(in: $0) } ?? []
        VStack(alignment: .leading, spacing: 4) {
            if let summary = patchCatalog?.preset(patches.preset)?.displaySummary, !summary.isEmpty {
                Text(verbatim: summary).foregroundStyle(.secondary)
            }
            if patches.hasOverrides {
                Text("Differs from the preset: \(patches.blocked.count) off, \(patches.allowed.count) on.")
                    .foregroundStyle(.secondary)
            }
            if !essentialOff.isEmpty {
                Label {
                    Text("^[\(essentialOff.count) boot-essential patch](inflect: true) off: \(essentialOff.map(\.identifier).joined(separator: ", "))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }
        }
    }

    /// Switching preset here re-bases the overrides for the same reason the editor
    /// does: they are read as a difference from whichever preset is active.
    private var presetBinding: Binding<String> {
        Binding(
            get: { patches.preset },
            set: { identifier in
                guard identifier != patches.preset else {
                    return
                }
                patches = VPhoneLaunchpadPatchSelection(preset: identifier)
                reloadPatches()
            },
        )
    }
}
