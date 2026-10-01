import Testing
@testable import VPhoneCoreKit

/// The keys the virtual USB keyboard drops, and what the guest gets instead.
@Suite("Guest key map")
struct GuestKeyMapTests {
    @Test
    func `fn becomes the Apple keyboard 🌐 usage`() {
        #expect(VPhoneGuestKeyMap.functionKeyCode == 0x3F)
        #expect(VPhoneGuestKeyMap.globe == .init(page: 0xFF, usage: 0x03))
    }

    @Test
    func `the JIS input-mode keys become LANG1 and LANG2`() {
        #expect(VPhoneGuestKeyMap.usage(forDroppedKeyCode: 0x68) == .init(page: 0x07, usage: 0x90))
        #expect(VPhoneGuestKeyMap.usage(forDroppedKeyCode: 0x66) == .init(page: 0x07, usage: 0x91))
    }

    @Test
    func `keys the virtual keyboard carries are left to it`() {
        // A, Space, Escape, Caps Lock, Left Control, F1, Up Arrow, kVK_Function.
        for keyCode: UInt16 in [0x00, 0x31, 0x35, 0x39, 0x3B, 0x7A, 0x7E, 0x3F] {
            #expect(VPhoneGuestKeyMap.usage(forDroppedKeyCode: keyCode) == nil)
        }
    }

    @Test
    func `every forwarded usage is on a page the guest accepts from vphoned`() {
        for usage in VPhoneGuestKeyMap.droppedKeys.values {
            #expect([0x07, 0x0C].contains(usage.page))
        }
    }
}
