//
//  SchemaCompareModels.swift
//  Domta
//

import Foundation

/// โหมดการทำงานหลักของแอป — เทียบข้อมูลในตาราง หรือเทียบโครงสร้าง schema
nonisolated enum CompareMode: String, CaseIterable, Identifiable, Hashable {
    case data
    case schema

    var id: String { rawValue }

    var title: String {
        switch self {
        case .data: return "Data Compare"
        case .schema: return "Schema Compare"
        }
    }

    var systemImage: String {
        switch self {
        case .data: return "tablecells"
        case .schema: return "square.stack.3d.up"
        }
    }

    var subtitle: String {
        switch self {
        case .data:
            return "เทียบข้อมูลในตารางที่ schema ตรงกัน แล้ว generate script sync ข้อมูล (ใช้ sqlcmd)"
        case .schema:
            return "เทียบโครงสร้าง table / view / stored procedure แล้ว generate deployment script (ใช้ sqlpackage)"
        }
    }

    var workflowSummary: String {
        switch self {
        case .data: return "Load > Compare > Sync"
        case .schema: return "Extract > Diff > Deploy"
        }
    }

    var requiredTool: String {
        switch self {
        case .data: return "sqlcmd"
        case .schema: return "sqlpackage"
        }
    }
}

/// กลุ่มชนิดของ object ที่ schema compare แสดงผล
///
/// sqlpackage คืน type ละเอียดมาก (`SqlTable`, `SqlIndex`, `SqlDefaultConstraint`, ...)
/// จึงยุบให้เหลือกลุ่มที่ผู้ใช้สนใจจริง โดย object ลูกของ table ถูกนับรวมเป็น table
nonisolated enum SchemaObjectCategory: String, CaseIterable, Identifiable, Hashable {
    case table
    case view
    case storedProcedure
    case function
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .table: return "Tables"
        case .view: return "Views"
        case .storedProcedure: return "Stored Procedures"
        case .function: return "Functions"
        case .other: return "Others"
        }
    }

    var shortTitle: String {
        switch self {
        case .table: return "Table"
        case .view: return "View"
        case .storedProcedure: return "Procedure"
        case .function: return "Function"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .table: return "tablecells"
        case .view: return "eye"
        case .storedProcedure: return "gearshape.2"
        case .function: return "function"
        case .other: return "shippingbox"
        }
    }

    /// object ที่ดึง definition มาเทียบบรรทัดต่อบรรทัดได้
    var supportsDefinitionDiff: Bool {
        self != .other
    }

    /// ชื่อ object type ของ sqlpackage ที่ใช้ใน `/p:ExcludeObjectTypes` เมื่อผู้ใช้ไม่เลือกกลุ่มนี้
    var excludableObjectTypeNames: [String] {
        switch self {
        case .table: return ["Tables"]
        case .view: return ["Views"]
        case .storedProcedure: return ["StoredProcedures"]
        case .function: return ["ScalarValuedFunctions", "TableValuedFunctions", "Aggregates"]
        case .other: return []
        }
    }

    /// type ของ sqlpackage ที่เป็น object ลูกของ table — นับรวมกลับเข้ากลุ่ม table
    private static let tableScopedTypes: Set<String> = [
        "SqlSimpleColumn",
        "SqlComputedColumn",
        "SqlIndex",
        "SqlColumnStoreIndex",
        "SqlSpatialIndex",
        "SqlFullTextIndex",
        "SqlPrimaryKeyConstraint",
        "SqlForeignKeyConstraint",
        "SqlUniqueConstraint",
        "SqlCheckConstraint",
        "SqlDefaultConstraint",
        "SqlDmlTrigger",
        "SqlStatistic",
        "SqlFilegroup"
    ]

    /// object ลูกของ table (column / index / constraint / trigger) — ไม่ใช่ object ระดับบนของตัวเอง
    static func isTableScopedType(_ type: String) -> Bool {
        tableScopedTypes.contains(type)
    }

    static func category(forSqlPackageType type: String) -> SchemaObjectCategory {
        if type == "SqlTable" { return .table }
        if type.contains("Procedure") { return .storedProcedure }
        if type.contains("View") { return .view }
        if type.contains("Function") || type.contains("Aggregate") { return .function }
        if tableScopedTypes.contains(type) { return .table }
        return .other
    }
}

