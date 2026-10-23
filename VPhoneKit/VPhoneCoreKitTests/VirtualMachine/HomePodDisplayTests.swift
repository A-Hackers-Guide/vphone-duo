import Foundation
import Testing
@testable import VPhoneCoreKit

struct HomePodDisplayTests {
    @Test func `Siri and always on banks illuminate the same emitters`() throws {
        let frame = try VPhoneHomePodDisplayFrame(banks: [[[0.4, 0.1, 0]], [[0.3, 0.2, 1]]], plusBrightness: 0.25, minusBrightness: 0.75)
        #expect(frame.pixels == [[0.7, 0.1 + 0.2, 1]])
        #expect(frame.brightness == 1)
        #expect(frame.plusBrightness == 0.25 && frame.minusBrightness == 0.75)
        #expect(throws: VPhoneHomePodDisplayGeometry.ValidationError.self) {
            try VPhoneHomePodDisplayFrame(banks: [[[0, 0, 0]], [[0, 0, 0], [0, 0, 0]]])
        }
        #expect(throws: VPhoneHomePodDisplayGeometry.ValidationError.self) {
            try VPhoneHomePodDisplayFrame(banks: [[[.nan, 0, 0]]])
        }
    }

    private func data(_ words: [UInt32]) -> Data {
        Data(words.flatMap { word in (0 ..< 4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
    }

    @Test func `B520 hardware layout keeps nineteen LEDs and the unlit rim`() throws {
        let x: [UInt32] = [19752, 32768, 45783, 55312, 58799, 55312, 45784, 32768, 19753, 10224, 6737, 10224, 23240, 36256, 45784, 42296, 29280, 19752, 32768]
        let y: [UInt32] = [55312, 58799, 55312, 45784, 32768, 19753, 10224, 6737, 10224, 19752, 32768, 45783, 42296, 45784, 36256, 23240, 19752, 29280, 32768]
        let rings = Array(repeating: UInt32(2), count: 12) + Array(repeating: UInt32(1), count: 6) + [0]
        let geometry = try VPhoneHomePodDisplayGeometry(deviceTreeProperties: [
            "MDXCoords": data(x), "MDYCoords": data(y), "MDRingCoords": data(rings),
            "MDBitDepth": data([12]), "MDHWVersion": data([3]),
        ])
        #expect(geometry.points.count == 19)
        #expect(geometry.normalizedPoints[18].x == 0.5 && geometry.normalizedPoints[18].y == 0.5)
        #expect(geometry.normalizedPoints[10].x == Double(6737) / 65536)
        #expect(geometry.normalizedPoints[4].x < 0.9)
        #expect(geometry.points.filter { $0.ring == 2 }.count == 12)
        #expect(geometry.points.filter { $0.ring == 1 }.count == 6)
    }

    @Test func `device tree coordinate payloads preserve LED order and ring membership`() throws {
        let geometry = try VPhoneHomePodDisplayGeometry(deviceTreeProperties: [
            "MDXCoords": data([0, 32768, 65536]), "MDYCoords": data([65536, 0, 65536]),
            "MDRingCoords": data([2, 0, 2]), "MDBitDepth": data([12]), "MDHWVersion": data([3]),
        ])
        #expect(geometry.bitDepth == 12 && geometry.hardwareVersion == 3)
        #expect(geometry.points.map(\.x) == [0, 0.5, 1])
        #expect(geometry.points.map(\.ring) == [2, 0, 2])
        #expect(geometry.normalizedPoints.map(\.x) == [0, 0.5, 1])
        #expect(geometry.normalizedPoints.map(\.y) == [1, 0, 1])
    }

    @Test func `truncated and mismatched device tree properties are rejected`() {
        var properties = [
            "MDXCoords": data([0, 65536]), "MDYCoords": data([0, 65536]),
            "MDRingCoords": data([0, 1]), "MDBitDepth": data([12]), "MDHWVersion": data([3]),
        ]
        properties["MDXCoords"] = Data([0, 1, 2])
        #expect(throws: VPhoneHomePodDisplayGeometry.ValidationError.self) {
            try VPhoneHomePodDisplayGeometry(deviceTreeProperties: properties)
        }
        properties["MDXCoords"] = data([0])
        #expect(throws: VPhoneHomePodDisplayGeometry.ValidationError.self) {
            try VPhoneHomePodDisplayGeometry(deviceTreeProperties: properties)
        }
    }

    @Test func `a central LED retains its hardware position`() throws {
        let geometry = try VPhoneHomePodDisplayGeometry(xCoordinates: [0.5], yCoordinates: [0.5], rings: [0], bitDepth: 12, hardwareVersion: 3)
        #expect(geometry.normalizedPoints[0].x == 0.5)
        #expect(geometry.normalizedPoints[0].y == 0.5)
    }

    @Test func `nonfinite coordinates and unsupported bit depths are rejected`() {
        #expect(throws: VPhoneHomePodDisplayGeometry.ValidationError.self) {
            try VPhoneHomePodDisplayGeometry(xCoordinates: [.nan], yCoordinates: [0], rings: [0], bitDepth: 12, hardwareVersion: 3)
        }
        #expect(throws: VPhoneHomePodDisplayGeometry.ValidationError.self) {
            try VPhoneHomePodDisplayGeometry(xCoordinates: [0], yCoordinates: [0], rings: [0], bitDepth: 0, hardwareVersion: 3)
        }
    }

    @Test func `malformed frames cannot reach the renderer`() {
        for pixels in [[], [[0, 1]], [[0, 1, 0, 1]], [[-0.1, 0, 0]], [[0, 1.1, 0]], [[0, .nan, 0]], [[.infinity, 0, 0]]] as [[[Double]]] {
            #expect(throws: VPhoneHomePodDisplayGeometry.ValidationError.self) { try VPhoneHomePodDisplayFrame(pixels: pixels) }
        }
        #expect(throws: VPhoneHomePodDisplayGeometry.ValidationError.self) { try VPhoneHomePodDisplayFrame(pixels: [[1, 0, 0]], brightness: .nan) }
        #expect(throws: VPhoneHomePodDisplayGeometry.ValidationError.self) { try VPhoneHomePodDisplayFrame(pixels: [[1, 0, 0]], minusBrightness: -1) }
    }

    @Test func `frames are admitted only for matching device geometry`() throws {
        let geometry = try VPhoneHomePodDisplayGeometry(xCoordinates: [0, 1], yCoordinates: [0, 1], rings: [0, 1], bitDepth: 12, hardwareVersion: 3)
        #expect(try VPhoneHomePodDisplayFrame(pixels: [[1, 0, 0]]).matches(geometry) == false)
        let frame = try VPhoneHomePodDisplayFrame(pixels: [[1, 0, 0], [0, 0.5, 1]], brightness: 0.75, plusBrightness: 0.25, generation: UInt64.max)
        #expect(frame.matches(geometry))
        #expect(frame.generation == UInt64.max)
    }
}
