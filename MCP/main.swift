// simple-recorder-mcp — Model Context Protocol server (stdio) for Simple Recorder.
//
// It reads the recorder through OSCQuery (HTTP) and writes to it with OSC (UDP), so it uses the very surface any
// OSC controller does: there is no other API.
import Foundation

let applicationName = "Simple Recorder"
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

    /// The most sources which can be recorded at once: /source/1 … /source/8
    static let maximumPlaces = 8

    /// The recorder as the tools report it.
    func status() throws -> [String: Any] {
        let (values, sources) = try read()
        // One title per line: the NDI sources which are available. Any other title in the list is a Syphon server
        let ndiTitles = Set((values["/status/ndi/sources"] as? String ?? "").split(separator: "\n").map(String.init))
        func value(_ path: String) -> Any { values[path] ?? NSNull() }
        var places: [[String: Any]] = []
        for place in 1...Self.maximumPlaces {
            guard let title = values["/source/\(place)"] as? String, !title.isEmpty else { continue }
            let status = "/status/source/\(place)/"
            places.append(["place": place, "title": title, "kind": value(status + "kind"), "online": (value(status + "online") as? NSNumber)?.boolValue ?? false,
                           "width": value(status + "width"), "height": value(status + "height"), "fps": value(status + "fps"),
                           "file": value(status + "file"), "frames": value(status + "frames"), "dropped": value(status + "dropped"),
                           "sound": (value(status + "sound") as? NSNumber)?.boolValue ?? false, "soundWritten": value(status + "soundwritten")])
        }
        return [
            "sources": places,
            "ndi": (values["/status/ndi"] as? NSNumber)?.boolValue ?? false,
            "sourcesAvailable": sources.map { ["title": $0, "kind": ndiTitles.contains($0) ? "ndi" : "syphon"] },
            "settings": ["codec": value("/codec"), "fps": value("/fps"), "bitrate": value("/bitrate"), "folder": value("/folder"), "name": value("/name"),
                         "output": value("/output"), "layout": value("/layout"), "gap": value("/gap"), "width": value("/width"), "height": value("/height"),
                         "sound": value("/sound"), "performance": (values["/performance"] as? NSNumber)?.boolValue ?? false],
            // The assembled picture as it is now, and the assembled movie of the take being recorded or of the last one
            "assembled": ["width": value("/status/assembled/width"), "height": value("/status/assembled/height"), "file": value("/status/assembled/file"),
                          "frames": value("/status/assembled/frames"), "dropped": value("/status/assembled/dropped"),
                          "soundWritten": value("/status/sound/written")],
            // Seconds of sound left out, in all the movies, because an encoder could not keep up
            "soundLeftOut": value("/status/sound/leftout"),
            "state": value("/status/state"),
            "elapsed": value("/status/elapsed"),
            "dropped": value("/status/dropped"),
            "error": value("/status/error"),
            "failure": value("/status/failure"),
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
        func bool(_ key: String) throws -> Bool? {
            guard let value = arguments[key] else { return nil }
            // JSON's true and false: a number is not taken for one
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw RecorderError.badArguments("\(key) must be true or false") }
            return number.boolValue
        }
        // sources replaces the sources chosen, in order; source is the first one alone
        var titles: [String]?
        if let list = arguments["sources"] {
            guard let list = list as? [String] else { throw RecorderError.badArguments("sources must be a list of titles") }
            guard list.count <= Self.maximumPlaces else { throw RecorderError.badArguments("no more than \(Self.maximumPlaces) sources can be recorded at once") }
            titles = list
        } else if let source = try string("source") {
            titles = [source]
        }
        if let titles {
            // Checked before anything is changed: a title which matches nothing must not leave the places empty
            let available = try read().sources
            for title in titles where !available.contains(where: { $0.range(of: title, options: .caseInsensitive) != nil }) {
                throw RecorderError.failed("There is no source called \u{201C}\(title)\u{201D}. Available: \(available.joined(separator: ", ")). Nothing was changed.")
            }
            // Emptying the first place moves the others up: eight times empties them all
            for _ in 1...Self.maximumPlaces { send("/source/1", [.string("")]) }
            for (index, title) in titles.enumerated() {
                let address = "/source/\(index + 1)"
                wanted.append((address, .string(title), { ($0 as? String)?.range(of: title, options: .caseInsensitive) != nil }))
            }
            if titles.count < Self.maximumPlaces {
                wanted.append(("/source/\(titles.count + 1)", .string(""), { ($0 as? String) == "" }))
            }
        }
        if let codec = try string("codec") {
            wanted.append(("/codec", .string(codec), { ($0 as? String) == codec.lowercased() }))
        }
        for key in ["fps", "bitrate"] {
            if let value = try number(key) {
                wanted.append(("/" + key, .float(Float(value)), { abs((($0 as? NSNumber)?.doubleValue ?? -1) - value) < 0.001 }))
            }
        }
        for key in ["output", "layout"] {
            if let value = try string(key) {
                wanted.append(("/" + key, .string(value), { ($0 as? String) == value.lowercased() }))
            }
        }
        for key in ["gap", "width", "height"] {
            if let value = try number(key) {
                wanted.append(("/" + key, .int(Int32(max(min(value, 1_000_000), -1_000_000))), { (($0 as? NSNumber)?.doubleValue ?? -1) == value.rounded() }))
            }
        }
        // After the sources: it is matched against the places chosen. The recorder keeps the full title; "" is none
        if let sound = try string("sound") {
            wanted.append(("/sound", .string(sound), { value in
                let stored = value as? String
                return sound.isEmpty ? stored == "" : stored?.range(of: sound, options: .caseInsensitive) != nil
            }))
        }
        // It applies at once, during a take too
        if let performance = try bool("performance") {
            wanted.append(("/performance", .int(performance ? 1 : 0), { ($0 as? NSNumber)?.intValue == (performance ? 1 : 0) }))
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
        send("/record", [.int(0)])
        let finished = try wait(upTo: 30) { try currentState().state == "idle" }
        let result = try status()
        if !finished { throw RecorderError.failed("The movie is still being finished.\n" + json(result)) }
        // failure, not error: a message refused during the recording leaves its error, and is not why it stopped
        if let failure = result["failure"] as? String, !failure.isEmpty {
            throw RecorderError.failed("The recording stopped with an error: \(failure)\n" + json(result))
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
    "sources": ["type": "array", "items": ["type": "string"], "description": "The sources to record, in order: their titles, or part of them (see sourcesAvailable in recorder_status); they may be Syphon servers or NDI sources. Up to 8. Replaces those chosen."],
    "source": ["type": "string", "description": "One source (a Syphon server or an NDI source) to record, alone: the same as sources with one title"],
    "codec": ["type": "string", "enum": ["h264", "hevc", "prores422", "prores4444"], "description": "The same for every movie. prores4444 keeps transparency"],
    "fps": ["type": "number", "description": "The most frames per second in the movie. 0: every frame of the source."],
    "bitrate": ["type": "number", "description": "Megabits per second, for h264 and hevc. 0: chosen from the size and frame rate."],
    "folder": ["type": "string", "description": "Folder the movies are written to. It must exist."],
    "name": ["type": "string", "description": "Name of the recording, without extension: the assembled movie's. Empty: the app's name and the date. A source's own movie adds its source's title, unless it is the only movie. An existing file is never overwritten: a number is added."],
    "output": ["type": "string", "enum": ["separate", "assembled", "both"], "description": "What a recording writes. separate: one movie for each source, at its own size. assembled: one movie of all the sources in one picture. both: all of them."],
    "layout": ["type": "string", "enum": ["row", "column", "grid", "focus"], "description": "How the sources are assembled, in their order. row: side by side. column: stacked. grid: a mosaic. focus: the first large, the others in a column on its right."],
    "sound": ["type": "string", "description": "The source whose sound the assembled movie takes: its title, or part of it, among the sources chosen; empty for none (the default). Only NDI sources which send sound have any (see sources[].sound in recorder_status); a source's own movie always has its own sound. Sound is 48 kHz stereo (the source's first two channels), AAC with h264 and hevc, linear PCM with prores422 and prores4444. Give it after the sources, or together with them."],
    "gap": ["type": "integer", "description": "Pixels between the sources in the assembled picture (black, or transparent with prores4444)"],
    "performance": ["type": "boolean", "description": "Performance mode: while a recording is in progress, the picture in the app's window is shown ten times a second instead of at every frame, to leave the GPU to the movies' encoders. The movies are not affected. Off by default. Unlike the other settings it applies at once, also during a recording (through recorder_configure)."],
    "width": ["type": "integer", "description": "Width the assembled picture is fitted into. 0 (or a height of 0): the size the sources need (see assembled in recorder_status)."],
    "height": ["type": "integer", "description": "Height the assembled picture is fitted into. 0 (or a width of 0): the size the sources need."],
]

let tools: [[String: Any]] = [
    ["name": "recorder_status",
     "description": "The state of Simple Recorder: the sources chosen for recording, in order, with each one's kind (syphon or ndi) and what it delivers (online, size, frame rate) and its movie "
        + "(file, frames written and dropped, sound: true if the source is sending sound, which only NDI sources do, and soundWritten: seconds of sound in its movie); the sources which can be chosen (sourcesAvailable: a list of {title, kind}, kind being syphon or ndi; it was a list of titles before NDI sources came); whether NDI is usable (ndi: false when NDI's library is not installed, which only leaves NDI sources out); the settings, among them what a recording writes "
        + "(output: separate | assembled | both), which source's sound the assembled movie takes (sound), how the sources are assembled (layout, gap, width, height) and whether the window's picture is held back while recording (performance); the assembled picture's size now and "
        + "the assembled movie (assembled: width, height, file, frames, dropped, soundWritten: seconds of sound in it); the seconds of sound left out in all the movies because an encoder could not keep up (soundLeftOut; pictures are never delayed for sound); whether it is recording "
        + "(state: idle | recording | finishing) and for how long; the last error (error: a refused message, a recording which could not start), "
        + "and why the last recording ended if it failed (failure).",
     "inputSchema": schema([:])],
    ["name": "recorder_configure",
     "description": "Changes the sources chosen and the settings; only what is given changes. Settings are saved by the app and apply to the next recording. "
        + "The sources cannot be changed while recording. With output separate each source is recorded to its own movie, at its own size; with assembled "
        + "the sources are recorded together in one movie, placed by layout in their order; with both, all of these. All the movies share one clock. "
        + "A source which sends sound (an NDI source: its sound is true in recorder_status) is recorded with it in its own movie, and the assembled movie takes "
        + "the sound of the source named by sound, none by default; the sound is 48 kHz stereo, AAC with h264 and hevc, linear PCM with ProRes. A source which sends none gives a movie without a sound track. "
        + "Returns the status afterwards.",
     "inputSchema": schema(settingsProperties)],
    ["name": "recorder_start",
     "description": "Starts recording the sources chosen: one movie (.mov) each, one assembled movie, or both, as output says. "
        + "Sources and settings (sound included) can be given as for recorder_configure. Returns once the recording has started, with the path of each source's movie "
        + "in sources[].file and of the assembled movie in assembled.file; fails with the reason if it could not start "
        + "(no source chosen, folder missing, an assembled picture too large…).",
     "inputSchema": schema(settingsProperties)],
    ["name": "recorder_stop",
     "description": "Stops the recording and waits for the movies to be finished. Returns the status: each movie's path, frames written and dropped "
        + "in sources[] and in assembled, the duration in elapsed. A source which delivered no frame has no movie.",
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
                  "instructions": "Controls the Simple Recorder app, which records several Syphon and NDI sources at once: each to its own movie file, all assembled in one movie "
                    + "(side by side, stacked, mosaic), or both. "
                    + "Call recorder_status first to see the sources and settings; recorder_configure chooses the sources; recorder_start and recorder_stop record."]
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
