//
//  ScriptGenerator.swift
//  Domta
//
//  Created by Codex on 25/3/26.
//

import Foundation

enum ScriptGenerator {
    static func wrapScriptBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return """
            -- No differences found.
            """
        }

        return """
        BEGIN TRANSACTION;
        GO

        \(trimmed)

        COMMIT TRANSACTION;
        GO
        """
    }

    static func makeScript(diff: TableDiff, schema: TableSchema) -> String {
        guard !(diff.inserts.isEmpty && diff.updates.isEmpty && diff.deletes.isEmpty) else {
            return ""
        }

        var lines: [String] = [
            "-- Sync \(schema.displayName)"
        ]

        if schema.hasIdentityColumn && !diff.inserts.isEmpty {
            lines.append("SET IDENTITY_INSERT \(MetadataQuery.qualifiedName(for: schema)) ON;")
            lines.append("GO")
        }

        for pair in diff.updates {
            if let source = pair.source {
                lines.append(makeUpdateStatement(row: source, schema: schema))
                lines.append("GO")
            }
        }

        for pair in diff.inserts {
            if let source = pair.source {
                lines.append(makeInsertStatement(row: source, schema: schema))
                lines.append("GO")
            }
        }

        for pair in diff.deletes {
            if let target = pair.target {
                lines.append(makeDeleteStatement(row: target, schema: schema))
                lines.append("GO")
            }
        }

        if schema.hasIdentityColumn && !diff.inserts.isEmpty {
            lines.append("SET IDENTITY_INSERT \(MetadataQuery.qualifiedName(for: schema)) OFF;")
            lines.append("GO")
        }

        return lines.joined(separator: "\n")
    }

    private static func makeUpdateStatement(row: [String: JSONValue], schema: TableSchema) -> String {
        let assignments = schema.updatableColumns.map { column in
            "\(MetadataQuery.quoteIdentifier(column.name)) = \(sqlLiteral(for: column, value: row[column.name] ?? .null))"
        }.joined(separator: ", ")

        return """
        UPDATE \(MetadataQuery.qualifiedName(for: schema))
        SET \(assignments)
        WHERE \(whereClause(for: row, schema: schema));
        """
    }

    private static func makeInsertStatement(row: [String: JSONValue], schema: TableSchema) -> String {
        let columns = schema.insertableColumns.map { MetadataQuery.quoteIdentifier($0.name) }.joined(separator: ", ")
        let values = schema.insertableColumns.map { sqlLiteral(for: $0, value: row[$0.name] ?? .null) }.joined(separator: ", ")

        return """
        INSERT INTO \(MetadataQuery.qualifiedName(for: schema)) (\(columns))
        VALUES (\(values));
        """
    }

    private static func makeDeleteStatement(row: [String: JSONValue], schema: TableSchema) -> String {
        """
        DELETE FROM \(MetadataQuery.qualifiedName(for: schema))
        WHERE \(whereClause(for: row, schema: schema));
        """
    }

    private static func whereClause(for row: [String: JSONValue], schema: TableSchema) -> String {
        schema.primaryKeyColumns.map { column in
            let identifier = MetadataQuery.quoteIdentifier(column.name)
            let value = row[column.name] ?? .null

            if case .null = value {
                return "\(identifier) IS NULL"
            }

            return "\(identifier) = \(sqlLiteral(for: column, value: value))"
        }.joined(separator: " AND ")
    }

    private static func sqlLiteral(for column: TableColumn, value: JSONValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .bool(let boolValue):
            return boolValue ? "1" : "0"
        case .number(let number):
            return NumberFormatter.domtaNumber.string(from: NSNumber(value: number)) ?? String(number)
        case .string(let stringValue):
            return stringLiteral(for: column, value: stringValue)
        case .array, .object:
            let serialized = value.displayString.replacingOccurrences(of: "'", with: "''")
            return "N'\(serialized)'"
        }
    }

    private static func stringLiteral(for column: TableColumn, value: String) -> String {
        let lowered = column.dataType.lowercased()

        if ["binary", "varbinary", "image"].contains(lowered) {
            if value.lowercased().hasPrefix("0x") {
                return value
            }
            if let data = Data(base64Encoded: value) {
                return "0x" + data.map { String(format: "%02X", $0) }.joined()
            }
        }

        if ["bit", "tinyint", "smallint", "int", "bigint", "decimal", "numeric", "money", "smallmoney", "float", "real"].contains(lowered) {
            return value
        }

        let escaped = value.replacingOccurrences(of: "'", with: "''")

        if ["nchar", "nvarchar", "ntext", "sysname", "xml"].contains(lowered) {
            return "N'\(escaped)'"
        }

        return "'\(escaped)'"
    }
}