/// ชนิดของความต่างที่ sqlpackage รายงานใน DeployReport
nonisolated enum SchemaChangeKind: String, CaseIterable, Identifiable, Hashable {
    case create
    case alter
    case drop
    case rebuild
    /// sqlpackage สั่ง Drop แล้ว Create object เดิมในรอบเดียว — มีทั้งสองฝั่งแต่นิยามต่างกันจนแก้ในที่ไม่ได้
    /// (เช่น table ที่ column ถูกนิยามใหม่ทั้งหมด) ข้อมูลในฝั่ง target จะหาย
    case recreate
    case other

    var id: String { rawValue }

    /// ป้ายในมุมมอง schema compare — สื่อว่า "อยู่ฝั่งไหน" มากกว่าสื่อว่า sqlpackage จะทำอะไร
    var title: String {
        switch self {
        case .create: return "Only in Source"
        case .alter: return "Different"
        case .drop: return "Only in Target"
        case .rebuild: return "Rebuild"
        case .recreate: return "Drop & Create"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .create: return "plus.circle.fill"
        case .alter: return "pencil.circle.fill"
        case .drop: return "minus.circle.fill"
        case .rebuild: return "arrow.triangle.2.circlepath.circle.fill"
        case .recreate: return "exclamationmark.arrow.triangle.2.circlepath"
        case .other: return "questionmark.circle.fill"
        }
    }

    static func kind(forOperationName name: String) -> SchemaChangeKind {
        switch name.lowercased() {
        case "create": return .create
        case "alter": return .alter
        case "drop": return .drop
        case "tablerebuild", "rebuild": return .rebuild
        default: return .other
        }
    }
}

