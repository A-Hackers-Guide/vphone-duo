import SwiftUI

struct VPhoneGyroscopeView: View {
    let model: VPhoneGyroscopeModel
    let connected: @MainActor () -> Bool

    var body: some View {
        VPhoneGyroscopeEditor(model: model)
            .task(id: connected()) { await model.connectionChanged(connected()) }
    }
}

struct VPhoneGyroscopeEditor: View {
    @Bindable var model: VPhoneGyroscopeModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: $model.enabled) {
                        Text("Enable Simulation", bundle: VPhoneLocalization.bundle)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("gyroscope-enabled")
                    Text("Changes sync to the guest immediately. Disabling keeps your axis values.", bundle: VPhoneLocalization.bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    VPhoneGyroscopeAxisRow(axis: "X", text: $model.xText, value: $model.xValue)
                    VPhoneGyroscopeAxisRow(axis: "Y", text: $model.yText, value: $model.yValue)
                    VPhoneGyroscopeAxisRow(axis: "Z", text: $model.zText, value: $model.zValue)
                    if model.hasInvalidAxes {
                        Text("Enter a number from -1000 to 1000 for each axis.", bundle: VPhoneLocalization.bundle)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button { model.reset() } label: {
                        Label {
                            Text("Reset", bundle: VPhoneLocalization.bundle)
                        } icon: { Image(systemName: "arrow.counterclockwise") }
                    }
                    .accessibilityIdentifier("gyroscope-reset")
                    .help(Text("Set all three axes to zero", bundle: VPhoneLocalization.bundle))
                } header: {
                    Text("Angular Velocity", bundle: VPhoneLocalization.bundle)
                }
            }
            .formStyle(.grouped)
            .disabled(!model.canEdit)
            Divider()
            VPhoneGyroscopeSyncStatus(model: model)
        }
    }
}

struct VPhoneGyroscopeAxisRow: View {
    let axis: String
    @Binding var text: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: axis)
                .font(.system(.body, design: .monospaced))
            TextField(axis, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel(VPhoneLocalization.format("%@ axis", axis))
                .accessibilityIdentifier("gyroscope-axis-" + axis.lowercased())
            Text(verbatim: "rad/s").foregroundStyle(.secondary)
            Stepper(axis, value: $value, in: -1000 ... 1000, step: 0.1)
                .labelsHidden()
                .accessibilityLabel(VPhoneLocalization.format("%@ axis", axis))
        }
    }
}

struct VPhoneGyroscopeSyncStatus: View {
    let model: VPhoneGyroscopeModel

    var body: some View {
        HStack(spacing: 8) {
            if !model.isConnected {
                Text("Guest not connected", bundle: VPhoneLocalization.bundle)
            } else if model.isReading || model.isSending {
                ProgressView().controlSize(.small)
                Text("Syncing…", bundle: VPhoneLocalization.bundle)
            } else if let error = model.error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(VPhoneLocalization.text(error)).textSelection(.enabled)
            } else if model.hasLoaded {
                Text(model.providerRunning ? "Synced" : "Waiting for sensor service…", bundle: VPhoneLocalization.bundle)
            }
            Spacer(minLength: 0)
            if model.canRetry {
                Button { model.retry() } label: { Text("Retry", bundle: VPhoneLocalization.bundle) }
            } else if model.isConnected && !model.hasLoaded && !model.isReading {
                Button { Task { await model.connectionChanged(true) } } label: {
                    Text("Retry", bundle: VPhoneLocalization.bundle)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(8)
        .background(.bar)
    }
}

#Preview {
    let sample = VPhoneGyroscopeReply(
        configuration: VPhoneGyroscopeConfiguration(enabled: true, x: 1.25, y: 0, z: -0.75),
        providerRunning: true,
    )
    let model = VPhoneGyroscopeModel(read: { sample }, write: {
        VPhoneGyroscopeReply(configuration: $0, providerRunning: true)
    })
    return VPhoneGyroscopeView(model: model, connected: { true })
        .frame(width: 440, height: 380)
}
