import XCTest
import RecorderKit

final class OSCQueryServerTests: XCTestCase {
    private let server = OSCQueryServer.shared()

    override func tearDown() {
        server.stop()
        server.clearRegisteredAddresses()
    }

    /// GETs a path from the server. The main run loop keeps turning meanwhile, as value providers run on the main thread.
    private func get(_ path: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let answered = expectation(description: path)
        var object: [String: Any] = [:]
        let url = URL(string: "http://127.0.0.1:\(server.httpPort)\(path)")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            XCTAssertNil(error, file: file, line: line)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, file: file, line: line)
            object = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            answered.fulfill()
        }.resume()
        wait(for: [answered], timeout: 5)
        return object
    }

    private func contents(_ node: Any?, _ name: String) -> [String: Any]? {
        ((node as? [String: Any])?["CONTENTS"] as? [String: Any])?[name] as? [String: Any]
    }

    func testServesNamespaceHostInfoAndValues() throws {
        server.serverName = "Recorder Test"
        server.oscPort = 19999
        server.registerOSCAddress("/codec", typeSpec: "s", description: "Codec", access: .readWrite,
                                  range: [["VALS": ["h264", "hevc"]]], valueProvider: { ["hevc"] })
        server.registerOSCAddress("/status/frames", typeSpec: "i", description: "Frames written", access: .readOnly,
                                  range: nil, valueProvider: { [12] })
        server.registerOSCAddress("/record/toggle", typeSpec: nil, description: "Start or stop")
        XCTAssertTrue(server.start(onPort: 19331))
        XCTAssertGreaterThanOrEqual(server.httpPort, 19331)

        let info = get("/?HOST_INFO")
        XCTAssertEqual(info["NAME"] as? String, "Recorder Test")
        XCTAssertEqual(info["OSC_PORT"] as? Int, 19999)
        XCTAssertEqual(info["OSC_TRANSPORT"] as? String, "UDP")

        let root = get("/")
        let codec = try XCTUnwrap(contents(root, "codec"))
        XCTAssertEqual(codec["FULL_PATH"] as? String, "/codec")
        XCTAssertEqual(codec["TYPE"] as? String, "s")
        XCTAssertEqual(codec["ACCESS"] as? Int, 3)
        XCTAssertEqual(codec["VALUE"] as? [String], ["hevc"])
        XCTAssertEqual((codec["RANGE"] as? [[String: [String]]])?.first?["VALS"], ["h264", "hevc"])

        let frames = try XCTUnwrap(contents(contents(root, "status"), "frames"))
        XCTAssertEqual(frames["ACCESS"] as? Int, 1)
        XCTAssertEqual(frames["VALUE"] as? [Int], [12])

        let toggle = try XCTUnwrap(contents(contents(root, "record"), "toggle"))
        XCTAssertEqual(toggle["ACCESS"] as? Int, 2)

        XCTAssertEqual(get("/codec?VALUE")["VALUE"] as? [String], ["hevc"])
        XCTAssertEqual(get("/status")["FULL_PATH"] as? String, "/status")
    }

    func testRegisteringAgainReplacesRangeAndValue() throws {
        server.registerOSCAddress("/source", typeSpec: "s", description: "Source", access: .readWrite,
                                  range: [["VALS": ["One"]]], valueProvider: { ["One"] })
        XCTAssertTrue(server.start(onPort: 19351))

        server.registerOSCAddress("/source", typeSpec: "s", description: "Source", access: .readWrite,
                                  range: [["VALS": ["One", "Two"]]], valueProvider: { ["Two"] })

        let source = get("/source")
        XCTAssertEqual((source["RANGE"] as? [[String: [String]]])?.first?["VALS"], ["One", "Two"])
        XCTAssertEqual(source["VALUE"] as? [String], ["Two"])
    }
}