/// ความต่างหนึ่งรายการที่อ่านมาจาก `<Operation><Item/></Operation>` ของ DeployReport
nonisolated struct SchemaDifference: Identifiable, Hashable {
    let id: String
    let kind: SchemaChangeKind
    let operationName: String
    let sqlPackageType: String
    let category: SchemaObjectCategory
    let rawValue: String
    let schemaName: String
    let objectName: String
    let memberName: String?
    /// constraint ไม่มีชื่อ — sqlpackage รายงานเป็น `unnamed constraint on [schema].[table]`
    let isUnnamedConstraint: Bool

    /// object แม่ที่ใช้ดึง definition — index/constraint จะชี้กลับไปที่ table ของตัวเอง
    var parentDisplayName: String {
        schemaName.isEmpty ? "[\(objectName)]" : "[\(schemaName)].[\(objectName)]"
    }

    var displayName: String { rawValue }

    var typeDisplay: String {
        sqlPackageType.hasPrefix("Sql") ? String(sqlPackageType.dropFirst(3)) : sqlPackageType
    }

    /// รายการนี้เป็น object ลูก (index/constraint/column) ไม่ใช่ตัว object เอง
    var isMember: Bool { memberName != nil }

    /// type นี้เป็นของลูก table เสมอ — ถ้าไม่ได้เป็น member แปลว่ายังหา table แม่ไม่เจอ
    var isChildObjectType: Bool { SchemaObjectCategory.isTableScopedType(sqlPackageType) }

    /// key ของ object แม่ — ใช้ยุบ index/constraint กลับเข้า object ที่มันสังกัดอยู่
    var objectKey: String {
        "\(category.rawValue)|\(schemaName.lowercased()).\(objectName.lowercased())"
    }

    /// ชื่อแบบไม่มีวงเล็บ ตามที่ตาราง compare แสดง เช่น `tax.TaxCalcVersionSnapshotV2`
    var plainName: String {
        schemaName.isEmpty ? objectName : "\(schemaName).\(objectName)"
    }

    /// ชื่อของ object ลูก เช่น constraint หรือ index พร้อม schema นำหน้า
    var plainMemberName: String? {
        guard let memberName else { return nil }
        if isUnnamedConstraint { return memberName }
        return schemaName.isEmpty ? memberName : "\(schemaName).\(memberName)"
    }

    init(index: Int, operationName: String, sqlPackageType: String, rawValue: String) {
        self.operationName = operationName
        self.kind = SchemaChangeKind.kind(forOperationName: operationName)
        self.sqlPackageType = sqlPackageType
        self.category = SchemaObjectCategory.category(forSqlPackageType: sqlPackageType)
        self.rawValue = rawValue
        self.id = "\(index)|\(operationName)|\(sqlPackageType)|\(rawValue)"

        let parts = SchemaDifference.splitQualifiedName(rawValue)
        let isUnnamed = SchemaDifference.isUnnamedConstraintValue(rawValue)
        let schemaName: String
        let objectName: String
        let memberName: String?

        if isUnnamed, parts.count == 2 {
            // `unnamed constraint on [schema].[table]` — ชื่อในวงเล็บคือ table แม่ ไม่ใช่ตัว constraint
            schemaName = parts[0]
            objectName = parts[1]
            memberName = SchemaDifference.unnamedConstraintLabel
        } else {
            schemaName = parts.count > 1 ? parts[0] : ""
            objectName = parts.count > 1 ? parts[1] : (parts.first ?? rawValue)
            memberName = parts.count > 2 ? parts[2] : nil
        }

        self.schemaName = schemaName
        self.objectName = objectName
        self.memberName = memberName
        self.isUnnamedConstraint = isUnnamed
    }

    private init(rehoming base: SchemaDifference, schemaName: String, objectName: String, memberName: String) {
        self.id = base.id
        self.kind = base.kind
        self.operationName = base.operationName
        self.sqlPackageType = base.sqlPackageType
        self.category = base.category
        self.rawValue = base.rawValue
        self.schemaName = schemaName
        self.objectName = objectName
        self.memberName = memberName
        self.isUnnamedConstraint = base.isUnnamedConstraint
    }

    static let unnamedConstraintLabel = "unnamed constraint"

    /// sqlpackage รายงาน constraint ที่ไม่มีชื่อเป็น `unnamed constraint on [schema].[table]`
    static func isUnnamedConstraintValue(_ value: String) -> Bool {
        value.lowercased().hasPrefix("unnamed constraint on ")
    }

    /// สำเนาที่ย้ายไปเป็น object ลูกของ `[schema].[table]` — ใช้กับ constraint ที่ sqlpackage รายงานแค่
    /// `[schema].[ConstraintName]` แล้วเราหา table แม่ได้จาก deployment script
    ///
    /// DacFx เองก็มอง constraint/index เป็นลูกของ table (difference ระดับบนมีแต่ `schema.table`)
    /// การยุบแบบนี้จึงทำให้ติ๊กในตารางตรงกับสิ่งที่ helper exclude ได้จริง
    func rehomed(underSchema schema: String, table: String) -> SchemaDifference {
        SchemaDifference(rehoming: self, schemaName: schema, objectName: table, memberName: objectName)
    }

    /// แยก `[dbo].[Order].[IX_Order_Date]` เป็น 3 ส่วน โดยเคารพ `]]` ที่เป็น escape
    static func splitQualifiedName(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var isInsideBracket = false
        let characters = Array(value)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if isInsideBracket {
                if character == "]" {
                    if index + 1 < characters.count, characters[index + 1] == "]" {
                        current.append("]")
                        index += 2
                        continue
                    }
                    isInsideBracket = false
                    parts.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            } else if character == "[" {
                isInsideBracket = true
                current = ""
            }

            index += 1
        }

        if isInsideBracket, !current.isEmpty {
            parts.append(current)
        }

        return parts.isEmpty ? [value] : parts
    }
}

