import Foundation
import Metal
import RecorderKit

/// A source which delivers the frames the test gives it.
final class FakeSource: NSObject, FrameSource {
    let title: String
    var flipped = false
    var kind = FrameSourceKind.syphon
    var frameHandler: ((MTLTexture) -> Void)?
    private(set) var stopped = false
    /// Which of the directory's entries it is connected to
    var entry = 0
    weak var directory: FakeDirectory?

    init(title: String) { self.title = title }
    /// How many times it was asked whether it is alive
    private(set) var aliveChecks = 0
    var isAlive: Bool {
        aliveChecks += 1
        return !(directory?.dead.contains(entry) ?? false)
    }
    func stop() { stopped = true }
    func deliver(_ texture: MTLTexture) { frameHandler?(texture) }
    var soundHandler: ((SourceSound) -> Void)?
    /// YES once the test has delivered sound
    private(set) var hasSound = false
    func deliverSound(_ sound: SourceSound) {
        hasSound = true
        soundHandler?(sound)
    }
}

/// The sources which exist, as the test says. As in Syphon's directory, a source whose application was killed
/// stays listed: only connecting to it tells that it has gone.
final class FakeDirectory: NSObject, SourceDirectory {
    var changeHandler: (() -> Void)?
    private(set) var titles: [String]
    /// The entries (indexes into `titles`) which are listed but dead
    private(set) var dead = Set<Int>()
    /// Every source ever connected to, the latest last
    private(set) var connections: [FakeSource] = []

    /// The titles which are NDI sources: the others are Syphon's
    let ndiTitles: Set<String>

    init(_ titles: [String], ndi: Set<String> = []) {
        self.titles = titles
        ndiTitles = ndi
    }

    func availableSources() -> [SourceDescription] {
        titles.map {
            ndiTitles.contains($0)
                ? SourceDescription(title: $0, detail: "NDI", kind: .NDI)
                : SourceDescription(title: $0, detail: $0.hasSuffix("eMotion") ? "eMotion" : "Simple Server", kind: .syphon)
        }
    }

    func connectToSource(withTitle title: String, device: MTLDevice) -> FrameSource? {
        // The first with the title which is alive
        guard let entry = titles.indices.first(where: { titles[$0] == title && !dead.contains($0) }) else { return nil }
        let source = FakeSource(title: title)
        source.entry = entry
        source.directory = self
        source.kind = ndiTitles.contains(title) ? .NDI : .syphon
        connections.append(source)
        return source
    }

    /// The live connection to a source, if there is one.
    func source(_ title: String) -> FakeSource? {
        connections.last { $0.title == title && !$0.stopped }
    }

    func setTitles(_ titles: [String]) {
        self.titles = titles
        dead = []
        changeHandler?()
    }

    /// The application of an entry is killed: nothing is announced, and the entry stays.
    func kill(entry: Int) { dead.insert(entry) }

    /// An application is launched: its source is announced.
    func launch(_ title: String) {
        titles.append(title)
        changeHandler?()
    }
}

/// The Mac's sound, as the test gives it.
final class FakeComputerSound: NSObject, SoundSource {
    var soundHandler: ((SourceSound) -> Void)?
    private(set) var running = false
    func start() -> Bool { running = true; return true }
    func stop() { running = false }
}

/// A controller over fake sources, with its own defaults and a folder of its own.
struct TestRecorder {
    let device: MTLDevice
    let directory: FakeDirectory
    let computerSound: FakeComputerSound
    let controller: RecorderController
    let folder: URL
    private let defaultsName: String

    static let titles = ["main view - eMotion", "depthMap - eMotion", "A - Simple Server", "B - Simple Server"]

    init(ndi: [String] = []) throws {
        device = MTLCreateSystemDefaultDevice()!
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaultsName = "SimpleRecorderTests-\(UUID().uuidString)"
        directory = FakeDirectory(Self.titles + ndi, ndi: Set(ndi))
        computerSound = FakeComputerSound()
        controller = RecorderController(device: device, directory: directory, computerSound: computerSound, defaults: UserDefaults(suiteName: defaultsName)!)
        controller.folder = folder.path
    }

    func cleanUp() {
        controller.stopNetwork()
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: folder)
    }

    func texture(_ width: Int = 320, _ height: Int = 180, grey: UInt8 = 128) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        let texture = device.makeTexture(descriptor: descriptor)!
        let pixels = [UInt8](repeating: grey, count: width * height * 4)
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }
}
