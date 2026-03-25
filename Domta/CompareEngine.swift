//
//  CompareEngine.swift
//  Domta
//
//  Created by Codex on 25/3/26.
//

import Foundation

enum CompareEngine {
    static func diff(sourceRows: [[String: JSONValue]], targetRows: [[String: JSONValue]], schema: TableSchema) -> TableDiff {
        let sourceMap = Dictionary(uniqueKeysWithValues: sourceRows.map { (keyString(for: $0, schema: schema), $0) })
        let targetMap = Dictionary(uniqueKeysWithValues: targetRows.map { (keyString(for: $0, schema: schema), $0) })

        let allKeys = Set(sourceMap.keys).union(targetMap.keys).sorted()

        var inserts: [RowPair] = []
        var updates: [RowPair] = []
        var deletes: [RowPair] = []

        for key in allKeys {
            switch (sourceMap[key], targetMap[key]) {
            case let (source?, nil):
                inserts.append(RowPair(key: key, source: source, target: nil))
            case let (nil, target?):
                deletes.append(RowPair(key: key, source: nil, target: target))
            case let (source?, target?):
                if rowsDiffer(source, target, schema: schema) {
                    updates.append(RowPair(key: key, source: source, target: target))
                }
            case (nil, nil):
                break
            }
        }

        return TableDiff(
            sourceRowCount: sourceRows.count,
            targetRowCount: targetRows.count,
            inserts: inserts,
            updates: updates,
            deletes: deletes
        )
    }

    static func makeResult(diff: TableDiff, schema: TableSchema) -> TableCompareResult {
        var samples: [DiffSample] = []

        samples += diff.inserts.prefix(3).map { pair in
            DiffSample(kind: .insert, keyDisplay: pair.key, summary: preview(for: pair.source, schema: schema))
        }

        samples += diff.updates.prefix(3).map { pair in
            let before = preview(for: pair.target, schema: schema)
            let after = preview(for: pair.source, schema: schema)
            return DiffSample(kind: .update, keyDisplay: pair.key, summary: "target={\(before)} -> source={\(after)}")
        }

        samples += diff.deletes.prefix(3).map { pair in
            DiffSample(kind: .delete, keyDisplay: pair.key, summary: preview(for: pair.target, schema: schema))
        }

        return TableCompareResult(
            tableName: schema.displayName,
            comparableColumns: schema.comparableColumns,
            sourceRowCount: diff.sourceRowCount,
            targetRowCount: diff.targetRowCount,
            insertCount: diff.inserts.count,
            updateCount: diff.updates.count,
            deleteCount: diff.deletes.count,
            inserts: diff.inserts,
            updates: diff.updates,
            deletes: diff.deletes,
            samples: samples
        )
    }

    static func keyString(for row: [String: JSONValue], schema: TableSchema) -> String {
        schema.primaryKeyColumns
            .map { column in
                let value = row[column.name] ?? .null
                return "\(column.name)=\(value.displayString)"
            }
            .joined(separator: " | ")
    }

    private static func rowsDiffer(_ left: [String: JSONValue], _ right: [String: JSONValue], schema: TableSchema) -> Bool {
        for column in schema.comparableColumns {
            if (left[column.name] ?? .null) != (right[column.name] ?? .null) {
                return true
            }
        }

        return false
    }

    private static func preview(for row: [String: JSONValue]?, schema: TableSchema) -> String {
        guard let row else { return "NULL" }

        return schema.comparableColumns.prefix(6).map { column in
            "\(column.name)=\((row[column.name] ?? .null).displayString)"
        }.joined(separator: ", ")
    }
}
