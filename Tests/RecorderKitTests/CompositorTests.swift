import XCTest
import Metal
import RecorderKit

final class CompositorTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var compositor: Compositor!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        compositor = Compositor(commandQueue: queue)
    }

    // MARK: Helpers

    typealias Pixel = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

    /// A texture of one colour, with an orange top left quarter if `marked`. `flipped` stores the bottom row first.
    private func texture(_ width: Int, _ height: Int, _ colour: Pixel, marked: Bool = false, flipped: Bool = false) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        let texture = device.makeTexture(descriptor: descriptor)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = flipped ? height - 1 - y : y
            for x in 0..<width {
                let orange = marked && x < width / 2 && y < height / 2
                let pixel: Pixel = orange ? (0, 128, 255, 255) : colour
                let offset = (row * width + x) * 4
                pixels[offset] = pixel.b; pixels[offset + 1] = pixel.g; pixels[offset + 2] = pixel.r; pixels[offset + 3] = pixel.a
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }

    /// Reads a texture back. The copy is made on the compositor's queue, which runs its buffers in order: what
    /// the compositor drew is there by then.
    private func pixels(_ texture: MTLTexture) -> (Int, Int) -> Pixel {
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

    private func layout(_ kind: LayoutKind, _ sizes: [NSSize], gap: Int = 0) -> Layout {
        Layout(kind: kind, sourceSizes: sizes.map { NSValue(size: $0) }, gap: gap, fitting: .zero)
    }

    private func compose(_ layout: Layout, _ textures: [Any], flipped: [Bool]? = nil, transparent: Bool = false) throws -> MTLTexture {
        try XCTUnwrap(compositor.compose(layout, textures: textures, flipped: (flipped ?? textures.map { _ in false }).map { NSNumber(value: $0) },
                                         transparent: transparent))
    }

    private func assertEqual(_ pixel: Pixel, _ expected: Pixel, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let close = abs(Int(pixel.b) - Int(expected.b)) <= 2 && abs(Int(pixel.g) - Int(expected.g)) <= 2
            && abs(Int(pixel.r) - Int(expected.r)) <= 2 && abs(Int(pixel.a) - Int(expected.a)) <= 2
        XCTAssertTrue(close, "\(message) got \(pixel), expected \(expected)", file: file, line: line)
    }

    private let red: Pixel = (0, 0, 255, 255), green: Pixel = (0, 255, 0, 255), blue: Pixel = (255, 0, 0, 255), black: Pixel = (0, 0, 0, 255)
    private let orange: Pixel = (0, 128, 255, 255), grey: Pixel = (128, 128, 128, 255)
    private let small = NSSize(width: 64, height: 48)

    // MARK: Tests

    func testEachSourceIsInItsPlace() throws {
        let row = layout(.row, [small, small, small])
        let picture = try compose(row, [texture(64, 48, red), texture(64, 48, green), texture(64, 48, blue)])
        XCTAssertEqual(picture.width, 192)
        XCTAssertEqual(picture.height, 48)
        let pixel = pixels(picture)
        assertEqual(pixel(32, 24), red)
        assertEqual(pixel(96, 24), green)
        assertEqual(pixel(160, 24), blue)
        assertEqual(pixel(63, 0), red, "the right edge of the first")
        assertEqual(pixel(64, 47), green, "the left edge of the second")
    }

    func testGapsAreBlack() throws {
        let row = layout(.row, [small, small], gap: 10)
        let pixel = pixels(try compose(row, [texture(64, 48, red), texture(64, 48, green)]))
        assertEqual(pixel(69, 24), black)
        assertEqual(pixel(63, 24), red)
        assertEqual(pixel(74, 24), green)
    }

    func testASourceIsScaledToItsPlace() throws {
        // The second is half the size of the first: in a row it is drawn twice as large
        let row = layout(.row, [small, NSSize(width: 32, height: 24)])
        let pixel = pixels(try compose(row, [texture(64, 48, red), texture(32, 24, grey, marked: true)]))
        assertEqual(pixel(64 + 4, 4), orange)
        assertEqual(pixel(64 + 28, 20), orange)
        assertEqual(pixel(64 + 36, 4), grey)
        assertEqual(pixel(64 + 4, 28), grey)
    }

    func testAFlippedSourceIsUpright() throws {
        let one = layout(.row, [small])
        let pixel = pixels(try compose(one, [texture(64, 48, grey, marked: true, flipped: true)], flipped: [true]))
        assertEqual(pixel(4, 4), orange, "the top left of the picture")
        assertEqual(pixel(4, 44), grey)
        assertEqual(pixel(60, 4), grey)
    }

    func testASourceWhichIsNotFlippedStaysAsItIs() throws {
        let one = layout(.row, [small])
        let pixel = pixels(try compose(one, [texture(64, 48, grey, marked: true)]))
        assertEqual(pixel(4, 4), orange)
        assertEqual(pixel(4, 44), grey)
    }

    func testASourceWithNoPictureLeavesItsPlaceBlack() throws {
        let row = layout(.row, [small, small, small])
        let pixel = pixels(try compose(row, [texture(64, 48, red), NSNull(), texture(64, 48, blue)]))
        assertEqual(pixel(32, 24), red)
        assertEqual(pixel(96, 24), black)
        assertEqual(pixel(160, 24), blue)
    }

    func testTransparencyIsKept() throws {
        let row = layout(.row, [small, small], gap: 10)
        let glass: Pixel = (0, 0, 100, 100)
        let transparent = pixels(try compose(row, [texture(64, 48, red), texture(64, 48, glass)], transparent: true))
        assertEqual(transparent(69, 24), (0, 0, 0, 0), "between the sources")
        assertEqual(transparent(32, 24), red)
        assertEqual(transparent(100, 24), glass, "a source's own transparency, not blended onto black")

        let opaque = pixels(try compose(row, [texture(64, 48, red), texture(64, 48, glass)]))
        XCTAssertEqual(opaque(69, 24).a, 255)
        XCTAssertEqual(opaque(100, 24).a, 255, "a movie without transparency has none")
        XCTAssertEqual(opaque(100, 24).r, 100)
    }

    func testACompositeIsNotOverwrittenByTheNextOnes() throws {
        // A composite can wait to be encoded while the next ones are made
        let one = layout(.row, [small])
        let first = try compose(one, [texture(64, 48, red)])
        var others: [MTLTexture] = []
        for _ in 0..<3 { others.append(try compose(one, [texture(64, 48, blue)])) }
        assertEqual(pixels(first)(32, 24), red)
        XCTAssertEqual(Set(([first] + others).map { ObjectIdentifier($0) }).count, 4)
    }

    func testTheTargetFollowsTheLayoutsSize() throws {
        let one = try compose(layout(.row, [small]), [texture(64, 48, red)])
        let two = try compose(layout(.column, [small, small]), [texture(64, 48, red), texture(64, 48, green)])
        XCTAssertEqual([one.width, one.height], [64, 48])
        XCTAssertEqual([two.width, two.height], [64, 96])
        assertEqual(pixels(two)(32, 72), green)
    }

    func testTexturesWhichDoNotMatchTheLayoutAreRefused() {
        let row = layout(.row, [small, small])
        XCTAssertNil(compositor.compose(row, textures: [texture(64, 48, red)], flipped: [false], transparent: false))
    }

    func testASourceWhichIsNotTheShapeOfItsPlaceIsFittedInIt() throws {
        // The places are made for two sources of 64 × 48; the first is now square (its window was resized)
        let row = layout(.row, [small, small])
        let pixel = pixels(try compose(row, [texture(48, 48, red), texture(64, 48, green)]))
        assertEqual(pixel(32, 24), red, "centred in its place")
        assertEqual(pixel(9, 24), red, "its left edge")
        assertEqual(pixel(54, 24), red, "its right edge")
        assertEqual(pixel(3, 24), black, "the bar on its left")
        assertEqual(pixel(60, 24), black, "the bar on its right")
        assertEqual(pixel(70, 24), green, "the second is where it was")
        // Wider than its place: bars above and below
        let wide = pixels(try compose(row, [texture(128, 48, red), texture(64, 48, green)]))
        assertEqual(wide(32, 24), red)
        assertEqual(wide(32, 5), black)
        assertEqual(wide(32, 42), black)
        assertEqual(wide(2, 24), red)
    }

    func testAPictureLargerThanATextureCanBeIsNotComposed() {
        let huge = layout(.row, [NSSize(width: 20000, height: 48)])
        XCTAssertNil(compositor.compose(huge, textures: [NSNull()], flipped: [false], transparent: false))
    }

    func testTheHandlerIsCalledOnceThePictureIsDrawn() throws {
        let row = layout(.row, [small, small])
        let drawn = expectation(description: "drawn")
        let picture = try XCTUnwrap(compositor.compose(row, textures: [texture(64, 48, red), texture(64, 48, green)], flipped: [false, false],
                                                       transparent: false) { _ in drawn.fulfill() })
        wait(for: [drawn], timeout: 5)
        // Read with a queue of its own, as a recorder does: the picture is there
        let other = try XCTUnwrap(device.makeCommandQueue())
        let buffer = device.makeBuffer(length: picture.width * 4 * picture.height, options: .storageModeShared)!
        let commands = other.makeCommandBuffer()!
        let blit = commands.makeBlitCommandEncoder()!
        blit.copy(from: picture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: picture.width, height: picture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: picture.width * 4, destinationBytesPerImage: picture.width * 4 * picture.height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(bytes[(24 * picture.width + 32) * 4 + 2], 255, "red in the first place")
        XCTAssertEqual(bytes[(24 * picture.width + 96) * 4 + 1], 255, "green in the second")

        // No picture, no call
        let huge = layout(.row, [NSSize(width: 20000, height: 48)])
        XCTAssertNil(compositor.compose(huge, textures: [NSNull()], flipped: [false], transparent: false) { _ in XCTFail("called without a picture") })
    }
}
