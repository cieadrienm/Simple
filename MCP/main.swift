// simple-recorder-mcp — Model Context Protocol server (stdio) for Simple Client's recorder.
//
// It reads the recorder through OSCQuery (HTTP) and writes to it with OSC (UDP), so it uses the very surface any
// OSC controller does: there is no other API.
import Foundation

let applicationName = "Simple Client"
let preferredPort = Int(ProcessInfo.processInfo.environment["SIMPLE_OSCQUERY_PORT"] ?? "") ?? 9231
/// The app takes the first free port from the one it prefers, so it may be a few ports further
let portsToTry = 16

enum RecorderError: Error, CustomStringConvertible {
    case unreachable
    case badArguments(String)
    case failed(String)

    var description: String {
        switch self {
        case .unreachable:
            return "\(applicationName) is not running, or its OSCQuery server is not on ports \(preferredPort)–\(preferredPort + portsToTry - 1). "
                + "Launch the app and retry (set SIMPLE_OSCQUERY_PORT if it uses another port)."
        case .badArguments(let why): return why
        case .failed(let why): return why
        }
    }
}

// MARK: OSCQuery

func get(port: Int, _ path: String, timeout: TimeInterval = 2) -> Any? {
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
    let done = DispatchSemaphore(value: 0)
    var object: Any?
    URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: timeout)) { data, response, _ in
        if (response as? HTTPURLResponse)?.statusCode == 200, let data {
            object = try? JSONSerialization.jsonObject(with: data)
        }
        done.signal()
    }.resume()
    done.wait()
    return object
}

struct Recorder {
    var queryPort: Int
    var oscPort: Int

    /// The app's OSCQuery server: on the preferred port, or one of those which follow.
    static func find() throws -> Recorder {
        for port in preferredPort..<(preferredPort + portsToTry) {
            // A short timeout: nothing listening answers at once, and the app is on this Mac
            if let info = get(port: port, "/?HOST_INFO", timeout: 0.5) as? [String: Any],
               info["NAME"] as? String == applicationName,
               let oscPort = info["OSC_PORT"] as? Int {
                return Recorder(queryPort: port, oscPort: oscPort)
            }
        }
        throw RecorderError.unreachable
    }

    /// Every parameter's value, by address, and the titles of the sources available.
    func read() throws -> (values: [String: Any], sources: [String]) {
        guard let root = get(port: queryPort, "/") as? [String: Any] else { throw RecorderError.unreachable }
        var values: [String: Any] = [:]
        var sources: [String] = []
        func walk(_ node: [String: Any]) {
            if let path = node["FULL_PATH"] as? String, let value = (node["VALUE"] as? [Any])?.first {
                values[path] = value
                if path == "/source", let range = (node["RANGE"] as? [[String: Any]])?.first {
                    sources = range["VALS"] as? [String] ?? []
                }
            }
            for child in (node["CONTENTS"] as? [String: Any] ?? [:]).values {
                if let child = child as? [String: Any] { walk(child) }
            }
        }
        walk(root)
        return (values, sources)
    }

    /// The recorder as the tools report it.
    func status() throws -> [String: Any] {
        let (values, sources) = try read()
        func value(_ path: String) -> Any { values[path] ?? NSNull() }
        return [
            "source": value("/source"),
            "sourcesAvailable": sources,
            "sourceFrames": ["width": value("/status/source/width"), "height": value("/status/source/height"), "fps": value("/status/source/fps")],
            "settings": ["codec": value("/codec"), "width": value("/width"), "height": value("/height"), "fps": value("/fps"),
                         "bitrate": value("/bitrate"), "folder": value("/folder"), "name": value("/name")],
            "state": value("/status/state"),
            "elapsed": value("/status/elapsed"),
            "frames": value("/status/frames"),
            "dropped": value("/status/dropped"),
            "file": value("/status/file"),
            "error": value("/status/error"),
        ]
    }

    func currentState() throws -> (state: String, error: String) {
        let values = try read().values
        return (values["/status/state"] as? String ?? "", values["/status/error"] as? String ?? "")
    }

    // MARK: OSC

    enum Argument {
        case int(Int32)
        case float(Float)
        case string(String)
    }

