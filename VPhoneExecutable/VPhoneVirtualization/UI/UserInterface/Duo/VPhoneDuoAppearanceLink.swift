import Foundation

// MARK: - Appearance Link

/// Keeps iOS's appearance with the Duo window's finish: Space Black is Dark,
/// Star White is Light.
///
/// The appearance is the `mobile` user's `UserInterfaceStyleMode` in
/// `com.apple.uikitservices.userInterfaceStyleMode` (1 Light, 2 Dark), the
/// value Settings ▸ Display & Brightness writes. vphoned's `settings.set`
/// writes it through cfprefsd, and SpringBoard and running apps follow at once.
/// The finish is sent again each time the guest's agent connects, so a guest
/// that booted while the window changed still matches it.
/// `VPHONE_DUO_FOLLOW_FINISH=0` leaves iOS's appearance alone.
@MainActor
final class VPhoneDuoAppearanceLink {
    static let domain = "com.apple.uikitservices.userInterfaceStyleMode"
    static let key = "UserInterfaceStyleMode"

    private weak var control: VPhoneGuestControl?
    private var finish: VPhoneDuoView.Finish
    /// The finish the guest has, or nil when it is not known.
    private var sent: VPhoneDuoView.Finish?
    private var connectionWatch: Timer?
    private var wasConnected = false

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VPHONE_DUO_FOLLOW_FINISH"] != "0"
    }

    /// The style mode a finish asks for.
    static func styleMode(for finish: VPhoneDuoView.Finish) -> Int {
        finish == .black ? 2 : 1
    }

    init(control: VPhoneGuestControl, finish: VPhoneDuoView.Finish) {
        self.control = control
        self.finish = finish
        connectionWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchConnection() }
        }
    }

    func stop() {
        connectionWatch?.invalidate()
        connectionWatch = nil
    }

    func apply(_ finish: VPhoneDuoView.Finish) {
        self.finish = finish
        send()
    }

    private func watchConnection() {
        let connected = control?.isConnected == true
        defer { wasConnected = connected }
        guard connected, !wasConnected else { return }
        sent = nil
        send()
    }

    private func send() {
        guard let control, control.isConnected, sent != finish else { return }
        let finish = finish
        sent = finish
        Task {
            do {
                try await control.settingsSet(
                    domain: Self.domain, key: Self.key, value: Self.styleMode(for: finish), type: "int",
                )
            } catch {
                if sent == finish { sent = nil }
                print("[vphone] Duo appearance not applied: \(error)")
            }
        }
    }
}
