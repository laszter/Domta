//
//  DeployReportParser.swift
//  Domta
//

import Foundation

/// อ่าน deployment report XML ที่ `sqlpackage /DeployReportPath:` เขียนออกมา
///
/// โครงสร้างที่สนใจ:
/// ```xml
/// <DeploymentReport>
///   <Alerts><Alert Name="DataIssue"><Issue Value="[dbo].[T]" /></Alert></Alerts>
///   <Operations><Operation Name="Alter"><Item Value="[dbo].[P]" Type="SqlProcedure" /></Operation></Operations>
/// </DeploymentReport>
/// ```
nonisolated enum DeployReportParser {
    struct Output {
        let differences: [SchemaDifference]
        let alerts: [SchemaCompareAlert]
    }

    static func parse(contentsOf url: URL) throws -> Output {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CompareAppError.sqlPackageFailed("sqlpackage ไม่ได้สร้าง deployment report ออกมา")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CompareAppError.sqlPackageFailed("อ่าน deployment report ไม่สำเร็จ: \(error.localizedDescription)")
        }

        return try parse(data: data)
    }

    static func parse(data: Data) throws -> Output {
        let delegate = ReportDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "รูปแบบ XML ไม่ถูกต้อง"
            throw CompareAppError.sqlPackageFailed("อ่าน deployment report ไม่สำเร็จ: \(reason)")
        }

        return Output(differences: delegate.differences, alerts: delegate.alerts)
    }
}

private nonisolated final class ReportDelegate: NSObject, XMLParserDelegate {
    private(set) var differences: [SchemaDifference] = []
    private(set) var alerts: [SchemaCompareAlert] = []

    private var currentOperationName: String?
    private var currentAlertName: String?
    private var currentAlertIssues: [String] = []
    private var itemIndex = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch localName(of: elementName) {
        case "Operation":
            currentOperationName = attributeDict["Name"] ?? "Unknown"

        case "Item":
            guard let operationName = currentOperationName else { return }
            guard let value = attributeDict["Value"], !value.isEmpty else { return }

            differences.append(
                SchemaDifference(
                    index: itemIndex,
                    operationName: operationName,
                    sqlPackageType: attributeDict["Type"] ?? "Unknown",
                    rawValue: value
                )
            )
            itemIndex += 1

        case "Alert":
            currentAlertName = attributeDict["Name"] ?? "Alert"
            currentAlertIssues = []

        case "Issue":
            if let value = attributeDict["Value"], !value.isEmpty {
                currentAlertIssues.append(value)
            }

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(of: elementName) {
        case "Operation":
            currentOperationName = nil

        case "Alert":
            if let name = currentAlertName {
                alerts.append(
                    SchemaCompareAlert(id: "\(alerts.count)|\(name)", name: name, issues: currentAlertIssues)
                )
            }
            currentAlertName = nil
            currentAlertIssues = []

        default:
            break
        }
    }

    /// รองรับกรณี parser คืนชื่อแบบมี prefix มาให้ (`ns:Operation`)
    private func localName(of elementName: String) -> String {
        guard let separator = elementName.lastIndex(of: ":") else { return elementName }
        return String(elementName[elementName.index(after: separator)...])
    }
}

extension DeployReportParser {
    /// ย้าย constraint ที่ report ระบุแค่ `[schema].[ConstraintName]` (FK / default / check) ไปเป็น object ลูก
    /// ของ table แม่ โดยหา table จาก `ALTER TABLE` ใน deployment script ที่ sqlpackage ออกมาคู่กัน
    ///
    /// รายการที่หา table ไม่เจอคงไว้ตามเดิม — โผล่เป็นแถวของตัวเองในตารางเหมือนก่อน
    static func resolvingParents(of differences: [SchemaDifference], script: String) -> [SchemaDifference] {
        let owners = ConstraintOwnerIndex(script: script)
        guard !owners.isEmpty else { return differences }

        return differences.map { difference in
            guard difference.isChildObjectType, !difference.isMember,
                  let owner = owners.owner(ofConstraintInSchema: difference.schemaName, named: difference.objectName)
            else { return difference }

            return difference.rehomed(underSchema: owner.schema, table: owner.table)
        }
    }
}

/// ตาราง constraint → table แม่ ที่อ่านจาก `ALTER TABLE ... ADD|DROP CONSTRAINT` ใน deployment script
///
/// ชื่อ constraint ไม่ซ้ำกันภายใน schema (SQL Server เก็บเป็น schema-scoped object)
/// จึงใช้ `schema.constraint` ชี้ table ได้ตัวเดียว
nonisolated struct ConstraintOwnerIndex {
    struct Owner: Equatable {
        let schema: String
        let table: String
    }

    private var owners: [String: Owner] = [:]

    /// `ALTER TABLE [s].[t] [WITH CHECK|NOCHECK] ADD|DROP|CHECK|NOCHECK CONSTRAINT [name]` — ชื่อในวงเล็บรองรับ `]]`
    private static let pattern =
        #"ALTER\s+TABLE\s+\[((?:[^\]]|\]\])+)\]\.\[((?:[^\]]|\]\])+)\]\s+(?:WITH\s+(?:NO)?CHECK\s+)?(?:ADD|DROP|CHECK|NOCHECK)\s+CONSTRAINT\s+\[((?:[^\]]|\]\])+)\]"#

    init(script: String) {
        guard !script.isEmpty,
              let regex = try? NSRegularExpression(pattern: Self.pattern, options: [.caseInsensitive]) else { return }

        let range = NSRange(script.startIndex..., in: script)
        for match in regex.matches(in: script, options: [], range: range) {
            guard let schema = Self.capture(1, in: match, of: script),
                  let table = Self.capture(2, in: match, of: script),
                  let constraint = Self.capture(3, in: match, of: script) else { continue }

            owners[Self.key(schema: schema, name: constraint)] = Owner(schema: schema, table: table)
        }
    }

    var isEmpty: Bool { owners.isEmpty }

    func owner(ofConstraintInSchema schema: String, named name: String) -> Owner? {
        owners[Self.key(schema: schema, name: name)]
    }

    private static func key(schema: String, name: String) -> String {
        "\(schema.lowercased()).\(name.lowercased())"
    }

    private static func capture(_ index: Int, in match: NSTextCheckingResult, of text: String) -> String? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range]).replacingOccurrences(of: "]]", with: "]")
    }
}