    func send(_ address: String, _ arguments: [Argument] = []) {
        func oscString(_ string: String) -> Data {
            var data = Data(string.utf8)
            data.append(contentsOf: [UInt8](repeating: 0, count: 4 - data.count % 4))
            return data
        }
        var tags = ","
        var values = Data()
        for argument in arguments {
            switch argument {
            case .int(let value):
                tags += "i"
                withUnsafeBytes(of: value.bigEndian) { values.append(contentsOf: $0) }
            case .float(let value):
                tags += "f"
                withUnsafeBytes(of: value.bitPattern.bigEndian) { values.append(contentsOf: $0) }
            case .string(let value):
                tags += "s"
                values.append(oscString(value))
            }
        }
        let packet = oscString(address) + oscString(tags) + values

        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(oscPort).bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")
        packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Calls `condition` until it is true or `seconds` have passed. OSC has no answer: this is how we know a
    /// message has had its effect.
    func wait(upTo seconds: TimeInterval, until condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if try condition() { return true }
            if Date() >= deadline { return false }
            usleep(50_000)
        }
    }

    // MARK: Tools

    /// Sends the settings present in `arguments`. Returns those which the recorder did not take as they were given.
    func configure(_ arguments: [String: Any]) throws -> [String: Any] {
        var wanted: [(address: String, argument: Argument, matches: (Any?) -> Bool)] = []
        func number(_ key: String) throws -> Double? {
            guard let value = arguments[key] else { return nil }
            guard let number = value as? NSNumber else { throw RecorderError.badArguments("\(key) must be a number") }
            return number.doubleValue
        }
        func string(_ key: String) throws -> String? {
            guard let value = arguments[key] else { return nil }
            guard let string = value as? String else { throw RecorderError.badArguments("\(key) must be a string") }
            return string
        }
        if let source = try string("source") {
            wanted.append(("/source", .string(source), { ($0 as? String)?.range(of: source, options: .caseInsensitive) != nil }))
        }
        if let codec = try string("codec") {
            wanted.append(("/codec", .string(codec), { ($0 as? String) == codec.lowercased() }))
        }
        for key in ["width", "height"] {
            if let value = try number(key) {
                wanted.append(("/" + key, .int(Int32(clamping: Int(value))), { ($0 as? NSNumber)?.intValue == Int(value) }))
            }
        }
        for key in ["fps", "bitrate"] {
            if let value = try number(key) {
                wanted.append(("/" + key, .float(Float(value)), { abs((($0 as? NSNumber)?.doubleValue ?? -1) - value) < 0.001 }))
            }
        }
        for key in ["folder", "name"] {
            if let value = try string(key) {
                let expected = key == "folder" ? (value as NSString).expandingTildeInPath : value
                wanted.append(("/" + key, .string(value), { ($0 as? String) == expected }))
            }
        }
        guard !wanted.isEmpty else { return [:] }

        for setting in wanted { send(setting.address, [setting.argument]) }

        var values: [String: Any] = [:]
        _ = try wait(upTo: 1) {
            values = try read().values
            return wanted.allSatisfy { $0.matches(values[$0.address]) }
        }
        var notApplied: [String: Any] = [:]
        for setting in wanted where !setting.matches(values[setting.address]) {
            notApplied[String(setting.address.dropFirst())] = values[setting.address] ?? NSNull()
        }
        return notApplied
    }

    func configureTool(_ arguments: [String: Any]) throws -> [String: Any] {
        let notApplied = try configure(arguments)
        var result = try status()
        if !notApplied.isEmpty {
            result["notApplied"] = notApplied
            let error = result["error"] as? String ?? ""
            throw RecorderError.failed("Some settings were not taken as given (the recorder's values are in notApplied)"
                + (error.isEmpty ? "" : ": \(error)") + "\n" + json(result))
        }
        return result
    }

    func start(_ arguments: [String: Any]) throws -> [String: Any] {
        if try currentState().state != "idle" {
            throw RecorderError.failed("A recording is already in progress. Stop it first.\n" + json(try status()))
        }
        let notApplied = try configure(arguments)
        if !notApplied.isEmpty {
            var result = try status()
            result["notApplied"] = notApplied
            throw RecorderError.failed("Not started: some settings were not taken as given.\n" + json(result))
        }

        // /status/error is the last error, whatever caused it: only one which appears now is this start's
        let errorBefore = try currentState().error
        send("/record", [.int(1)])
        var failure: String?
        let started = try wait(upTo: 3) {
            let (state, error) = try currentState()
            if state == "recording" { return true }
            if !error.isEmpty, error != errorBefore {
                failure = error
                return true
            }
            return false
        }
        if let failure { throw RecorderError.failed("The recording did not start: \(failure)") }
        if !started { throw RecorderError.failed("The recording did not start.\n" + json(try status())) }
        return try status()
    }

