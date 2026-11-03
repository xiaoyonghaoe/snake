import CoreGraphics
import XCTest
@testable import SwiftTerm

/// The Metal renderer puts glyphs on the cell grid, so splitting a run (as a
/// moving selection does) never shifts the text that follows the split.
final class MetalGlyphGridTests: XCTestCase {
    func testGlyphPositionDoesNotDependOnWhereItsRunStarts() {
        let cellWidth: CGFloat = 8.4287
        // Column 12 drawn as the 12th glyph of one run starting at column 0…
        let unsplit = MetalTerminalRenderer.gridGlyphX(lineOriginX: 0, cellWidth: cellWidth,
                                                       startColumn: 0, glyphIndex: 12, columnWidth: 1)
        // …or as the 3rd glyph of a run that a selection edge started at column 9.
        let split = MetalTerminalRenderer.gridGlyphX(lineOriginX: 0, cellWidth: cellWidth,
                                                     startColumn: 9, glyphIndex: 3, columnWidth: 1)
        XCTAssertEqual(unsplit, split)
        XCTAssertEqual(unsplit, 12 * cellWidth)
    }

    func testWideGlyphsAdvanceTwoColumns() {
        let x = MetalTerminalRenderer.gridGlyphX(lineOriginX: 4, cellWidth: 10,
                                                 startColumn: 2, glyphIndex: 3, columnWidth: 2)
        XCTAssertEqual(x, 4 + CGFloat(2 + 3 * 2) * 10)
    }
}
