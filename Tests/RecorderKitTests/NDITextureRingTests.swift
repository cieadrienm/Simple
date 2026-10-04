import XCTest
import Metal
import RecorderKit

final class NDITextureRingTests: XCTestCase {
    private var device: MTLDevice!
    private var ring: NDITextureRing!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        ring = NDITextureRing(device: device)
    }

    // MARK: Helpers

    typealias Pixel = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

    /// A picture as NDI gives it: BGRA, the top row first, rows of `bytesPerRow` bytes whose padding is white.
    /// `colour` gives each pixel's colour.
    private func picture(_ width: Int, _ height: Int, bytesPerRow: Int? = nil, _ colour: (Int, Int) -> Pixel) -> [UInt8] {
        let rowBytes = bytesPerRow ?? width * 4
        var bytes = [UInt8](repeating: 255, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = colour(x, y)
                let offset = y * rowBytes + x * 4
                bytes[offset] = pixel.b; bytes[offset + 1] = pixel.g; bytes[offset + 2] = pixel.r; bytes[offset + 3] = pixel.a
            }
        }
        return bytes
    }

    private func texture(_ bytes: [UInt8], _ width: Int, _ height: Int, bytesPerRow: Int? = nil, hasAlpha: Bool = true) -> MTLTexture? {
        bytes.withUnsafeBytes { buffer in
            ring.texture(withBytes: buffer.baseAddress!, width: UInt(width), height: UInt(height),
                         bytesPerRow: UInt(bytesPerRow ?? width * 4), hasAlpha: hasAlpha)
        }
    }

    private func texture(_ width: Int, _ height: Int, _ colour: Pixel) throws -> MTLTexture {
        try XCTUnwrap(texture(picture(width, height) { _, _ in colour }, width, height))
    }

    /// Reads a texture of the ring back. They are written with `replaceRegion`, by the CPU: no GPU work to wait for.
    private func pixels(_ texture: MTLTexture) -> (Int, Int) -> Pixel {
        let rowBytes = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * texture.height)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return { x, y in
            let offset = y * rowBytes + x * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
    }

    /// Reads a texture drawn by the GPU back, with the queue which drew it: its buffers run in order.
    private func pixels(_ texture: MTLTexture, drawnWith queue: MTLCommandQueue) -> (Int, Int) -> Pixel {
        let rowBytes = texture.width * 4
        let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared)!
        let commands = queue.makeCommandBuffer()!
        let blit = commands.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return { x, y in
            let offset = y * rowBytes + x * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
    }

    /// The texture drawn by a compositor which keeps transparency, alone in a layout of its size
    private func composedTransparent(_ texture: MTLTexture) throws -> (Int, Int) -> Pixel {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let compositor = try XCTUnwrap(Compositor(commandQueue: queue))
        let size = NSSize(width: texture.width, height: texture.height)
        let layout = Layout(kind: .row, sourceSizes: [NSValue(size: size)], gap: 0, fitting: .zero)
        let picture = try XCTUnwrap(compositor.compose(layout, textures: [texture], flipped: [NSNumber(value: false)], transparent: true))
        return pixels(picture, drawnWith: queue)
    }

    private func assertEqual(_ pixel: Pixel, _ expected: Pixel, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let close = abs(Int(pixel.b) - Int(expected.b)) <= 2 && abs(Int(pixel.g) - Int(expected.g)) <= 2
            && abs(Int(pixel.r) - Int(expected.r)) <= 2 && abs(Int(pixel.a) - Int(expected.a)) <= 2
        XCTAssertTrue(close, "\(message) got \(pixel), expected \(expected)", file: file, line: line)
    }

    private let red: Pixel = (0, 0, 255, 255), green: Pixel = (0, 255, 0, 255), blue: Pixel = (255, 0, 0, 255)
    private let yellow: Pixel = (0, 255, 255, 255), white: Pixel = (255, 255, 255, 255)

    /// Four quarters of four colours: red top left, green top right, blue bottom left, yellow bottom right
    private func quarters(_ width: Int, _ height: Int) -> (Int, Int) -> Pixel {
        { [red, green, blue, yellow] x, y in
            y < height / 2 ? (x < width / 2 ? red : green) : (x < width / 2 ? blue : yellow)
        }
    }

    // MARK: Tests

    func testThePictureIsCopiedAsItIs() throws {
        let texture = try XCTUnwrap(texture(picture(64, 48, quarters(64, 48)), 64, 48))
        XCTAssertEqual(texture.width, 64)
        XCTAssertEqual(texture.height, 48)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        let read = pixels(texture)
        assertEqual(read(0, 0), red, "the first row is the top")
        assertEqual(read(63, 0), green)
        assertEqual(read(0, 47), blue)
        assertEqual(read(63, 47), yellow)
    }

    func testRowsLongerThanThePictureAreCopiedRight() throws {
        let rowBytes = 64 * 4 + 64
        let bytes = picture(64, 48, bytesPerRow: rowBytes, quarters(64, 48))
        let read = pixels(try XCTUnwrap(texture(bytes, 64, 48, bytesPerRow: rowBytes)))
        for y in 0..<48 {
            for x in 0..<64 {
                let pixel = read(x, y)
                XCTAssertFalse(pixel == white, "no padding at \(x), \(y)")
            }
        }
        assertEqual(read(0, 47), blue, "the last row")
        assertEqual(read(63, 47), yellow, "the last row")
        assertEqual(read(63, 0), green)
    }

    func testAPictureWithoutAlphaIsOpaque() throws {
        // NDI's BGRX: the fourth byte is anything
        let bytes = picture(64, 48) { x, _ in x < 32 ? (0, 0, 255, 0) : (255, 0, 0, 37) }
        let texture = try XCTUnwrap(texture(bytes, 64, 48, hasAlpha: false))
        let composed = try composedTransparent(texture)
        assertEqual(composed(10, 24), red, "a fourth byte of 0")
        assertEqual(composed(50, 24), blue, "a fourth byte of 37")
    }

    func testAPictureWithAlphaKeepsIt() throws {
        let bytes = picture(64, 48) { _, _ in (0, 0, 100, 37) }
        let texture = try XCTUnwrap(texture(bytes, 64, 48, hasAlpha: true))
        XCTAssertEqual(pixels(texture)(10, 24).a, 37)
        XCTAssertEqual(try composedTransparent(texture)(10, 24).a, 37, "the same compositor keeps it")
    }

    func testATextureIsNotWrittenOverByTheFramesWhichFollow() throws {
        // What the header promises: not written to again by the eleven calls which follow
        let slots = 12
        let first = try texture(64, 48, red)
        // Every call but the first's turn to come round again
        for index in 1..<slots {
            let other = try texture(64, 48, index % 2 == 0 ? green : blue)
            XCTAssertFalse(other === first, "call \(index + 1) gave the first texture back")
        }
        assertEqual(pixels(first)(32, 24), red, "after the \(slots - 1) calls which follow")
        let again = try texture(64, 48, yellow)
        XCTAssertTrue(again === first, "the ring comes round after \(slots) calls")
    }

    func testASizeChangeMakesNewTextures() throws {
        let first = try texture(640, 360, red)
        let second = try texture(320, 180, green)
        XCTAssertEqual(second.width, 320)
        XCTAssertEqual(second.height, 180)
        XCTAssertEqual(first.width, 640)
        XCTAssertEqual(first.height, 360)
        assertEqual(pixels(first)(600, 300), red, "the first is unchanged")
        // All the ring's textures are of the new size now, the one the first was in too
        for _ in 0..<12 {
            XCTAssertEqual(try texture(320, 180, blue).width, 320)
        }
        assertEqual(pixels(first)(600, 300), red, "the first, still held, is not reused")
    }

    func testSizesWhichCannotBeAreRefused() throws {
        let bytes = [UInt8](repeating: 0, count: 20000 * 4)
        XCTAssertNil(texture(bytes, 0, 2))
        XCTAssertNil(texture(bytes, 64, 0))
        XCTAssertNil(texture(bytes, 20000, 1), "wider than a texture can be")
        XCTAssertNil(texture(bytes, 1, 20000), "taller than a texture can be")
        XCTAssertNil(texture(bytes, 64, 2, bytesPerRow: 64 * 4 - 1), "rows shorter than the picture")
        XCTAssertNotNil(texture(bytes, 64, 2), "the same bytes, read right")
    }
}