    func stop() throws -> [String: Any] {
        if try currentState().state == "idle" {
            throw RecorderError.failed("There is no recording in progress.\n" + json(try status()))
        }
        // A message refused during the recording leaves its error: it is not why the recording stopped
        let errorBefore = try currentState().error
        send("/record", [.int(0)])
        let finished = try wait(upTo: 30) { try currentState().state == "idle" }
        let result = try status()
        if !finished { throw RecorderError.failed("The movie is still being finished.\n" + json(result)) }
        if let error = result["error"] as? String, !error.isEmpty, error != errorBefore {
            throw RecorderError.failed("The recording stopped with an error: \(error)\n" + json(result))
        }
        return result
    }
}

func json(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

// MARK: Tools

func schema(_ properties: [String: Any]) -> [String: Any] {
    ["type": "object", "properties": properties, "additionalProperties": false]
}

let settingsProperties: [String: Any] = [
    "source": ["type": "string", "description": "Title of the Syphon source, or part of it (see sourcesAvailable in recorder_status)"],
    "codec": ["type": "string", "enum": ["h264", "hevc", "prores422", "prores4444"], "description": "prores4444 keeps transparency"],
    "width": ["type": "integer", "description": "Pixels. 0 with height 0: the size of the source. Other sizes scale the picture to fit, with bars."],
    "height": ["type": "integer"],
    "fps": ["type": "number", "description": "The most frames per second in the movie. 0: every frame of the source."],
    "bitrate": ["type": "number", "description": "Megabits per second, for h264 and hevc. 0: chosen from the size and frame rate."],
    "folder": ["type": "string", "description": "Folder the movies are written to. It must exist."],
    "name": ["type": "string", "description": "Name of the movie, without extension. Empty: the source's application and the date. An existing file is never overwritten: a number is added."],
]

let tools: [[String: Any]] = [
    ["name": "recorder_status",
     "description": "The state of Simple Client's recorder: the Syphon sources available and the one selected, the size and frame rate of its frames, "
        + "the settings, and whether it is recording (state: idle | recording | finishing), for how long, how many frames were written and dropped, "
        + "the movie being written or last written, and the last error.",
     "inputSchema": schema([:])],
    ["name": "recorder_configure",
     "description": "Changes the recorder's settings; only those given change. They are saved by the app and apply to the next recording, "
        + "not to one in progress — except source, which switches at once what is shown and recorded. Returns the status afterwards.",
     "inputSchema": schema(settingsProperties)],
    ["name": "recorder_start",
     "description": "Starts recording the selected source to a new movie (.mov). Settings can be given as for recorder_configure. "
        + "Returns once the recording has started, with the path of the movie in file; fails with the reason if it could not start "
        + "(no source selected, folder missing…).",
     "inputSchema": schema(settingsProperties)],
    ["name": "recorder_stop",
     "description": "Stops the recording and waits for the movie to be finished. Returns the status, with the movie's path in file, "
        + "its duration in elapsed and the frames written and dropped.",
     "inputSchema": schema([:])],
]

func callTool(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
    let recorder = try Recorder.find()
    let result: [String: Any]
    switch name {
    case "recorder_status": result = try recorder.status()
    case "recorder_configure": result = try recorder.configureTool(arguments)
    case "recorder_start": result = try recorder.start(arguments)
    case "recorder_stop": result = try recorder.stop()
    default: throw RecorderError.badArguments("unknown tool \(name)")
    }
    return ["content": [["type": "text", "text": json(result)]], "isError": false]
}

// MARK: JSON-RPC over stdio

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let method = message["method"] as? String else { continue }
    guard let id = message["id"] else { continue } // notifications need no answer
    let params = message["params"] as? [String: Any] ?? [:]

    var result: [String: Any]?
    switch method {
    case "initialize":
        result = ["protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                  "capabilities": ["tools": [:] as [String: Any]],
                  "serverInfo": ["name": "simple-recorder", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                  "instructions": "Controls the recorder of the Simple Client app, which records a Syphon source to a movie file. "
                    + "Call recorder_status first to see the sources and settings; recorder_start and recorder_stop record."]
    case "ping": result = [:]
    case "tools/list": result = ["tools": tools]
    case "tools/call":
        do {
            result = try callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        } catch {
            result = ["content": [["type": "text", "text": "\(error)"]], "isError": true]
        }
    default: break
    }

    if let result {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    } else {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
    }
}
