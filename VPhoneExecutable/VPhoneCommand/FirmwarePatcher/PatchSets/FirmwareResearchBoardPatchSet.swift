// FirmwareResearchBoardPatchSet.swift — Manifest for the research board fallback.
//
// The guest boots the vphone600 device tree and SEP firmware, but only the
// 26.1–26.4 beta cloudOS releases carry a vphone600ap identity. Every other
// cloudOS ships the research board alone, vresearch101ap, and `fw prepare` then
// takes its components instead (`FirmwareManifest.generate`). The patches here
// turn those into what vphone600 would have been.
//
// Every shipped preset names this set. Its patches only write where they find
// the research board, so on a cloudOS with vphone600 components they record
// nothing: the fallback costs the other presets nothing and needs no version
// gate. They are boot-essential where they apply.

import Foundation
import VPhonePatchKit

public enum FirmwareResearchBoardPatchSet {
    public static let identifier = "com.vphone.patchset.research.board"

    /// The research board's device tree, rewritten as the vphone600 one.
    public static let deviceTreeConversion = "devicetree-boot-vresearch101_conversion"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Research Board",
        summary: "Converts a cloudOS without vphone600 components from the research board",
        patches: [
            VPhonePatchDeclaration(
                identifier: deviceTreeConversion,
                title: "vphone600 device tree",
                summary: "Gives the research board's device tree the vphone600 identity, product properties and nodes, so a cloudOS without vphone600ap boots an iPhone userland. Runs before every other device tree patch.",
                target: .firmware(.deviceTree),
                bootEssential: true,
            ),
        ],
        provides: ["vphone.research.board"],
    )
}
