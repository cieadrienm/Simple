import XCTest
import RecorderKit

final class LayoutTests: XCTestCase {
    private let hd = NSSize(width: 1920, height: 1080)
    private let depth = NSSize(width: 512, height: 520)

    private func layout(_ kind: LayoutKind, _ sizes: [Any], gap: Int = 0, fitting: NSSize = .zero) -> Layout {
        Layout(kind: kind, sourceSizes: sizes.map { ($0 as? NSSize).map { NSValue(size: $0) } ?? $0 }, gap: gap, fitting: fitting)
    }

    private func frames(_ layout: Layout) -> [NSRect] { layout.frames.map(\.rectValue) }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }

    private let kinds: [LayoutKind] = [.row, .column, .grid, .focus]

    func testOneSourceIsItselfWhateverTheKind() {
        for kind in kinds {
            let one = layout(kind, [depth], gap: 20)
            XCTAssertEqual(one.size, depth)
            XCTAssertEqual(frames(one), [rect(0, 0, 512, 520)])
        }
    }

    func testNoSourceIsAnEmpty1080pPicture() {
        let none = layout(.row, [])
        XCTAssertEqual(none.size, hd)
        XCTAssertEqual(frames(none), [])
    }

    func testRowScalesToTheTallest() {
        let row = layout(.row, [hd, depth])
        // 512 × 520 at 1080 high is 1063.4 wide; the picture's width is rounded up to an even number
        XCTAssertEqual(row.size, NSSize(width: 2984, height: 1080))
        XCTAssertEqual(frames(row), [rect(0, 0, 1920, 1080), rect(1920, 0, 1063, 1080)])
    }

    func testRowWithAGap() {
        let row = layout(.row, [hd, hd, hd], gap: 10)
        XCTAssertEqual(row.size, NSSize(width: 5780, height: 1080))
        XCTAssertEqual(frames(row), [rect(0, 0, 1920, 1080), rect(1930, 0, 1920, 1080), rect(3860, 0, 1920, 1080)])
    }

    func testColumnScalesToTheWidest() {
        let column = layout(.column, [hd, NSSize(width: 960, height: 400)], gap: 4)
        XCTAssertEqual(column.size, NSSize(width: 1920, height: 1884))
        XCTAssertEqual(frames(column), [rect(0, 0, 1920, 1080), rect(0, 1084, 1920, 800)])
    }

    func testGridOfThreeIsTwoByTwoCellsOfTheLargest() {
        let grid = layout(.grid, [hd, hd, hd], gap: 8)
        XCTAssertEqual(grid.size, NSSize(width: 3848, height: 2168))
        XCTAssertEqual(frames(grid), [rect(0, 0, 1920, 1080), rect(1928, 0, 1920, 1080), rect(0, 1088, 1920, 1080)])
    }

    func testGridFitsEachSourceInItsCell() {
        let grid = layout(.grid, [hd, depth])
        XCTAssertEqual(grid.size, NSSize(width: 3840, height: 1080))
        // 512 × 520 fitted in 1920 × 1080: 1063 × 1080, centred in the second cell
        XCTAssertEqual(frames(grid)[1], rect(1920 + 428, 0, 1063, 1080))
    }

    func testGridOfFiveIsThreeColumns() {
        let grid = layout(.grid, [hd, hd, hd, hd, hd])
        XCTAssertEqual(grid.size, NSSize(width: 5760, height: 2160))
        XCTAssertEqual(frames(grid)[3], rect(0, 1080, 1920, 1080))
        XCTAssertEqual(frames(grid)[4], rect(1920, 1080, 1920, 1080))
    }

    func testFocusPutsTheOthersInAColumn() {
        let focus = layout(.focus, [hd, hd, hd])
        // The two others share the first's height: 540 each, so 960 wide
        XCTAssertEqual(focus.size, NSSize(width: 2880, height: 1080))
        XCTAssertEqual(frames(focus), [rect(0, 0, 1920, 1080), rect(1920, 0, 960, 540), rect(1920, 540, 960, 540)])
    }

    func testFocusWithAGapAndSourcesOfOtherShapes() {
        let focus = layout(.focus, [hd, depth, hd], gap: 10)
        // Each of the others has (1080 − 10) / 2 = 535 of height: 512 × 520 is 527 × 535, 1920 × 1080 is 951 × 535
        XCTAssertEqual(focus.size, NSSize(width: 1920 + 10 + 952, height: 1080))
        XCTAssertEqual(frames(focus)[0], rect(0, 0, 1920, 1080))
        XCTAssertEqual(frames(focus)[1], rect(1930 + 212, 0, 527, 535), "centred in the column")
        XCTAssertEqual(frames(focus)[2], rect(1930, 545, 951, 535))
    }

    func testFocusWithOneOtherSource() {
        let focus = layout(.focus, [hd, depth])
        XCTAssertEqual(focus.size, NSSize(width: 2984, height: 1080))
        XCTAssertEqual(frames(focus), [rect(0, 0, 1920, 1080), rect(1920, 0, 1063, 1080)])
    }

    func testASourceNeverSeenCountsAs1080p() {
        let row = layout(.row, [NSNull(), NSSize.zero, NSSize(width: 0, height: 480)])
        XCTAssertEqual(row.size, NSSize(width: 5760, height: 1080))
        XCTAssertEqual(frames(row)[2], rect(3840, 0, 1920, 1080))
    }

    func testAFittingSizeScalesAndCentresThePicture() {
        let row = layout(.row, [hd, hd], fitting: hd)
        XCTAssertEqual(row.size, hd)
        XCTAssertEqual(frames(row), [rect(0, 270, 960, 540), rect(960, 270, 960, 540)])
        let tall = layout(.column, [hd, hd], fitting: hd)
        XCTAssertEqual(frames(tall), [rect(480, 0, 960, 540), rect(480, 540, 960, 540)])
    }

    func testAFittingSizeWithOneDimensionIsAutomatic() {
        XCTAssertEqual(layout(.row, [hd, hd], fitting: NSSize(width: 1920, height: 0)).size, NSSize(width: 3840, height: 1080))
    }

    func testSizesAreEven() {
        for kind in kinds {
            let odd = layout(kind, [NSSize(width: 641, height: 361), NSSize(width: 333, height: 77), NSSize(width: 101, height: 303)], gap: 3)
            XCTAssertEqual(Int(odd.size.width) % 2, 0, "\(kind.rawValue)")
            XCTAssertEqual(Int(odd.size.height) % 2, 0, "\(kind.rawValue)")
            XCTAssertEqual(layout(kind, [hd, hd], fitting: NSSize(width: 1001, height: 501)).size, NSSize(width: 1000, height: 500))
        }
    }

    func testEightSources() {
        let sizes: [NSSize] = [hd, depth, NSSize(width: 640, height: 480), hd, NSSize(width: 1080, height: 1920), depth, hd, NSSize(width: 3840, height: 2160)]
        for kind in kinds {
            for fitting in [NSSize.zero, hd] {
                let eight = layout(kind, sizes, gap: 6, fitting: fitting)
                let rects = frames(eight)
                XCTAssertEqual(rects.count, 8)
                let picture = NSRect(origin: .zero, size: eight.size)
                for (index, rect) in rects.enumerated() {
                    XCTAssertTrue(rect.width >= 1 && rect.height >= 1, "\(kind.rawValue): source \(index) has no place")
                    XCTAssertTrue(picture.contains(rect), "\(kind.rawValue): source \(index) at \(rect) is outside \(eight.size)")
                    XCTAssertEqual(rect, rect.integral, "\(kind.rawValue): whole pixels")
                    for other in rects[(index + 1)...] {
                        XCTAssertTrue(rect.intersection(other).isEmpty, "\(kind.rawValue): \(rect) overlaps \(other)")
                    }
                }
            }
        }
    }

    func testKindNames() {
        XCTAssertEqual(Layout.kindNames(), ["row", "column", "grid", "focus"])
        XCTAssertEqual(Layout.name(for: .focus), "focus")
        var kind = LayoutKind.row
        XCTAssertTrue(Layout.getKind(&kind, forName: "Grid"))
        XCTAssertEqual(kind, .grid)
        XCTAssertFalse(Layout.getKind(&kind, forName: "pile"))
    }
}
