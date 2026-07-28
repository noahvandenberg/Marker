import Foundation

/// Rewrites a pipe table so its source lines up in a monospaced font.
///
/// The editor renders tables from the raw pipe syntax, so making the source
/// itself aligned is what makes them readable — and it keeps the file portable.
enum TableFormatter {

    static func render(rows: [[String]],
                       alignments: [TableAlignment],
                       columnCount: Int) -> String {
        guard columnCount > 0 else { return "" }

        let normalized = rows.map { row -> [String] in
            var cells = row.map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.count > columnCount { cells = Array(cells.prefix(columnCount)) }
            while cells.count < columnCount { cells.append("") }
            return cells
        }

        var widths = [Int](repeating: 3, count: columnCount)
        for row in normalized {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }

        var lines: [String] = []
        for (rowIndex, row) in normalized.enumerated() {
            var cells: [String] = []
            for (index, cell) in row.enumerated() {
                let alignment = index < alignments.count ? alignments[index] : .none
                cells.append(pad(cell, to: widths[index], alignment: alignment))
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")

            // The delimiter row always follows the header.
            if rowIndex == 0 {
                var separators: [String] = []
                for index in 0..<columnCount {
                    let alignment = index < alignments.count ? alignments[index] : .none
                    separators.append(delimiter(width: widths[index], alignment: alignment))
                }
                lines.append("| " + separators.joined(separator: " | ") + " |")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func pad(_ text: String, to width: Int, alignment: TableAlignment) -> String {
        let deficit = max(0, width - text.count)
        switch alignment {
        case .right:
            return String(repeating: " ", count: deficit) + text
        case .center:
            let left = deficit / 2
            return String(repeating: " ", count: left) + text
                + String(repeating: " ", count: deficit - left)
        case .left, .none:
            return text + String(repeating: " ", count: deficit)
        }
    }

    private static func delimiter(width: Int, alignment: TableAlignment) -> String {
        let w = max(3, width)
        switch alignment {
        case .none: return String(repeating: "-", count: w)
        case .left: return ":" + String(repeating: "-", count: w - 1)
        case .right: return String(repeating: "-", count: w - 1) + ":"
        case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
        }
    }
}
