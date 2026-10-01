// MARK: - Guest Key Map

/// Mac keys the virtual USB keyboard cannot carry, and the HID usage the guest
/// gets for each instead, by way of vphoned.
///
/// `VZUSBKeyboardConfiguration` is a boot-protocol keyboard: its report holds
/// the eight page-7 modifiers (0xE0–0xE7) and six page-7 keys in 0x00–0x91,
/// nothing else. `_VZKeyboard` first maps each Mac virtual key code to an
/// internal index through a 179-entry table, and drops codes the table has no
/// index for (macOS 27.0.1, Virtualization 259). Measured against that table
/// and the report descriptor, the keys that never reach a guest are:
///
/// - **fn / 🌐** (`kVK_Function`, 0x3F): has an index, but no report field. On
///   an iPad, 🌐 switches the input source and starts the 🌐 shortcuts; Apple's
///   keyboards send it as Apple vendor top-case page 0xFF, usage 0x03, which
///   iPadOS honours from any keyboard service.
/// - the JIS keys 英数 / かな / ¥ / _ / keypad `,`, which switch the Japanese
///   input mode and type their characters;
/// - Context Menu, Help/Insert, and the volume and mute keys.
public enum VPhoneGuestKeyMap {
    public struct Usage: Hashable, Sendable {
        public let page: UInt32
        public let usage: UInt32

        public init(page: UInt32, usage: UInt32) {
            self.page = page
            self.usage = usage
        }
    }

    /// `kVK_Function`, which AppKit reports in a flags-changed event.
    public static let functionKeyCode: UInt16 = 0x3F

    /// The 🌐 key of an Apple keyboard: vendor top-case page, keyboard fn.
    public static let globe = Usage(page: 0xFF, usage: 0x03)

    /// Key-down / key-up codes `_VZKeyboard` drops, with the usage to send.
    public static let droppedKeys: [UInt16: Usage] = [
        0x66: Usage(page: 0x07, usage: 0x91), // JIS 英数 → LANG2
        0x68: Usage(page: 0x07, usage: 0x90), // JIS かな → LANG1
        0x5D: Usage(page: 0x07, usage: 0x89), // JIS ¥ → International3
        0x5E: Usage(page: 0x07, usage: 0x87), // JIS _ → International1
        0x5F: Usage(page: 0x07, usage: 0x85), // JIS keypad , → Keypad Comma
        0x6E: Usage(page: 0x07, usage: 0x65), // Context Menu → Application
        0x72: Usage(page: 0x07, usage: 0x49), // Help / Insert → Insert
        0x48: Usage(page: 0x0C, usage: 0xE9), // Volume Up
        0x49: Usage(page: 0x0C, usage: 0xEA), // Volume Down
        0x4A: Usage(page: 0x0C, usage: 0xE2), // Mute
    ]

    /// The usage a key-down or key-up with `keyCode` needs sent by hand, or nil
    /// for a key the virtual keyboard carries itself.
    public static func usage(forDroppedKeyCode keyCode: UInt16) -> Usage? {
        droppedKeys[keyCode]
    }
}
