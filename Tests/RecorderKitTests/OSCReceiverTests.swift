import XCTest
import RecorderKit

final class OSCReceiverTests: XCTestCase {
    private func send(_ message: OSCMessage, toPort port: Int) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let packet = message.packet()
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sent, packet.count)
    }

    func testReceivesMessageSentToItsPort() {
        let receiver = OSCReceiver()
        let received = expectation(description: "message")
        var message: OSCMessage?
        XCTAssertTrue(receiver.start(onPort: 19270) {
            XCTAssertTrue(Thread.isMainThread)
            message = $0
            received.fulfill()
        })
        defer { receiver.stop() }
        XCTAssertEqual(receiver.port, 19270)

        send(OSCMessage(address: "/fps", arguments: [NSNumber(value: Float(25))]), toPort: 19270)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(message?.address, "/fps")
        XCTAssertEqual(message?.arguments as? [Float], [25])
    }

    func testPacketsWhichAreNotOSCAreIgnoredAndLaterOnesHandled() {
        let receiver = OSCReceiver()
        let received = expectation(description: "message")
        var addresses: [String] = []
        XCTAssertTrue(receiver.start(onPort: 19240) {
            addresses.append($0.address)
            if $0.address == "/after" { received.fulfill() }
        })
        defer { receiver.stop() }

        send(OSCMessage(address: "not osc", arguments: []), toPort: 19240)
        send(OSCMessage(address: "/after", arguments: []), toPort: 19240)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(addresses, ["/after"])
    }

    func testSecondReceiverTakesNextPort() {
        let first = OSCReceiver()
        let second = OSCReceiver()
        XCTAssertTrue(first.start(onPort: 19250) { _ in })
        XCTAssertTrue(second.start(onPort: 19250) { _ in })
        defer { first.stop(); second.stop() }
        XCTAssertEqual(first.port, 19250)
        XCTAssertEqual(second.port, 19251)
    }

    func testStopFreesThePort() {
        let receiver = OSCReceiver()
        XCTAssertTrue(receiver.start(onPort: 19260) { _ in })
        receiver.stop()
        XCTAssertEqual(receiver.port, 0)
        XCTAssertTrue(receiver.start(onPort: 19260) { _ in })
        XCTAssertEqual(receiver.port, 19260)
        receiver.stop()
    }
}
