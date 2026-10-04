import Foundation

extension VPhoneGuestControl {
    // MARK: - URL

    func openURL(_ url: String) async throws {
        let (resp, _) = try await sendRequest(["t": "open_url", "url": url])
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            let msg = resp["msg"] as? String ?? "failed to open URL"
            throw ControlError.guestError(msg)
        }
    }

    // MARK: - Settings

    func settingsGet(domain: String, key: String? = nil) async throws -> Any? {
        var req: [String: Any] = ["t": "settings_get", "domain": domain]
        if let key {
            req["key"] = key
        }
        let (resp, _) = try await sendRequest(req)
        return resp["value"]
    }

    func settingsSet(domain: String, key: String, value: Any, type: String? = nil) async throws {
        var req: [String: Any] = ["t": "settings_set", "domain": domain, "key": key, "value": value]
        if let type {
            req["type"] = type
        }
        _ = try await sendRequest(req)
    }

    func lowPowerMode(enabled: Bool) async throws {
        let (resp, _) = try await sendRequest(["t": "low_power_mode", "enabled": enabled])
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            throw ControlError.guestError("low_power_mode: failed to set state on guest")
        }
    }

    // MARK: - Time Zone

    /// Pins the guest's system time zone to an Olson name such as
    /// `Asia/Shanghai` and turns its automatic time zone off. Returns false
    /// when the guest was already pinned to it.
    func setTimeZone(_ identifier: String) async throws -> Bool {
        let result = try await call("time.timezone", params: ["identifier": identifier])
        return result["changed"] as? Bool ?? false
    }

    // MARK: - Audio

    /// Tells the guest's sound plugin what the Mac's output device adds after
    /// its mixer, in seconds. Returns false when the guest already had it.
    func setHostAudioLatency(_ seconds: Double) async throws -> Bool {
        let result = try await call("audio.host_latency", params: ["seconds": seconds])
        return result["changed"] as? Bool ?? false
    }

    // MARK: - Unlock at Startup

    /// Wakes a guest whose vphoned has just started and dismisses its Lock
    /// Screen through `screen.unlock`. vphoned can come up well before
    /// SpringBoard on a cold boot; the method waits for SpringBoard itself, so
    /// it is given the longest timeout it takes. A guest with a passcode
    /// refuses without one and stays locked: the passcode is never stored.
    func unlockAtStartup() async {
        do {
            let result = try await call("screen.unlock", params: ["timeout": 60])
            if result["was_locked"] as? Bool == true {
                print("[unlock] dismissed the Lock Screen at startup")
            } else {
                print("[unlock] the guest was already unlocked")
            }
        } catch {
            print("[unlock] could not unlock the guest at startup: \(error)")
        }
    }
}