/// `<Alerts>` ของ DeployReport เช่นการเตือน data loss
nonisolated struct SchemaCompareAlert: Identifiable, Hashable {
    let id: String
    let name: String
    let issues: [String]

    var title: String {
        switch name.lowercased() {
        case "dataissue", "datamotion": return "Possible Data Loss"
        case "warning": return "Warning"
        default: return name
        }
    }
}

extension SchemaChangeKind {
    /// คำในคอลัมน์ Action ของตาราง compare
    var actionTitle: String {
        switch self {
        case .create: return "Add"
        case .alter: return "Change"
        case .drop: return "Delete"
        case .rebuild: return "Rebuild"
        case .recreate: return "Drop & Create"
        case .other: return "Other"
        }
    }

    /// คำที่ใช้สรุปความต่างของ object ลูก เช่น "Constraints added"
    var memberSummaryVerb: String {
        switch self {
        case .create: return "added"
        case .alter: return "changed"
        case .drop: return "removed"
        case .rebuild: return "rebuilt"
        case .recreate: return "re-created"
        case .other: return "affected"
        }
    }
}

/// หนึ่งแถวของตาราง compare — ยุบความต่างทุกรายการของ object เดียวกันเข้าด้วยกัน
///
/// sqlpackage รายงาน index และ constraint แยกเป็นรายการของตัวเอง แต่ตาราง compare
/// แสดงเป็น object ระดับบนสุดแถวเดียว แล้วยกรายละเอียดของลูกไปไว้ใน Comparison Details
nonisolated struct SchemaCompareRow: Identifiable, Hashable {
    let id: String
    let category: SchemaObjectCategory
    let typeDisplay: String
    let schemaName: String
    let objectName: String
    let kind: SchemaChangeKind
    let representative: SchemaDifference
    let members: [SchemaDifference]

    var plainName: String { representative.plainName }

    /// ว่างไว้เมื่อ object ไม่มีอยู่ในฝั่งนั้น เหมือนตารางของ mssql extension
    var sourceName: String? { kind == .drop ? nil : plainName }
    var targetName: String? { kind == .create ? nil : plainName }

    /// บรรทัดสรุปความต่างของ object ลูก เช่น "Constraints added: tax.PK_Foo"
    var memberSummaryLines: [String] {
        var order: [String] = []
        var named: [String: [String]] = [:]
        var unnamedCounts: [String: Int] = [:]

        // constraint/index ชื่อเดิมที่ถูก drop แล้ว create ในรอบเดียว (เช่น FK ที่ต้องปลดตอน rebuild table ที่มันอ้าง)
        // สรุปเป็น "re-created" รายการเดียว แทนที่จะแยกเป็น removed กับ added
        var pairedKinds: [String: Set<SchemaChangeKind>] = [:]
        for member in members where !member.isUnnamedConstraint {
            pairedKinds[SchemaCompareRow.pairKey(for: member), default: []].insert(member.kind)
        }
        var emittedRecreates: Set<String> = []

        for member in members {
            var kind = member.kind
            if !member.isUnnamedConstraint {
                let pairKey = SchemaCompareRow.pairKey(for: member)
                if let kinds = pairedKinds[pairKey], kinds.contains(.drop), kinds.contains(.create) {
                    guard emittedRecreates.insert(pairKey).inserted else { continue }
                    kind = .recreate
                }
            }

            let key = "\(SchemaCompareRow.pluralize(SchemaCompareRow.summaryTypeName(member.typeDisplay))) \(kind.memberSummaryVerb)"
            if named[key] == nil {
                order.append(key)
                named[key] = []
            }

            // constraint ไม่มีชื่อหลายตัวในตารางเดียวกันแสดงเป็นจำนวนแทนการซ้ำคำเดิม
            if member.isUnnamedConstraint {
                unnamedCounts[key, default: 0] += 1
            } else {
                named[key, default: []].append(member.plainMemberName ?? member.plainName)
            }
        }

        return order.map { key in
            var names = named[key] ?? []
            if let count = unnamedCounts[key], count > 0 {
                names.append("\(count) unnamed")
            }
            return "\(key): \(names.joined(separator: ", "))"
        }
    }

    private static func pairKey(for member: SchemaDifference) -> String {
        "\(member.typeDisplay)|\(member.plainMemberName ?? member.plainName)".lowercased()
    }

    /// ยุบชนิดย่อยให้เหลือคำที่คนอ่านรู้เรื่อง — default/primary key/check ล้วนเป็น constraint
    static func summaryTypeName(_ typeDisplay: String) -> String {
        if typeDisplay.hasSuffix("Constraint") { return "Constraint" }
        if typeDisplay.hasSuffix("Column") { return "Column" }
        if typeDisplay.hasSuffix("Index") { return "Index" }
        if typeDisplay.hasSuffix("Trigger") { return "Trigger" }
        return typeDisplay
    }

    static func pluralize(_ value: String) -> String {
        if value.hasSuffix("x") || value.hasSuffix("s") { return value + "es" }
        if value.hasSuffix("y") { return String(value.dropLast()) + "ies" }
        return value + "s"
    }

    /// จัดกลุ่มความต่างทั้งหมดเป็นแถวระดับ object โดยคงลำดับที่ sqlpackage รายงานมา
    static func rows(from differences: [SchemaDifference]) -> [SchemaCompareRow] {
        var order: [String] = []
        var grouped: [String: [SchemaDifference]] = [:]

        for difference in differences {
            if grouped[difference.objectKey] == nil { order.append(difference.objectKey) }
            grouped[difference.objectKey, default: []].append(difference)
        }

        return order.compactMap { key -> SchemaCompareRow? in
            guard let group = grouped[key], let first = group.first else { return nil }

            // ถ้าเปลี่ยนแค่ index หรือ constraint sqlpackage จะไม่รายงาน object แม่มาด้วย
            // แถวนั้นจึงนับเป็น Change ของ object แม่ — และ constraint ที่หา table แม่ไม่เจอ
            // ต้องไม่ถูกเลือกเป็นแม่แทนตัว object จริง
            let owners = group.filter { !$0.isMember && !$0.isChildObjectType }
            let owner = owners.first ?? group.first { !$0.isMember }

            // Drop กับ Create ของ object เดียวกันในรอบเดียว = object มีทั้งสองฝั่งแต่ถูกสร้างใหม่
            // ต้องไม่หยิบรายการ Drop มาเป็นตัวแทน ไม่งั้นแถวจะกลายเป็น Delete ที่ Source Name ว่าง
            let isRecreated = owners.contains { $0.kind == .drop } && owners.contains { $0.kind == .create }
            let representative = isRecreated ? (owners.first { $0.kind == .create } ?? owner) : owner

            return SchemaCompareRow(
                id: key,
                category: first.category,
                typeDisplay: owner?.typeDisplay ?? first.category.shortTitle,
                schemaName: first.schemaName,
                objectName: first.objectName,
                kind: isRecreated ? .recreate : (owner?.kind ?? .alter),
                representative: representative ?? first,
                members: group.filter(\.isMember)
            )
        }
    }
}

