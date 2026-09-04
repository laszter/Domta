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
    case other

    var id: String { rawValue }

    /// ป้ายในมุมมอง schema compare — สื่อว่า "อยู่ฝั่งไหน" มากกว่าสื่อว่า sqlpackage จะทำอะไร
    var title: String {
        switch self {
        case .create: return "Only in Source"
        case .alter: return "Different"
        case .drop: return "Only in Target"
        case .rebuild: return "Rebuild"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .create: return "plus.circle.fill"
        case .alter: return "pencil.circle.fill"
        case .drop: return "minus.circle.fill"
        case .rebuild: return "arrow.triangle.2.circlepath.circle.fill"
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
        self.schemaName = parts.count > 1 ? parts[0] : ""
        self.objectName = parts.count > 1 ? parts[1] : (parts.first ?? rawValue)
        self.memberName = parts.count > 2 ? parts[2] : nil
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
        var grouped: [String: [String]] = [:]

        for member in members {
            let key = "\(SchemaCompareRow.pluralize(SchemaCompareRow.summaryTypeName(member.typeDisplay))) \(member.kind.memberSummaryVerb)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(member.plainMemberName ?? member.plainName)
        }

        return order.compactMap { key in
            guard let names = grouped[key] else { return nil }
            return "\(key): \(names.joined(separator: ", "))"
        }
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
            // แถวนั้นจึงนับเป็น Change ของ object แม่
            let owner = group.first { !$0.isMember }

            return SchemaCompareRow(
                id: key,
                category: first.category,
                typeDisplay: owner?.typeDisplay ?? first.category.shortTitle,
                schemaName: first.schemaName,
                objectName: first.objectName,
                kind: owner?.kind ?? .alter,
                representative: owner ?? first,
                members: group.filter(\.isMember)
            )
        }
    }
}

nonisolated struct SchemaCompareReport {
    let differences: [SchemaDifference]
    let alerts: [SchemaCompareAlert]
    let script: String
    let generatedAt: Date

    var isEmpty: Bool { differences.isEmpty }
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
