//
//  SQLSyntaxHighlighter.swift
//  Domta
//

import SwiftUI

/// ระบายสี T-SQL แบบบรรทัดต่อบรรทัดสำหรับมุมมอง Comparison Details
///
/// ทำงานทีละบรรทัดจึงไม่รู้จัก block comment ที่คร่อมหลายบรรทัด — แลกกับการที่
/// `LazyVStack` เรนเดอร์เฉพาะบรรทัดที่มองเห็นได้โดยไม่ต้องวิเคราะห์ทั้งไฟล์ก่อน
enum SQLSyntaxHighlighter {
    /// บรรทัดที่ยาวกว่านี้ปล่อยเป็นข้อความธรรมดา — ไม่คุ้มกับการ tokenize
    private static let maximumLineLength = 500

    private static let keywords: Set<String> = [
        "ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASCADE",
        "CASE", "CHECK", "CLUSTERED", "COLLATE", "COLUMN", "COMMIT", "CONSTRAINT", "CREATE",
        "CROSS", "CURRENT", "DECLARE", "DEFAULT", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE",
        "END", "EXEC", "EXECUTE", "EXISTS", "FOR", "FOREIGN", "FROM", "FULL", "FUNCTION", "GO",
        "GROUP", "HAVING", "IDENTITY", "IF", "IN", "INDEX", "INNER", "INSERT", "INTO", "IS",
        "JOIN", "KEY", "LEFT", "LIKE", "NOCHECK", "NONCLUSTERED", "NOT", "NULL", "OFF", "ON",
        "OPTION", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PERSISTED", "PRIMARY", "PRINT",
        "PROC", "PROCEDURE", "REFERENCES", "RETURN", "RETURNS", "RIGHT", "ROLLBACK", "SCHEMA",
        "SELECT", "SET", "TABLE", "THEN", "TOP", "TRANSACTION", "TRIGGER", "TRUNCATE", "UNION",
        "UNIQUE", "UPDATE", "USE", "VALUES", "VIEW", "WHEN", "WHERE", "WITH"
    ]

    private static let types: Set<String> = [
        "BIGINT", "BINARY", "BIT", "CHAR", "DATE", "DATETIME", "DATETIME2", "DATETIMEOFFSET",
        "DECIMAL", "FLOAT", "GEOGRAPHY", "GEOMETRY", "HIERARCHYID", "IMAGE", "INT", "MAX",
        "MONEY", "NCHAR", "NTEXT", "NUMERIC", "NVARCHAR", "REAL", "ROWVERSION", "SMALLDATETIME",
        "SMALLINT", "SMALLMONEY", "SQL_VARIANT", "TEXT", "TIME", "TIMESTAMP", "TINYINT",
        "UNIQUEIDENTIFIER", "VARBINARY", "VARCHAR", "XML"
    ]

    private enum TokenStyle {
        case plain
        case keyword
        case type
        case identifier
        case string
        case number
        case comment

        var color: Color {
            switch self {
            case .plain: return .primary
            case .keyword: return Color(red: 0.35, green: 0.63, blue: 0.90)
            case .type: return Color(red: 0.30, green: 0.75, blue: 0.78)
            case .identifier: return Color(red: 0.60, green: 0.78, blue: 0.98)
            case .string: return Color(red: 0.85, green: 0.60, blue: 0.42)
            case .number: return Color(red: 0.80, green: 0.45, blue: 0.80)
            case .comment: return Color(red: 0.45, green: 0.62, blue: 0.45)
            }
        }
    }

    static func highlight(_ line: String) -> AttributedString {
        guard !line.isEmpty, line.count <= maximumLineLength else {
            return AttributedString(line)
        }

        var result = AttributedString()
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                result.append(styled(String(characters[index...]), .comment))
                break
            }

            if character == "[" {
                let start = index
                index += 1
                while index < characters.count, characters[index] != "]" { index += 1 }
                if index < characters.count { index += 1 }
                result.append(styled(String(characters[start..<index]), .identifier))
                continue
            }

            if character == "'" {
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "'" {
                        index += 1
                        if index < characters.count, characters[index] == "'" { index += 1; continue }
                        break
                    }
                    index += 1
                }
                result.append(styled(String(characters[start..<index]), .string))
                continue
            }

            if character.isNumber {
                let start = index
                while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
                result.append(styled(String(characters[start..<index]), .number))
                continue
            }

            if character.isLetter || character == "_" || character == "@" || character == "#" {
                let start = index
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber
                        || characters[index] == "_" || characters[index] == "@" || characters[index] == "#" {
                    index += 1
                }

                let word = String(characters[start..<index])
                let upper = word.uppercased()
                let style: TokenStyle = keywords.contains(upper) ? .keyword : (types.contains(upper) ? .type : .plain)
                result.append(styled(word, style))
                continue
            }

            let start = index
            index += 1
            result.append(styled(String(characters[start..<index]), .plain))
        }

        return result
    }

    private static func styled(_ text: String, _ style: TokenStyle) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = style.color
        return piece
    }
}
