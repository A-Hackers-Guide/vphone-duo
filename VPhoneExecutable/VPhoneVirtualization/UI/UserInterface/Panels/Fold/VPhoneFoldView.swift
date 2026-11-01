import SwiftUI

/// The three-state fold control, the guest-side counterpart of Apple's
/// simulator fold chrome: one picker for the screen states, one sweep
/// setting, and the hinge state the guest answered with.
struct VPhoneFoldView: View {
    let model: VPhoneFoldModel

    var body: some View {
        VPhoneFoldEditor(model: model)
            .task { await model.run() }
    }
}

private struct VPhoneFoldEditor: View {
    @Bindable var model: VPhoneFoldModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(String(localized: "Screen State", bundle: VPhoneLocalization.bundle), selection: $model.position) {
                        ForEach(VPhoneFoldPosition.allCases, id: \.self) { position in
                            Text(verbatim: position.title).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!model.canFold)
                    .accessibilityIdentifier("fold-position")
                    .onChange(of: model.position) { _, target in
                        Task { await model.set(target) }
                    }
                    Button {
                        Task { await model.set(model.position) }
                    } label: {
                        Label {
                            Text(model.animates ? "Sweep Again" : "Set Again", bundle: VPhoneLocalization.bundle)
                        } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(!model.canFold)
                    .accessibilityIdentifier("fold-repeat")
                } header: {
                    Text("Screen State", bundle: VPhoneLocalization.bundle)
                }
                Section {
                    Toggle(isOn: $model.animates) {
                        Text("Animate the fold (sweep)", bundle: VPhoneLocalization.bundle)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("fold-animate")
                    if model.animates {
                        Slider(
                            value: $model.duration,
                            in: 0.5 ... 10,
                            step: 0.5,
                        ) {
                            Text("Duration", bundle: VPhoneLocalization.bundle)
                        } minimumValueLabel: {
                            Text(verbatim: "0.5s").font(.caption).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text(verbatim: "10s").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("fold-duration")
                    }
                } header: {
                    Text("Sweep", bundle: VPhoneLocalization.bundle)
                }
                Section {
                    foldRow("Angle", model.reply.map { "\(Int($0.angle.rounded()))°" })
                    foldRow("Hinge State", model.reply.map(\.hinge.title))
                    foldRow("Hinge Service", model.reply.map {
                        $0.providerRunning ? "running" : ($0.applied ? "not running" : "absent")
                    })
                    foldRow("Sweep", model.reply?.sweepMilliseconds.map { milliseconds in
                        milliseconds < 0 ? "guest default" : String(format: "%.1fs", milliseconds / 1000)
                    })
                    Text("Closed uses the cover screen. Book and Open use the inner screen. Screen changes apply while the device is running.", bundle: VPhoneLocalization.bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Hinge Sensor", bundle: VPhoneLocalization.bundle)
                }
            }
            .formStyle(.grouped)
            .disabled(!model.isConnected)
            Divider()
            VPhoneGuestToolStatusBar(
                isConnected: model.isConnected,
                activity: model.isSending
                    ? String(localized: "Folding…", bundle: VPhoneLocalization.bundle)
                    : nil,
                status: model.status,
            )
        }
    }

    private func foldRow(_ title: LocalizedStringKey, _ value: String?) -> some View {
        HStack {
            Text(title, bundle: VPhoneLocalization.bundle)
            Spacer(minLength: 0)
            VPhonePanelMonoText(value ?? "—", secondary: value == nil)
        }
    }
}
