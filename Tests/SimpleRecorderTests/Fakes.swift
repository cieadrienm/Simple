import Foundation
import Metal
import RecorderKit

/// A source which delivers the frames the test gives it.
final class FakeSource: NSObject, FrameSource {
    let title: String
    var flipped = false
    var frameHandler: ((MTLTexture) -> Void)?
    private(set) var stopped = false
    /// Which of the sources with its title it is
    var choice = 0

    init(title: String) { self.title = title }
    func stop() { stopped = true }
    func deliver(_ texture: MTLTexture) { frameHandler?(texture) }
}

/// The sources which exist, as the test says.
final class FakeDirectory: NSObject, SourceDirectory {
    var changeHandler: (() -> Void)?
    private(set) var titles: [String]
    private(set) var connections: [FakeSource] = []

    init(_ titles: [String]) { self.titles = titles }

    func availableSources() -> [SourceDescription] {
        titles.map { SourceDescription(title: $0, detail: $0.hasSuffix("eMotion") ? "eMotion" : "Simple Server", kind: .syphon) }
    }

    func connectToSource(withTitle title: String, choice: UInt, device: MTLDevice) -> FrameSource? {
        // Several sources can have the same title: choice says which, going round
        let count = titles.filter { $0 == title }.count
        guard count > 0 else { return nil }
        let source = FakeSource(title: title)
        source.choice = Int(choice) % count
        connections.append(source)
        return source
    }

    func source(_ title: String) -> FakeSource? {
        connections.last { $0.title == title && !$0.stopped }
    }

    func setTitles(_ titles: [String]) {
        self.titles = titles
        changeHandler?()
    }
}

/// A controller over fake sources, with its own defaults and a folder of its own.
struct TestRecorder {
    let device: MTLDevice
    let directory: FakeDirectory
    let controller: RecorderController
    let folder: URL
    private let defaultsName: String

    static let titles = ["main view - eMotion", "depthMap - eMotion", "A - Simple Server", "B - Simple Server"]

    init() throws {
        device = MTLCreateSystemDefaultDevice()!
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaultsName = "SimpleRecorderTests-\(UUID().uuidString)"
        directory = FakeDirectory(Self.titles)
        controller = RecorderController(device: device, directory: directory, defaults: UserDefaults(suiteName: defaultsName)!)
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