/// ฝั่งหนึ่งของ schema compare มาจากไหน
nonisolated enum SchemaEndpointKind: String, CaseIterable, Identifiable, Hashable {
    case database
    case dacpac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .database: return "Database"
        case .dacpac: return "DACPAC File"
        }
    }

    var systemImage: String {
        switch self {
        case .database: return "cylinder.split.1x2"
        case .dacpac: return "doc.zipper"
        }
    }
}

/// source หรือ target ของ schema compare — database สดที่ต้อง extract ก่อน หรือไฟล์ `.dacpac` ที่มีอยู่แล้ว
nonisolated enum SchemaCompareEndpoint: Sendable {
    case database(ConnectionInput)
    case dacpac(URL)

    var kind: SchemaEndpointKind {
        switch self {
        case .database: return .database
        case .dacpac: return .dacpac
        }
    }

    /// connection ของฝั่งนี้ — `nil` เมื่อเป็นไฟล์ dacpac ซึ่ง query ด้วย sqlcmd ไม่ได้
    var connectionInput: ConnectionInput? {
        if case .database(let input) = self { return input }
        return nil
    }
}

/// ไฟล์ที่ compare รอบหนึ่งทิ้งไว้ให้ขั้นออก script ใช้ต่อ
///
/// dacpac ของฝั่งที่เป็น database ถูก extract มาไว้ใน `directory` ส่วนฝั่งที่ผู้ใช้เลือกไฟล์ `.dacpac`
/// ชี้ไปที่ไฟล์นั้นตรง ๆ — `cleanUp()` ลบแค่ `directory` จึงไม่แตะไฟล์ของผู้ใช้
nonisolated struct SchemaCompareWorkspace: Sendable {
    let directory: URL
    let sourceDacpac: URL
    let targetDacpac: URL
    /// ชื่อ database ของ target ที่ใส่ในหัว script (`Deployment script for ...` / `USE [...]`)
    let targetDatabaseName: String

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

nonisolated struct SchemaCompareReport {
    let differences: [SchemaDifference]
    let alerts: [SchemaCompareAlert]
    let script: String
    let generatedAt: Date
    let workspace: SchemaCompareWorkspace

    var isEmpty: Bool { differences.isEmpty }
}

/// รูปแบบของ script ที่แสดง/คัดลอก
nonisolated enum SchemaScriptFormat: String, CaseIterable, Identifiable, Hashable {
    /// ถอดคำสั่ง SQLCMD ออกแล้ว — วางใน query editor ธรรมดาได้เลย (VS Code mssql, ADS, SSMS)
    case plainTSQL
    /// ตามที่ DacFx สร้าง มี `:setvar` / `:on error exit` — ต้องรันด้วย `sqlcmd` หรือเปิด SQLCMD mode
    case sqlcmd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plainTSQL: return "Plain T-SQL"
        case .sqlcmd: return "SQLCMD"
        }
    }

    var help: String {
        switch self {
        case .plainTSQL:
            return "ถอด :setvar / :on error exit และ batch ตรวจ SQLCMD mode ออก แทนค่า $(DatabaseName) ให้แล้ว — วางใน query editor ธรรมดาได้"
        case .sqlcmd:
            return "script ดิบจาก DacFx — รันด้วย sqlcmd -i หรือเปิด SQLCMD mode ใน editor ก่อน ไม่งั้นจะ error ที่ :setvar"
        }
    }
}

