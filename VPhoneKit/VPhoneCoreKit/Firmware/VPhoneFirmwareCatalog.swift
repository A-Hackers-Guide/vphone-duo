import Foundation

// MARK: - VPhoneFirmwarePairing

/// A known restore-IPSW ↔ cloudOS pairing for one guest device, with friendly
/// names for prompts and the direct download URLs `fw prepare` consumes.
public struct VPhoneFirmwarePairing: Sendable, Equatable {
    /// The guest's product type: `iPhone17,3`, or the iPad model `fw prepare
    /// --device` picks from an IPSW that covers several.
    public let device: String
    public let iosName: String
    public let iosURL: String
    public let cloudosName: String
    public let cloudosURL: String

    public init(
        device: String = VPhoneFirmwareCatalog.device,
        iosName: String,
        iosURL: String,
        cloudosName: String,
        cloudosURL: String,
    ) {
        self.device = device
        self.iosName = iosName
        self.iosURL = iosURL
        self.cloudosName = cloudosName
        self.cloudosURL = cloudosURL
    }
}

// MARK: - VPhoneCloudOSOption

public struct VPhoneCloudOSOption: Sendable, Equatable {
    public let name: String
    public let url: String
    public init(name: String, url: String) {
        self.name = name; self.url = url
    }
}

// MARK: - VPhoneFirmwareCatalog

/// The known downloadable restore/cloudOS pairings, per guest device. Prompts
/// show the friendly `iosName`/`cloudosName`; selection resolves to the URLs.
public enum VPhoneFirmwareCatalog {
    /// The iPhone model every iPhone pairing targets, and the device a catalog
    /// lookup without one means.
    public static let device = "iPhone17,3"

    // cloudOS images (one per major); referenced by multiple iPhone builds.
    // cloud264 is the 26.4 beta (23E5207q), the last cloudOS with vphone600ap:
    // every release from 26.4 (23E244) to 26.7 (23H20) has only vresearch101ap,
    // so newer builds keep pairing with it.
    static let cloud261 = "https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349"
    static let cloud262 = "https://updates.cdn-apple.com/private-cloud-compute/0cb00f22e0f7a8b33995b49b2bdca77f781ed6093a09c570ac21b0f012bab908"
    static let cloud263 = "https://updates.cdn-apple.com/private-cloud-compute/edc92b58ab7e2f207a6407fd0a0e1a60f7d43bf9d93325bf6d3db3e154ee5525"
    static let cloud264 = "https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64"

