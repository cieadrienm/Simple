import XCTest
import RecorderKit

final class OSCMessageTests: XCTestCase {
    /// An OSC string: the bytes, a null, then nulls up to a multiple of four.
    private func oscString(_ string: String) -> [UInt8] {
        var bytes = Array(string.utf8) + [0]
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    private func messages(_ parts: [UInt8]...) -> [OSCMessage] {
        OSCMessage.messages(fromPacket: Data(join(parts)))
    }

    private func join(_ parts: [[UInt8]]) -> [UInt8] { parts.flatMap { $0 } }
    private func join(_ parts: [UInt8]...) -> [UInt8] { join(parts) }

    private func size(_ bytes: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Array($0) }
    }

    private let bundleHeader: [UInt8] = Array("#bundle".utf8) + [0] + [UInt8](repeating: 0, count: 8)

    func testRoundTripIntFloatString() {
        let packet = OSCMessage(address: "/a/b", arguments: [NSNumber(value: Int32(-7)), NSNumber(value: Float(0.25)), "héllo"]).packet()
        let decoded = OSCMessage.messages(fromPacket: packet)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.address, "/a/b")
        XCTAssertEqual(decoded.first?.arguments as? [AnyHashable], [-7, 0.25, "héllo"] as [AnyHashable])
    }

    func testEncodesIntegersAsIntAndOtherNumbersAsFloat() {
        let packet = OSCMessage(address: "/x", arguments: [NSNumber(value: 3), NSNumber(value: 1.5)]).packet()
        XCTAssertEqual([UInt8](packet), join(oscString("/x"), oscString(",if"), [0, 0, 0, 3], [0x3F, 0xC0, 0, 0]))
    }

    func testDecodesKnownBytes() {
        let decoded = messages(oscString("/record"), oscString(",i"), [0, 0, 0, 1])
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.address, "/record")
        XCTAssertEqual(decoded.first?.arguments as? [Int], [1])
    }

    func testTrueFalseAndDouble() {
        let pi: [UInt8] = [0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18]
        let decoded = messages(oscString("/t"), oscString(",TFd"), pi)
        XCTAssertEqual(decoded.first?.arguments.count, 3)
        XCTAssertEqual(decoded.first?.arguments[0] as? Bool, true)
        XCTAssertEqual(decoded.first?.arguments[1] as? Bool, false)
        XCTAssertEqual(decoded.first?.arguments[2] as? Double ?? 0, Double.pi, accuracy: 1e-12)
    }

    func testLongInteger() {
        let decoded = messages(oscString("/h"), oscString(",h"), [0, 0, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(decoded.first?.arguments as? [Int64], [1 << 32])
    }

    func testNoTypeTagString() {
        let decoded = messages(oscString("/record/toggle"))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.address, "/record/toggle")
        XCTAssertEqual(decoded.first?.arguments.count, 0)
    }

    func testBundleIsFlattened() {
        let first = join(oscString("/a"), oscString(",i"), [0, 0, 0, 1])
        let second = join(oscString("/b"), oscString(",s"), oscString("x"))
        let inner = join(bundleHeader, size(second), second)
        let bundle = join(bundleHeader, size(first), first, size(inner), inner)
        XCTAssertEqual(messages(bundle).map(\.address), ["/a", "/b"])
    }

    func testUnknownTypesAreSkipped() {
        // A blob of three bytes (padded to four) between an int and a float
        let blob: [UInt8] = [0, 0, 0, 3, 9, 9, 9, 0]
        let decoded = messages(oscString("/u"), oscString(",ibf"), [0, 0, 0, 5], blob, [0x3F, 0x00, 0, 0])
        XCTAssertEqual(decoded.first?.arguments as? [AnyHashable], [5, 0.5] as [AnyHashable])
    }

    func testMalformedPacketsAreIgnored() {
        XCTAssertEqual(messages([]).count, 0)
        XCTAssertEqual(messages(oscString("record"), oscString(",i"), [0, 0, 0, 1]).count, 0, "an address starts with /")
        XCTAssertEqual(messages(Array("/unterminated".utf8)).count, 0)
        XCTAssertEqual(messages(oscString("/record"), oscString(",i"), [0, 0]).count, 0, "truncated int")
        XCTAssertEqual(messages(oscString("/s"), oscString(",s"), Array("abc".utf8)).count, 0, "unterminated string argument")
        XCTAssertEqual(messages(oscString("/b"), oscString(",b"), [0x7F, 0xFF, 0xFF, 0xFF]).count, 0, "blob longer than the packet")
        XCTAssertEqual(messages(oscString("/b"), oscString(",b"), [0xFF, 0xFF, 0xFF, 0xFF]).count, 0, "blob size which overflows")
        XCTAssertEqual(messages(oscString("/q"), oscString(",?")).count, 0, "unknown type")
        XCTAssertEqual(messages(oscString("#bundle"), [0, 0, 0]).count, 0, "truncated time tag")
        let element = join(oscString("/a"), oscString(",i"), [0, 0, 0, 1])
        XCTAssertEqual(messages(bundleHeader, [0, 0, 1, 0], element).count, 0, "element size past the end")
    }

    func testDeeplyNestedBundlesAreIgnored() {
        var nested = join(oscString("/a"), oscString(",i"), [0, 0, 0, 1])
        for _ in 0..<5000 {
            nested = join(bundleHeader, size(nested), nested)
        }
        XCTAssertEqual(messages(nested).count, 0)
    }
}
