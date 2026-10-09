import SwiftUI

/// New Machine's Template page: whether the machine is cloned from a
/// template, and how that template is slimmed. The switches are part of the
/// template's key: other switches make another template, and both stay.
struct VPhoneLaunchpadSlimmingSections: View {
    @Binding var usesTemplate: Bool
    @Binding var slimming: VPhoneLaunchpadSlimming

    var body: some View {
        Section {
            Toggle("Create from a template", isOn: $usesTemplate)
        } header: {
            Text("Template")
        } footer: {
            Text(usesTemplate
                ? "Machines from one template share its SEP root secret and Data volume keys. Turn this off for a machine that needs keys of its own."
                : "The machine is restored on its own, with keys of its own. It is not slimmed, and starts at Setup Assistant.")
                .foregroundStyle(.secondary)
        }

        if usesTemplate {
            filesSection
            servicesSection
            appsSection
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        Section {
            Picker("Trim", selection: $slimming.trim) {
                ForEach(VPhoneLaunchpadSlimming.TrimTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            if slimming.trim == .standard {
                TextField("Kept Languages", text: $slimming.keptLanguages, prompt: Text(verbatim: VPhoneLaunchpadSlimming.defaultLanguages))
            }
        } header: {
            Text("System Files")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(trimNote).foregroundStyle(.secondary)
                if let problem = slimming.problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
        }
        .disabled(!slimming.slim)
    }

    private var trimNote: String {
        switch slimming.trim {
        case .none:
            String(localized: "Nothing is deleted from the System volume.")
        case .conservative:
            String(localized: "Deletes the software update ramdisk and baseband firmware, about 0.4 GB. It cannot be undone: the trim is part of the template.")
        case .standard:
            String(localized: "Also deletes the AirPods pairing assets, watch faces and the language data of languages not kept, about 1.2 GB. It cannot be undone: the trim is part of the template.")
        }
    }

    // MARK: - Services

    private var servicesSection: some View {
        Section {
            Toggle("Turn off unneeded services", isOn: $slimming.trimsServices)
            Toggle("Turn off Apple Account", isOn: $slimming.accountsOff)
                .disabled(!slimming.trimsServices)
        } header: {
            Text("Services")
        } footer: {
            Text("About 140 launch daemons a research machine rarely needs. Each machine can switch them back on in Guest System. Without Apple Account the guest cannot sign in.")
                .foregroundStyle(.secondary)
        }
        .disabled(!slimming.slim)
    }

    // MARK: - Apps

    private var appsSection: some View {
        Section {
            Toggle("Remove system apps", isOn: $slimming.removesApps)
            if slimming.removesApps {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                    ForEach(VPhoneLaunchpadSlimming.removableApps) { app in
                        Toggle(isOn: removes(app.id)) {
                            Text(verbatim: app.name)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        } header: {
            Text("System Apps")
        } footer: {
            Text("Checked apps are removed. Camera and Phone are never removed. Each machine can restore removed apps in Guest System.")
                .foregroundStyle(.secondary)
        }
        .disabled(!slimming.slim)
    }

    private func removes(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { !slimming.keptApps.contains(bundleID) },
            set: { removed in
                if removed {
                    slimming.keptApps.remove(bundleID)
                } else {
                    slimming.keptApps.insert(bundleID)
                }
            },
        )
    }
}