/// script ของ object ที่เลือกมาจากทางไหน
nonisolated enum SelectedScriptSource: Equatable {
    /// DacFx exclude object ที่ไม่ได้เลือก แล้วออก script พร้อม dependency ที่จำเป็น — ทางหลัก
    case dacFx
    /// ตัด script เต็มของ sqlpackage เป็นส่วน ๆ ตามชื่อ object — ทางสำรองเมื่อ helper ใช้ไม่ได้
    case textFilter
}

/// ผลของการออก script เฉพาะ object ที่เลือก
nonisolated struct SelectedScriptResult {
    let script: String
    let source: SelectedScriptSource
    /// object ระดับบนที่อยู่ใน script จริง (รวมที่ DacFx บังคับเก็บ)
    let included: [String]
    /// object ที่ไม่ได้ติ๊กแต่ DacFx เก็บไว้เพราะ object ที่ติ๊กต้องพึ่ง
    let forcedIncluded: [DacFxForcedObject]
    let excludedCount: Int
    let differenceCount: Int
    let warnings: [String]
    /// เหตุที่ต้องถอยไปใช้ทางสำรอง (ว่างเมื่อ DacFx ทำงานได้)
    let fallbackReason: String?
    /// รายละเอียดของทางสำรอง
    let filter: DeploymentScriptFilterResult?

    var usedFallback: Bool { source == .textFilter }
}