    /// The iPhone17,3 pairings, oldest first. Launchpad offers the last one by
    /// default, so the newest release stays last.
    public static let pairings: [VPhoneFirmwarePairing] = [
        .init(iosName: "iOS 18.6.2", iosURL: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-20738/98758B5A-311E-4538-B365-FEE3D8792CDF/iPhone17,3_18.6.2_22G100_Restore.ipsw", cloudosName: "cloudOS 26.1", cloudosURL: cloud261),
        .init(iosName: "iOS 26.0", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-40775/B7282E74-76C1-4D0A-8FAE-CE97FC2330C2/iPhone17,3_26.0_23A341_Restore.ipsw", cloudosName: "cloudOS 26.1", cloudosURL: cloud261),
        .init(iosName: "iOS 26.0.1", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-46329/C1717B2A-9E58-4131-A398-75D9B1D01A89/iPhone17,3_26.0.1_23A355_Restore.ipsw", cloudosName: "cloudOS 26.1", cloudosURL: cloud261),
        .init(iosName: "iOS 26.1", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw", cloudosName: "cloudOS 26.1", cloudosURL: cloud261),
        .init(iosName: "iOS 26.2", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-90760/1214478F-8ED8-4AE0-B693-2F63CE0259A9/iPhone17,3_26.2_23C55_Restore.ipsw", cloudosName: "cloudOS 26.2", cloudosURL: cloud262),
        .init(iosName: "iOS 26.2.1", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/047-34150/D14FB1F1-B8C5-4A20-9250-8DD35EF19BF5/iPhone17,3_26.2.1_23C71_Restore.ipsw", cloudosName: "cloudOS 26.2", cloudosURL: cloud262),
        .init(iosName: "iOS 26.3", iosURL: "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-39165/E8E603F3-A2E2-4638-8067-394754896386/iPhone17,3_26.3_23D127_Restore.ipsw", cloudosName: "cloudOS 26.3", cloudosURL: cloud263),
        .init(iosName: "iOS 26.3.1", iosURL: "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-90312/17B5C7BE-C560-43BD-BA9A-7DD1E5C2FC23/iPhone17,3_26.3.1_23D8133_Restore.ipsw", cloudosName: "cloudOS 26.3", cloudosURL: cloud263),
        .init(iosName: "iOS 26.4", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-06082/FE21226A-B87F-4FC7-9D4B-B97A9EAF5C20/iPhone17,3_26.4_23E246_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.4.1", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-28526/10E1E3EC-6A3E-4620-A569-8E0C4361AB77/iPhone17,3_26.4.1_23E254_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.4.2", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-60828/A4082066-CCC4-4903-89E6-FF4801EA609C/iPhone17,3_26.4.2_23E261_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.5", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-63074/5E6B4A05-BDBC-45FE-9606-22B8F4315989/iPhone17,3_26.5_23F77_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.5.2", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25549/1AFB1F72-E48E-476A-9C21-42B27C846C01/iPhone17,3_26.5.2_23F84_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.6", iosURL: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-58193/1F477C3E-934B-43C0-B428-753B9E005EC0/iPhone17,3_26.6_23G71_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.6.1", iosURL: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-93817/B5362BAA-F3EE-49C8-BA43-309F0DAD1362/iPhone17,3_26.6.1_23G83_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.6.2", iosURL: "https://updates.cdn-apple.com/2026SummerFCS/29d685ce-f70d-45a0-9823-b1cd115f3927/iPhone17,3_26.6.2_23G90_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 1", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/122-99394/32118457-A80B-4953-BF2A-11F74FD7D375/iPhone17,3_27.0_24A5355q_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 2", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-21207/F0510574-F649-48C5-B535-0A477E342BFB/iPhone17,3_27.0_24A5370h_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 3", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-35950/D135F5B5-C2BE-4630-8AE9-C78A6F0E8381/iPhone17,3_27.0_24A5380h_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 4", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-57108/5E816D0E-89BB-4B95-8825-6A3EDF22E509/iPhone17,3_27.0_24A5390f_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 5", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-86338/57B34BF9-3BF5-4B47-BCCA-81B282175957/iPhone17,3_27.0_24A5408d_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 6", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/ad5b3026-b03e-4b21-8bcb-96d6ea527e09/iPhone17,3_27.0_24A5418b_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 7", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/ad5a4f9d-f005-466b-bbcf-3b466040074b/iPhone17,3_27.0_24A5424a_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 8", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/2d03d580-843b-4b2a-b09d-976b31c10744/iPhone17,3_27.0_24A5430a_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27.0 RC", iosURL: "https://updates.cdn-apple.com/2026FallFCS/2d0cd01d-b4f9-4a20-a1e8-f3be54570da7/iPhone17,3_27.0_24A435_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27.0", iosURL: "https://updates.cdn-apple.com/2026FallFCS/5130b3f9-3b4e-469a-b60e-93f6b310cdd9/iPhone17,3_27.0_24A437_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27.0.1", iosURL: "https://updates.cdn-apple.com/2026FallFCS/38dca0ee-bb5d-4132-ad13-62d57bcd6d32/iPhone17,3_27.0.1_24A446_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
    ]

    /// iPadOS releases, one entry per iPad IPSW, oldest first. Each IPSW also
    /// covers the cellular twins, which run as their Wi-Fi model
    /// (`VPhoneGuestDevice.aliases`), so `devices` lists only the models a guest
    /// can be. The URLs are AppleDB's; betas and release candidates are left out.
    static let iPadReleases: [(devices: [String], releases: [(version: String, url: String)])] = [
        // iPad mini (A17 Pro)
        (devices: ["iPad16,1"], releases: [
            ("26.0", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-40200/9E916D65-39EF-49BF-9246-0F1190E93B10/iPad16,1,iPad16,2_26.0_23A341_Restore.ipsw"),
            ("26.0.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-44520/43068DEC-6704-4E42-9F06-DB0391F44D69/iPad16,1,iPad16,2_26.0.1_23A355_Restore.ipsw"),
            ("26.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-12753/0AC11D64-550A-4C49-A257-7EC00EE9551A/iPad16,1,iPad16,2_26.1_23B85_Restore.ipsw"),
            ("26.2", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-81716/33E631AB-9ADD-48EC-BA4B-344BA1740DB1/iPad16,1,iPad16,2_26.2_23C55_Restore.ipsw"),
            ("26.2.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/047-34203/F9F7CE68-7EAD-4FD7-A8AC-25FC05F9E57E/iPad16,1,iPad16,2_26.2.1_23C71_Restore.ipsw"),
            ("26.3", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-60060/B1928C4A-73EA-4118-B32C-8F5CB8DB5C37/iPad16,1,iPad16,2_26.3_23D127_Restore.ipsw"),
            ("26.3.1", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-90322/BF9DA0EC-EA61-4F64-9726-386B5A9F5F6D/iPad16,1,iPad16,2_26.3.1_23D8133_Restore.ipsw"),
            ("26.4", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-04123/1E3F7841-247B-4FB9-A6E5-555E7B37E905/iPad16,1,iPad16,2_26.4_23E246_Restore.ipsw"),
            ("26.4.1", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-28463/D1829F98-B5E6-4CFF-BA6D-3944FB6F0169/iPad16,1,iPad16,2_26.4.1_23E254_Restore.ipsw"),
            ("26.4.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-60229/671D5227-99FC-4400-8B87-759B124F3A25/iPad16,1,iPad16,2_26.4.2_23E261_Restore.ipsw"),
            ("26.5", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-72606/1CDD78CE-0B50-471B-83B4-B1873BF12350/iPad16,1,iPad16,2_26.5_23F77_Restore.ipsw"),
            ("26.5.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-26558/40877F89-3762-40A6-B87A-DCAE2D2A4640/iPad16,1,iPad16,2_26.5.2_23F84_Restore.ipsw"),
            ("26.6", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-57473/555F9A51-FB16-4FDA-B60E-1AE599CB0E38/iPad16,1,iPad16,2_26.6_23G71_Restore.ipsw"),
            ("26.6.1", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-93812/387AE60F-41A6-4EBD-A1BC-E3AF66434C9C/iPad16,1,iPad16,2_26.6.1_23G83_Restore.ipsw"),
            ("26.6.2", "https://updates.cdn-apple.com/2026SummerFCS/cf7db64d-5866-4bf2-bfff-50a32f58bec3/iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw"),
            ("27.0", "https://updates.cdn-apple.com/2026FallFCS/e81c639f-1417-45aa-8a75-6f262083fe37/iPad16,1,iPad16,2_27.0_24A437_Restore.ipsw"),
            ("27.0.1", "https://updates.cdn-apple.com/2026FallFCS/46399de6-53d0-47ec-baea-c203630bcee9/iPad16,1,iPad16,2_27.0.1_24A446_Restore.ipsw"),
        ]),
        // iPad (A16)
        (devices: ["iPad15,7"], releases: [
            ("26.0", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-40869/5E29D9F8-D82C-41AB-B999-30DB3E3AB67E/iPad15,7_26.0_23A341_Restore.ipsw"),
            ("26.0.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-44823/3805B746-50BB-4226-AA51-A41218E4DC8B/iPad15,7_26.0.1_23A355_Restore.ipsw"),
            ("26.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13278/C93C2D8A-8BB5-4754-8BE8-BD894B8BD280/iPad15,7_26.1_23B85_Restore.ipsw"),
            ("26.2", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-80977/82AABD09-DC93-460F-A1C6-D358527CB62D/iPad15,7_26.2_23C55_Restore.ipsw"),
            ("26.2.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/047-34190/1727242B-9A24-44CA-AF0A-20F2CC10DC78/iPad15,7_26.2.1_23C71_Restore.ipsw"),
            ("26.3", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-59864/C987B5A8-9A87-498B-9739-CCCA36759BF2/iPad15,7_26.3_23D127_Restore.ipsw"),
            ("26.3.1", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-90330/70651A4E-5FDE-42E6-A757-11D0B10967D6/iPad15,7_26.3.1_23D8133_Restore.ipsw"),
            ("26.4", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-01462/F6D80D95-3B54-47F0-8E8E-6DAA861A3615/iPad15,7_26.4_23E246_Restore.ipsw"),
            ("26.4.1", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-28497/8533F29A-DB67-4CF3-A37F-D5C0AA8117BF/iPad15,7_26.4.1_23E254_Restore.ipsw"),
            ("26.4.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-60819/F9C65878-32AC-438B-BA6E-ABD08D386E7E/iPad15,7_26.4.2_23E261_Restore.ipsw"),
            ("26.5", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-36065/9064647F-C48C-4213-B5E6-7AA5E3377A7C/iPad15,7_26.5_23F77_Restore.ipsw"),
            ("26.5.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-26993/CFCC3254-9102-428F-94FA-FC61C2CE0706/iPad15,7_26.5.2_23F84_Restore.ipsw"),
            ("26.6", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-58697/CB8C4B63-F794-4EED-AD2F-15297E14B69E/iPad15,7_26.6_23G71_Restore.ipsw"),
            ("26.6.1", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-73569/4627D405-B284-43D6-AA1E-FF775D807C89/iPad15,7_26.6.1_23G83_Restore.ipsw"),
            ("26.6.2", "https://updates.cdn-apple.com/2026SummerFCS/ac34b338-5954-4440-acd7-eb623372b116/iPad15,7_26.6.2_23G90_Restore.ipsw"),
            ("27.0", "https://updates.cdn-apple.com/2026FallFCS/cbdb3e7c-6078-4116-81f5-9ca857711975/iPad15,7_27.0_24A437_Restore.ipsw"),
            ("27.0.1", "https://updates.cdn-apple.com/2026FallFCS/224ac70a-6dd1-4fd4-8d3a-45f3c4026600/iPad15,7_27.0.1_24A446_Restore.ipsw"),
        ]),
        // iPad Air (M3), 11- and 13-inch
        (devices: ["iPad15,3", "iPad15,5"], releases: [
            ("26.0", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-41910/8ED9149B-5FAA-46CA-BFF1-4F1AC5B70E05/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.0_23A341_Restore.ipsw"),
            ("26.0.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-44466/6E2168C0-561F-40A5-84C0-1E71B0EED75D/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.0.1_23A355_Restore.ipsw"),
            ("26.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-12827/9A6C58AA-2A00-4773-8A69-3CB0D7C21AF6/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.1_23B85_Restore.ipsw"),
            ("26.2", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-79199/1F1CC2FD-45B0-4A5C-A69C-16DB618D0ADF/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.2_23C55_Restore.ipsw"),
            ("26.2.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/047-34196/5C6B83F9-16A3-40E7-961F-6AE05572177E/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.2.1_23C71_Restore.ipsw"),
            ("26.3", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-61590/387157F3-CEBD-4FF1-8E06-4E4F3EF185C1/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.3_23D127_Restore.ipsw"),
            ("26.3.1", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-89616/C5FDAFB4-B15A-482B-963E-3E8807692007/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.3.1_23D8133_Restore.ipsw"),
            ("26.4", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-07874/61C4FAFB-925D-4CE4-95C7-04E0DF9E7484/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.4_23E246_Restore.ipsw"),
            ("26.4.1", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-28513/B7952EA1-2E7B-4B5A-9098-08C7FB0B3065/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.4.1_23E254_Restore.ipsw"),
            ("26.4.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-60254/E881A5D5-8452-4196-964E-A8614FF16AA6/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.4.2_23E261_Restore.ipsw"),
            ("26.5", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-70574/10C3FA3A-E70C-4A46-82AE-34C2320F8023/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.5_23F77_Restore.ipsw"),
            ("26.5.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-26796/75B1A13D-F146-4198-A1A0-F71D4E58A07B/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.5.2_23F84_Restore.ipsw"),
            ("26.6", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-57887/5713215E-7923-4102-8D3C-0B03DA847759/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.6_23G71_Restore.ipsw"),
            ("26.6.1", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-93813/53D9BF7A-EC71-4F4B-B97A-ED3F8922CBEF/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.6.1_23G83_Restore.ipsw"),
            ("26.6.2", "https://updates.cdn-apple.com/2026SummerFCS/3ddb0f1f-46ed-48f4-aaad-9837e83144fa/iPad15,3,iPad15,4,iPad15,5,iPad15,6_26.6.2_23G90_Restore.ipsw"),
            ("27.0", "https://updates.cdn-apple.com/2026FallFCS/0b0970ac-f84c-4323-82ab-f153c69c89b7/iPad15,3,iPad15,4,iPad15,5,iPad15,6_27.0_24A437_Restore.ipsw"),
            ("27.0.1", "https://updates.cdn-apple.com/2026FallFCS/7cabbf62-92ba-48e9-afaa-d8ec39313fa8/iPad15,3,iPad15,4,iPad15,5,iPad15,6_27.0.1_24A446_Restore.ipsw"),
        ]),
        // iPad Pro (M4), 11- and 13-inch
        (devices: ["iPad16,3", "iPad16,5"], releases: [
            ("26.0", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-40671/F76C0CC9-322F-4F2B-B2D9-5DA6F0F7C160/iPad_Pro_M4_26.0_23A341_Restore.ipsw"),
            ("26.0.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-45848/6007892D-DB8F-4F7F-BC2A-DFE468C1FB89/iPad_Pro_M4_26.0.1_23A355_Restore.ipsw"),
            ("26.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-12294/8B8B66E4-24AC-4D54-BBD3-F9D35832E74D/iPad_Pro_M4_26.1_23B85_Restore.ipsw"),
            ("26.2", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-81719/ECE32135-FCBE-4096-92DE-E12D6C3F4160/iPad_Pro_M4_26.2_23C55_Restore.ipsw"),
            ("26.2.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/047-21543/5EB13756-48DB-4A4E-A3F0-C36A1172C6D8/iPad_Pro_M4_26.2.1_23C71_Restore.ipsw"),
            ("26.3", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-61663/76E85FB6-6A25-4844-A3DD-FB15EA9D1466/iPad_Pro_M4_26.3_23D127_Restore.ipsw"),
            ("26.3.1", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-91004/34DCB1DE-C509-4AB2-96FC-A8FA83246209/iPad_Pro_M4_26.3.1_23D8133_Restore.ipsw"),
            ("26.4", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-02774/55F8FBBE-EAD4-4FE9-B62F-3D75E28B8D3B/iPad_Pro_M4_26.4_23E246_Restore.ipsw"),
            ("26.4.1", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-28530/6E00E32B-0B47-4F71-80CE-5380561EFE27/iPad_Pro_M4_26.4.1_23E254_Restore.ipsw"),
            ("26.4.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-60853/499BEF59-2EC1-4E2D-AC10-B0122FF4B5DD/iPad_Pro_M4_26.4.2_23E261_Restore.ipsw"),
            ("26.5", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-64200/E70453A1-F1E6-405E-A39A-267AED87CCC2/iPad_Pro_M4_26.5_23F77_Restore.ipsw"),
            ("26.5.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25404/3C9A5919-8296-4275-A2B7-E5D0C2162572/iPad_Pro_M4_26.5.2_23F84_Restore.ipsw"),
            ("26.6", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-57655/D1CB1E3E-79BC-4304-8545-C667E82DF2AF/iPad_Pro_M4_26.6_23G71_Restore.ipsw"),
            ("26.6.1", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-74906/D199C9EE-0CA2-4BAC-B39D-EAAE6F711136/iPad_Pro_M4_26.6.1_23G83_Restore.ipsw"),
            ("26.6.2", "https://updates.cdn-apple.com/2026SummerFCS/9f44484a-c9ac-4a85-8240-435894b1464f/iPad_Pro_M4_26.6.2_23G90_Restore.ipsw"),
            ("27.0", "https://updates.cdn-apple.com/2026FallFCS/459900f0-887c-4dee-a819-3395e7bf67b5/iPad_Pro_M4_27.0_24A437_Restore.ipsw"),
            ("27.0.1", "https://updates.cdn-apple.com/2026FallFCS/7532c1a2-9d94-419d-ad88-bd0e3a0e2bbc/iPad_Pro_M4_27.0.1_24A446_Restore.ipsw"),
        ]),
        // iPad Pro (M5), 11- and 13-inch
        (devices: ["iPad17,1", "iPad17,3"], releases: [
            ("26.0.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-88260/57436729-3132-41A2-89D1-52AB75C7FD2C/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.0.1_23A8466_Restore.ipsw"),
            ("26.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13189/7F17B1CD-05CE-421A-AFEC-AD7F5ED4CF95/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.1_23B85_Restore.ipsw"),
            ("26.2", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-79327/60AAF9BE-FCDB-4478-B5CF-A65E1177346F/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.2_23C55_Restore.ipsw"),
            ("26.2.1", "https://updates.cdn-apple.com/2025FallFCS/fullrestores/047-34213/B71D7BDD-767E-4597-80E7-CBA54CA737E1/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.2.1_23C71_Restore.ipsw"),
            ("26.3", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-61625/38C75A42-C0A5-49AB-8DB1-0D31618617E2/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.3_23D127_Restore.ipsw"),
            ("26.3.1", "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-90311/A91F8DEB-EF60-4571-8A16-81154C15F6F5/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.3.1_23D8133_Restore.ipsw"),
            ("26.4", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-09212/2E89B1A1-1462-45AD-AB0F-301FCBC56358/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.4_23E246_Restore.ipsw"),
            ("26.4.1", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-28528/40A1B358-2D66-4974-9441-0ED88BCC5628/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.4.1_23E254_Restore.ipsw"),
            ("26.4.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-60809/BEBBE1E0-1A14-436B-8541-6F082F04DEB7/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.4.2_23E261_Restore.ipsw"),
            ("26.5", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-39566/3DBC2822-E9B6-4D5B-9A74-A3B5E84315DF/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.5_23F77_Restore.ipsw"),
            ("26.5.2", "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25976/000BB0A6-045B-47FF-AE4E-D8BF722E24FD/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.5.2_23F84_Restore.ipsw"),
            ("26.6", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-57200/196D099E-2EA7-46E3-8BDA-A06BFBBB01C4/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.6_23G71_Restore.ipsw"),
            ("26.6.1", "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-74867/2D974F07-513F-4C4A-8B2D-816B22D03A24/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.6.1_23G83_Restore.ipsw"),
            ("26.6.2", "https://updates.cdn-apple.com/2026SummerFCS/c92fa0b5-4f21-4e74-8980-2926c7320a78/iPad17,1,iPad17,2,iPad17,3,iPad17,4_26.6.2_23G90_Restore.ipsw"),
            ("27.0", "https://updates.cdn-apple.com/2026FallFCS/3d6d90ea-e942-4a86-834f-939769d6e3f4/iPad17,1,iPad17,2,iPad17,3,iPad17,4_27.0_24A437_Restore.ipsw"),
            ("27.0.1", "https://updates.cdn-apple.com/2026FallFCS/6074e110-d48d-40c2-b0e8-b611520941a3/iPad17,1,iPad17,2,iPad17,3,iPad17,4_27.0.1_24A446_Restore.ipsw"),
        ]),
    ]

    /// The pairings for one guest device, oldest first: the iPhone list, or
    /// the iPad's releases with the cloudOS an iPhone of that release uses.
    /// A cellular iPad gets its Wi-Fi model's; an unknown device gets none.
    public static func pairings(for device: String) -> [VPhoneFirmwarePairing] {
        guard let guest = VPhoneGuestDevice.named(device) else { return [] }
        guard guest.isPad else { return pairings }
        let releases = iPadReleases.first { $0.devices.contains(guest.productType) }?.releases ?? []
        return releases.map { release in
            let cloudOS = recommendedCloudOS(forVersion: release.version)
            return VPhoneFirmwarePairing(
                device: guest.productType,
                iosName: "iPadOS \(release.version)",
                iosURL: release.url,
                cloudosName: cloudOS.name,
                cloudosURL: cloudOS.url,
            )
        }
    }

    /// The cloudOS the iPhone pairings give a release of this version.
    static func recommendedCloudOS(forVersion version: String) -> VPhoneCloudOSOption {
        switch version.split(separator: ".").prefix(2).joined(separator: ".") {
        case "26.0", "26.1": VPhoneCloudOSOption(name: "cloudOS 26.1", url: cloud261)
        case "26.2": VPhoneCloudOSOption(name: "cloudOS 26.2", url: cloud262)
        case "26.3": VPhoneCloudOSOption(name: "cloudOS 26.3", url: cloud263)
        default: VPhoneCloudOSOption(name: "cloudOS 26.4", url: cloud264)
        }
    }

    /// Distinct cloudOS images (first-seen order) for the "choose the cloudOS" prompt.
    public static var cloudOSOptions: [VPhoneCloudOSOption] {
        var seen = Set<String>()
        var out: [VPhoneCloudOSOption] = []
        for p in pairings where seen.insert(p.cloudosName).inserted {
            out.append(VPhoneCloudOSOption(name: p.cloudosName, url: p.cloudosURL))
        }
        return out
    }

    /// JSON-friendly projection of the catalog: each build with its recommended
    /// cloudOS, for the iPhone and then per guest device.
    public static var report: VPhoneFirmwareCatalogReport {
        func entries(_ pairings: [VPhoneFirmwarePairing]) -> [VPhoneFirmwareCatalogReport.Entry] {
            pairings.map {
                .init(
                    ios: .init(name: $0.iosName, url: $0.iosURL),
                    recommendedCloudOS: .init(name: $0.cloudosName, url: $0.cloudosURL),
                )
            }
        }
        return VPhoneFirmwareCatalogReport(
            device: device,
            pairings: entries(pairings),
            devices: VPhoneGuestDevice.known.compactMap { guest in
                let pairings = pairings(for: guest.productType)
                guard !pairings.isEmpty else { return nil }
                return .init(
                    productType: guest.productType,
                    name: guest.productName,
                    family: guest.family.rawValue,
                    pairings: entries(pairings),
                )
            },
        )
    }
}

// MARK: - VPhoneFirmwareCatalogReport

/// Codable view of the firmware catalog for `fw catalog --json`.
///
/// `device` and `pairings` are the iPhone17,3 list that Launchpad releases
/// before iPad guests read; `devices` repeats it and adds every iPad.
public struct VPhoneFirmwareCatalogReport: Codable, Equatable, Sendable {
    public struct Firmware: Codable, Equatable, Sendable {
        public let name: String
        public let url: String
        public init(name: String, url: String) {
            self.name = name; self.url = url
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let ios: Firmware
        public let recommendedCloudOS: Firmware
        public init(ios: Firmware, recommendedCloudOS: Firmware) {
            self.ios = ios
            self.recommendedCloudOS = recommendedCloudOS
        }
    }

    /// One guest device and its pairings, oldest first.
    public struct Device: Codable, Equatable, Sendable {
        /// The product type `fw prepare --device` takes.
        public let productType: String
        /// The marketing name, such as `iPad mini (A17 Pro)`.
        public let name: String
        /// `iPhone` or `iPad`.
        public let family: String
        public let pairings: [Entry]
        public init(productType: String, name: String, family: String, pairings: [Entry]) {
            self.productType = productType
            self.name = name
            self.family = family
            self.pairings = pairings
        }
    }

    public let device: String
    public let pairings: [Entry]
    public let devices: [Device]

    public init(device: String, pairings: [Entry], devices: [Device]) {
        self.device = device
        self.pairings = pairings
        self.devices = devices
    }
}
