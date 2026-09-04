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
