#if os(macOS)
import AppKit

/// A foreground override for a UTF-16 range in a logical (soft-wrapped) line.
/// Providers are only called for lines of at most 4,096 displayed characters.
/// Buffer attributes, clipboard contents and remote bytes are never modified.
public struct TerminalDisplayHighlight {
    public let range: NSRange
    public let color: NSColor

    public init(range: NSRange, color: NSColor) {
        self.range = range
        self.color = color
    }
}

extension TerminalView {
    func displayHighlightColors(row: Int, line: BufferLine, cols: Int) -> [Int: NSColor] {
        guard !terminal.isDisplayBufferAlternate, let provider = displayHighlights else { return [:] }
        let buffer = terminal.displayBuffer
        guard cols > 0 else { return [:] }
        let limit = 4_096
        // Even wide glyphs occupy at most two cells. Bound the backwards traversal
        // before building text, including giant lines that are already in scrollback.
        let maxRows = limit * 2 / cols + 1
        var start = row
        while start > 0, buffer.lines[start].isWrapped {
            start -= 1
            if row - start >= maxRows { return [:] }
        }
        var text = ""
        var cells: [(column: Int, range: NSRange)] = []
        var offset = 0
        var count = 0
        var index = start
        repeat {
            let source = index == row ? line : buffer.lines[index]
            var column = 0
            while column < cols {
                count += 1
                if count > limit { return [:] }
                let cell = source[column]
                let character = cell.code == 0 ? " " : String(terminal.getCharacter(for: cell))
                // Also bound pathological combining-character sequences.
                if offset + character.utf16.count > limit * 4 { return [:] }
                if index == row {
                    cells.append((column, NSRange(location: offset, length: character.utf16.count)))
                }
                text += character
                offset += character.utf16.count
                column += max(1, Int(cell.width))
            }
            index += 1
        } while index < buffer.lines.count && buffer.lines[index].isWrapped
        // If the first retained row is a continuation of evicted history, we cannot
        // establish the left boundary reliably; skip rather than color a fragment.
        if start == 0 && buffer.lines[start].isWrapped {
            return [:]
        }
        let textLength = offset
        let matches = provider(text)
        guard !matches.isEmpty else { return [:] }
        var colors: [Int: NSColor] = [:]
        for match in matches {
            guard match.range.location >= 0, match.range.length > 0,
                  match.range.location <= textLength,
                  match.range.length <= textLength - match.range.location else { continue }
            for cell in cells where NSIntersectionRange(cell.range, match.range).length == cell.range.length {
                colors[cell.column] = match.color
            }
        }
        return colors
    }
}
#endif
