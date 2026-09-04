//
//  SchemaDiffEngine.swift
//  Domta
//

import Foundation

/// diff รายบรรทัดสำหรับ definition ของ view / stored procedure / function / table
///
/// ตัด prefix และ suffix ที่เหมือนกันออกก่อนแล้วค่อยทำ LCS เฉพาะช่วงกลาง
/// เพราะ definition ส่วนใหญ่ต่างกันไม่กี่บรรทัด — ทำให้ตาราง DP เล็กพอที่จะไม่กินหน่วยความจำ
nonisolated enum SchemaDiffEngine {
    /// ขนาดช่วงกลางสูงสุดที่ยอมทำ LCS (1500 x 1500 x 4 byte ~ 9 MB)
    static let maximumLCSLineCount = 1500

    static func diff(sourceText: String?, targetText: String?) -> SchemaObjectDefinition {
        let sourceLines = splitLines(sourceText)
        let targetLines = splitLines(targetText)

        let (lines, isTruncated) = makeLines(source: sourceLines, target: targetLines)

        return SchemaObjectDefinition(
            sourceText: sourceText,
            targetText: targetText,
            lines: lines,
            sideBySideRows: sideBySideRows(from: lines),
            isTruncated: isTruncated
        )
    }

    /// จับคู่บรรทัดของสองฝั่งให้อยู่แถวเดียวกัน สำหรับมุมมองเทียบซ้าย-ขวา
    ///
    /// บรรทัดที่ต่างกันเป็นช่วงติดกันจะถูกจับคู่ทีละบรรทัดตามลำดับ ช่วงที่ยาวไม่เท่ากัน
    /// ฝั่งที่สั้นกว่าจะเว้นว่างไว้ — อ่านง่ายกว่าการไล่บรรทัดเดี่ยว ๆ ทีละฝั่ง
    static func sideBySideRows(from lines: [SchemaDiffLine]) -> [SchemaSideBySideRow] {
        var rows: [SchemaSideBySideRow] = []
        var sourceRun: [SchemaDiffLine] = []
        var targetRun: [SchemaDiffLine] = []

        func flushRuns() {
            let pairCount = max(sourceRun.count, targetRun.count)

            for index in 0..<pairCount {
                let sourceLine = index < sourceRun.count ? sourceRun[index] : nil
                let targetLine = index < targetRun.count ? targetRun[index] : nil

                let kind: SchemaSideBySideRowKind
                switch (sourceLine, targetLine) {
                case (.some, .some): kind = .changed
                case (.some, nil): kind = .sourceOnly
                default: kind = .targetOnly
                }

                rows.append(
                    SchemaSideBySideRow(
                        id: rows.count,
                        sourceNumber: sourceLine?.sourceNumber,
                        sourceText: sourceLine?.text,
                        targetNumber: targetLine?.targetNumber,
                        targetText: targetLine?.text,
                        kind: kind
                    )
                )
            }

            sourceRun.removeAll()
            targetRun.removeAll()
        }

        for line in lines {
            switch line.kind {
            case .sourceOnly:
                sourceRun.append(line)
            case .targetOnly:
                targetRun.append(line)
            case .unchanged:
                flushRuns()
                rows.append(
                    SchemaSideBySideRow(
                        id: rows.count,
                        sourceNumber: line.sourceNumber,
                        sourceText: line.text,
                        targetNumber: line.targetNumber,
                        targetText: line.text,
                        kind: .unchanged
                    )
                )
            }
        }

        flushRuns()
        return rows
    }

    private static func splitLines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }

        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func makeLines(source: [String], target: [String]) -> ([SchemaDiffLine], Bool) {
        var builder = DiffLineBuilder()

        var prefixLength = 0
        while prefixLength < source.count,
              prefixLength < target.count,
              isEqual(source[prefixLength], target[prefixLength]) {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < source.count - prefixLength,
              suffixLength < target.count - prefixLength,
              isEqual(source[source.count - 1 - suffixLength], target[target.count - 1 - suffixLength]) {
            suffixLength += 1
        }

        for index in 0..<prefixLength {
            builder.appendUnchanged(source[index])
        }

        let sourceMiddle = Array(source[prefixLength..<(source.count - suffixLength)])
        let targetMiddle = Array(target[prefixLength..<(target.count - suffixLength)])
        var isTruncated = false

        if sourceMiddle.count > maximumLCSLineCount || targetMiddle.count > maximumLCSLineCount {
            isTruncated = true
            for line in sourceMiddle { builder.appendSourceOnly(line) }
            for line in targetMiddle { builder.appendTargetOnly(line) }
        } else {
            appendLCSDiff(source: sourceMiddle, target: targetMiddle, into: &builder)
        }

        for index in (source.count - suffixLength)..<source.count {
            builder.appendUnchanged(source[index])
        }

        return (builder.lines, isTruncated)
    }

    /// เทียบแบบ trim ท้ายบรรทัด เพราะ SQL Server เก็บ definition ตามที่พิมพ์มาเป๊ะ ๆ
    private static func isEqual(_ left: String, _ right: String) -> Bool {
        left == right || left.trimmingCharacters(in: .whitespaces) == right.trimmingCharacters(in: .whitespaces)
    }

    private static func appendLCSDiff(source: [String], target: [String], into builder: inout DiffLineBuilder) {
        let rowCount = source.count
        let columnCount = target.count

        guard rowCount > 0 else {
            for line in target { builder.appendTargetOnly(line) }
            return
        }

        guard columnCount > 0 else {
            for line in source { builder.appendSourceOnly(line) }
            return
        }

        let rowStride = columnCount + 1
        var table = [Int32](repeating: 0, count: (rowCount + 1) * rowStride)

        for row in 1...rowCount {
            for column in 1...columnCount {
                if isEqual(source[row - 1], target[column - 1]) {
                    table[row * rowStride + column] = table[(row - 1) * rowStride + (column - 1)] + 1
                } else {
                    table[row * rowStride + column] = max(
                        table[(row - 1) * rowStride + column],
                        table[row * rowStride + (column - 1)]
                    )
                }
            }
        }

        var operations: [(kind: SchemaDiffLineKind, text: String)] = []
        var row = rowCount
        var column = columnCount

        while row > 0 && column > 0 {
            if isEqual(source[row - 1], target[column - 1]) {
                operations.append((.unchanged, source[row - 1]))
                row -= 1
                column -= 1
            } else if table[(row - 1) * rowStride + column] >= table[row * rowStride + (column - 1)] {
                operations.append((.sourceOnly, source[row - 1]))
                row -= 1
            } else {
                operations.append((.targetOnly, target[column - 1]))
                column -= 1
            }
        }

        while row > 0 {
            operations.append((.sourceOnly, source[row - 1]))
            row -= 1
        }

        while column > 0 {
            operations.append((.targetOnly, target[column - 1]))
            column -= 1
        }

        for operation in operations.reversed() {
            switch operation.kind {
            case .unchanged: builder.appendUnchanged(operation.text)
            case .sourceOnly: builder.appendSourceOnly(operation.text)
            case .targetOnly: builder.appendTargetOnly(operation.text)
            }
        }
    }
}

private nonisolated struct DiffLineBuilder {
    private(set) var lines: [SchemaDiffLine] = []
    private var sourceNumber = 0
    private var targetNumber = 0

    mutating func appendUnchanged(_ text: String) {
        sourceNumber += 1
        targetNumber += 1
        lines.append(
            SchemaDiffLine(id: lines.count, sourceNumber: sourceNumber, targetNumber: targetNumber, text: text, kind: .unchanged)
        )
    }

    mutating func appendSourceOnly(_ text: String) {
        sourceNumber += 1
        lines.append(
            SchemaDiffLine(id: lines.count, sourceNumber: sourceNumber, targetNumber: nil, text: text, kind: .sourceOnly)
        )
    }

    mutating func appendTargetOnly(_ text: String) {
        targetNumber += 1
        lines.append(
            SchemaDiffLine(id: lines.count, sourceNumber: nil, targetNumber: targetNumber, text: text, kind: .targetOnly)
        )
    }
}