nonisolated enum SelectedScriptState {
    case idle
    case generating(String)
    case ready(SelectedScriptResult)

    var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }

    var result: SelectedScriptResult? {
        if case .ready(let result) = self { return result }
        return nil
    }
}

/// ตัวเลือกที่แปลงตรงเป็น `/p:` ของ sqlpackage
nonisolated struct SchemaCompareOptions: Equatable {
    var selectedCategories: Set<SchemaObjectCategory> = [.table, .view, .storedProcedure, .function]
    /// รายงาน object ที่มีเฉพาะฝั่ง target ด้วย (`/p:DropObjectsNotInSource`)
    var reportObjectsOnlyInTarget = true
    var ignorePermissions = true
    var ignoreUserSettingsObjects = true
    var ignoreExtendedProperties = true
    var ignoreWhitespaceInModules = true
    var blockOnPossibleDataLoss = false

    /// object type ที่ไม่เกี่ยวกับการเทียบ schema ของ object — ตัดออกเสมอเพื่อลด noise
    static let alwaysExcludedObjectTypes = [
        "Users",
        "Logins",
        "RoleMembership",
        "ServerRoleMembership",
        "Permissions",
        "Credentials",
        "DatabaseScopedCredentials",
        "Audits",
        "DatabaseAuditSpecifications",
        "ServerAuditSpecifications",
        "Endpoints",
        "ServerTriggers",
        "LinkedServers",
        "LinkedServerLogins"
    ]

    var hasSelectedCategory: Bool {
        !selectedCategories.isEmpty
    }

    var excludedObjectTypes: [String] {
        var excluded = Self.alwaysExcludedObjectTypes

        for category in SchemaObjectCategory.allCases where !selectedCategories.contains(category) {
            excluded.append(contentsOf: category.excludableObjectTypeNames)
        }

        return excluded
    }
}

/// บรรทัดหนึ่งใน definition อยู่ฝั่งไหนบ้าง
///
/// `sourceOnly` คือบรรทัดที่ script จะเพิ่มเข้า target, `targetOnly` คือบรรทัดที่จะหายไป
nonisolated enum SchemaDiffLineKind: Hashable {
    case unchanged
    case sourceOnly
    case targetOnly
}

nonisolated struct SchemaDiffLine: Identifiable, Hashable {
    let id: Int
    let sourceNumber: Int?
    let targetNumber: Int?
    let text: String
    let kind: SchemaDiffLineKind
}

/// definition ของ object ทั้งสองฝั่ง พร้อมผล diff รายบรรทัด
/// สถานะของหนึ่งแถวในมุมมองเทียบสองฝั่ง
nonisolated enum SchemaSideBySideRowKind: Hashable {
    case unchanged
    case changed
    case sourceOnly
    case targetOnly
}

/// หนึ่งบรรทัดที่จับคู่ source กับ target ไว้แล้ว สำหรับแสดงแบบสองคอลัมน์
nonisolated struct SchemaSideBySideRow: Identifiable, Hashable {
    let id: Int
    let sourceNumber: Int?
    let sourceText: String?
    let targetNumber: Int?
    let targetText: String?
    let kind: SchemaSideBySideRowKind
}

nonisolated enum SchemaDiffViewMode: String, CaseIterable, Identifiable, Hashable {
    case sideBySide
    case unified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: return "Side by Side"
        case .unified: return "Unified"
        }
    }
}

nonisolated struct SchemaObjectDefinition {
    let sourceText: String?
    let targetText: String?
    let lines: [SchemaDiffLine]
    let sideBySideRows: [SchemaSideBySideRow]
    let isTruncated: Bool

    var changedLineCount: Int {
        lines.filter { $0.kind != .unchanged }.count
    }
}

nonisolated enum SchemaDefinitionState {
    case idle
    case loading
    case loaded(SchemaObjectDefinition)
    case failed(String)
    case unsupported(String)
}
