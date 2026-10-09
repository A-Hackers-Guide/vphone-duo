import Foundation

// MARK: - First-Boot Settle

/// Decides from polled signals whether a guest's first-boot work is done, so
/// a template can be changed and shut down without cutting it short.
///
/// On the first boot after a restore, installd expands the removable system
/// apps from `/System/Library/AppPlaceholders` into data-volume containers.
/// The ones still to do wait in `stagedSystemAppsPath`; installd empties it as
/// it goes. Removing an app or disabling services before that ends races the
/// expansion. Settled means, over the last `stablePolls` polls in a row:
///
/// - `staged_system_apps` is empty (or absent),
/// - the number of registered apps did not change,
/// - installd used less than `installdBusyCPUSeconds` of CPU between polls,
///   or was not running.
///
/// Measured on an iOS 27.0 template (P0, 2026-10-07): 92 s after `setup.skip`
/// all three held.
///
/// Nothing here touches the guest, so `VPhoneDaemon/Tests/run-logic-tests.sh`
/// builds this file on the Mac.
enum GuestFirstBootSettle {
    static let stagedSystemAppsPath = "/private/var/staged_system_apps"
    /// CPU seconds installd may use between two polls and still count as idle.
    static let installdBusyCPUSeconds = 0.2

    /// One poll.
    struct Sample: Equatable, Sendable {
        /// Seconds since the wait began.
        var time: Double
        /// Entries in `staged_system_apps`, 0 when it is absent, nil when it
        /// could not be read.
        var stagedSystemApps: Int?
        /// Registered apps, nil when LaunchServices did not answer.
        var appCount: Int?
        /// installd's pid and CPU time, nil when it is not running.
        var installdPID: Int?
        var installdCPUSeconds: Double?
    }

    struct Verdict: Equatable, Sendable {
        var settled: Bool
        /// Why not: one line per unmet condition, empty when settled.
        var reasons: [String]
        /// installd's CPU between the last two polls.
        var installdCPUDelta: Double?
    }

    /// CPU installd used from `earlier` to `later`. A new pid counts all of
    /// its CPU so far; no installd in `later` counts as none.
    static func installdCPUDelta(from earlier: Sample, to later: Sample) -> Double? {
        guard let pid = later.installdPID, let cpu = later.installdCPUSeconds else { return 0 }
        if earlier.installdPID == pid, let before = earlier.installdCPUSeconds {
            return max(cpu - before, 0)
        }
        return cpu
    }

    static func evaluate(_ samples: [Sample], stablePolls: Int) -> Verdict {
        let needed = max(stablePolls, 2)
        let window = Array(samples.suffix(needed))
        let lastDelta = window.count >= 2 ? installdCPUDelta(from: window[window.count - 2], to: window[window.count - 1]) : nil
        var reasons: [String] = []
        if window.count < needed {
            reasons.append("\(window.count) of \(needed) polls so far")
        }
        if let latest = window.last {
            switch latest.stagedSystemApps {
            case nil:
                reasons.append("staged_system_apps could not be read")
            case let count? where count > 0:
                reasons.append("staged_system_apps has \(count) entries")
            default:
                if window.contains(where: { ($0.stagedSystemApps ?? 1) != 0 }) {
                    reasons.append("staged_system_apps only just emptied")
                }
            }
            let counts = window.map(\.appCount)
            if counts.contains(where: { $0 == nil }) {
                reasons.append("app count unavailable")
            } else if Set(counts.compactMap(\.self)).count > 1 {
                let values = counts.compactMap(\.self).map(String.init).joined(separator: " → ")
                reasons.append("app count changed: \(values)")
            }
        }
        for (earlier, later) in zip(window, window.dropFirst()) {
            if let delta = installdCPUDelta(from: earlier, to: later), delta >= installdBusyCPUSeconds {
                reasons.append(String(format: "installd used %.2f s CPU between polls", delta))
                break
            }
        }
        return Verdict(settled: reasons.isEmpty, reasons: reasons, installdCPUDelta: lastDelta)
    }
}
