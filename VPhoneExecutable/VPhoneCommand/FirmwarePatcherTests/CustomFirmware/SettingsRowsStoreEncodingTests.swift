import Foundation
import Testing
import VPhonePatchKit

@Suite("Settings rule store encoding")
struct SettingsRowsStoreEncodingTests {
    @Test func encodesZeroPayloadStore() {
        #expect(ARM64Encoder.encodeStrXUnsignedOffset(rt: 31, rn: 23, offset: 0) == Data([0xff, 0x02, 0x00, 0xf9]))
        #expect(ARM64Encoder.encodeStrXUnsignedOffset(rt: 0, rn: 31, offset: 32760) != nil)
    }
    @Test func rejectsInvalidOperands() {
        #expect(ARM64Encoder.encodeStrXUnsignedOffset(rt: 32, rn: 0, offset: 0) == nil)
        #expect(ARM64Encoder.encodeStrXUnsignedOffset(rt: 0, rn: 32, offset: 0) == nil)
        #expect(ARM64Encoder.encodeStrXUnsignedOffset(rt: 0, rn: 0, offset: 4) == nil)
        #expect(ARM64Encoder.encodeStrXUnsignedOffset(rt: 0, rn: 0, offset: 32768) == nil)
    }
}
