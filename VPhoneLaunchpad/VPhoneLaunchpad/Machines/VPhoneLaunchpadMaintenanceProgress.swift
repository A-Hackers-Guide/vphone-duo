import Foundation

// MARK: - Maintenance progress

/// What the output of `cfw install`, `cfw update-environment` or
/// `cfw update-kernel` says about how far it has come. The CLI reports no
/// fraction, but it starts each step with an unindented `[*]` line and marks
/// a step that failed with `[!]`, which a run of several hundred lines of
/// patch detail otherwise buries.
nonisolated struct VPhoneLaunchpadMaintenanceProgress: Equatable, Sendable {
    /// The step under way: the last unindented `[*]`, `[+]` or `[!]` line,
    /// without its marker.
    private(set) var stage: String?
    /// Lines that say something went wrong, at any depth: `[!]` steps left
    /// in their prior state, `warning:` and `error:` lines. The first
    /// `maximumWarnings` are kept.
    private(set) var warnings: [String] = []
    /// Every such line, kept or not.
    private(set) var warningCount = 0

    static let maximumWarnings = 50

    private static let stageMarkers = ["[*] ", "[+] ", "[!] "]
    private static let warningPrefixes = ["warning:", "error:"]

    /// Cheap enough to ask of every line on the helper's queue, so only the
    /// few lines that change the progress cross to the main actor.
    static func isNotable(_ line: String) -> Bool {
        stageMarkers.contains(where: line.hasPrefix) || warning(in: line) != nil
    }

    mutating func read(_ line: String) {
        if let marker = Self.stageMarkers.first(where: line.hasPrefix) {
            let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                stage = text
            }
        }
        if let warning = Self.warning(in: line) {
            warningCount += 1
            if warnings.count < Self.maximumWarnings {
                warnings.append(warning)
            }
        }
    }

    /// The line, trimmed and without a `[!]` marker, when it reports a
    /// failure or a warning.
    private static func warning(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[!]") {
            let text = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        let lowered = trimmed.lowercased()
        return warningPrefixes.contains(where: lowered.hasPrefix) ? trimmed : nil
    }
}
