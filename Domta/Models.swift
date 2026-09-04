//
//  Models.swift
//  Domta
//
//  Created by Codex on 25/3/26.
//

import Foundation

/// connection string หนึ่งฝั่ง พร้อมรหัสผ่านที่ผู้ใช้กรอกแยกไว้
///
/// tool อย่าง vscode-mssql export connection string ออกมาโดยเว้น `Password=` ว่าง
/// เพราะเก็บรหัสผ่านไว้ใน Keychain ของ OS แทน — ช่อง password แยกเลยจำเป็น
struct ConnectionInput: Sendable {
    let connectionString: String
    let password: String

    init(connectionString: String, password: String = "") {
        self.connectionString = connectionString
        self.password = password
    }
}

nonisolated struct SQLConnectionConfiguration {
    let server: String
    let database: String?
    let username: String?
    let password: String?
    let trustServerCertificate: Bool
    let encrypt: Bool?
    let isIntegratedSecurity: Bool
    let authenticationMethod: String?

    /// `Authentication=` ที่ตัดช่องว่างและ case ออกแล้ว เช่น `SqlPassword` -> `sqlpassword`
    var normalizedAuthenticationMethod: String? {
        guard let authenticationMethod else { return nil }

        let normalized = authenticationMethod
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        return normalized.isEmpty ? nil : normalized
    }

    /// ไม่ระบุ `Authentication=` ให้ถือว่าเป็น SQL login ตามค่า default ของ SqlClient
    var isSQLPasswordAuthentication: Bool {
        guard let method = normalizedAuthenticationMethod else { return true }
        return method == "sqlpassword" || method == "sql"
    }

    /// server ที่ชี้มาที่เครื่องตัวเอง (docker ที่ map port ออกมา) — ใช้แยกข้อความ diagnosis
    var isLocalServer: Bool {
        let host = server
            .replacingOccurrences(of: "tcp:", with: "", options: [.caseInsensitive, .anchored])
            .split(separator: ",").first
            .map { $0.split(separator: "\\").first.map(String.init) ?? String($0) }?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""

        return ["localhost", "127.0.0.1", "::1", "0.0.0.0", "host.docker.internal"].contains(host)
    }

    /// เติมรหัสผ่านที่ผู้ใช้กรอกแยก เมื่อ connection string ไม่มี `Password=` หรือมีแต่ว่าง
    func applyingFallbackPassword(_ fallback: String) -> SQLConnectionConfiguration {
        guard password?.isEmpty != false else { return self }
        guard !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }

        return SQLConnectionConfiguration(
            server: server,
            database: database,
            username: username,
            password: fallback,
            trustServerCertificate: trustServerCertificate,
            encrypt: encrypt,
            isIntegratedSecurity: isIntegratedSecurity,
            authenticationMethod: authenticationMethod
        )
    }
}

struct MetadataRow: Decodable {
    let schemaName: String
    let tableName: String
    let columnID: Int
    let columnName: String
    let dataType: String
    let maxLength: Int
    let precisionValue: Int
    let scaleValue: Int
    let isNullable: Bool
    let isIdentity: Bool
    let isComputed: Bool
    let isPrimaryKey: Bool

    enum CodingKeys: String, CodingKey {
        case schemaName = "schema_name"
        case tableName = "table_name"
        case columnID = "column_id"
        case columnName = "column_name"
        case dataType = "data_type"
        case maxLength = "max_length"
        case precisionValue = "precision_value"
        case scaleValue = "scale_value"
        case isNullable = "is_nullable"
        case isIdentity = "is_identity"
        case isComputed = "is_computed"
        case isPrimaryKey = "is_primary_key"
    }
}

struct ConnectionInfoRow {
    let serverName: String
    let databaseName: String
    let loginName: String
    let systemUserName: String
}

struct TableColumn: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let ordinal: Int
    let dataType: String
    let maxLength: Int
    let precision: Int
    let scale: Int
    let isNullable: Bool
    let isIdentity: Bool
    let isComputed: Bool
    let isPrimaryKey: Bool

    var comparisonSignature: String {
        [
            name.lowercased(),
            dataType.lowercased(),
            "\(maxLength)",
            "\(precision)",
            "\(scale)",
            isNullable ? "1" : "0",
            isIdentity ? "1" : "0",
            isComputed ? "1" : "0",
            isPrimaryKey ? "1" : "0"
        ].joined(separator: "|")
    }

    var isScriptWritable: Bool {
        !isComputed && !["timestamp", "rowversion"].contains(dataType.lowercased())
    }

    var isComparable: Bool {
        !isComputed && !["timestamp", "rowversion"].contains(dataType.lowercased())
    }
}

struct TableSchema: Identifiable, Hashable {
    let schemaName: String
    let tableName: String
    let columns: [TableColumn]

    var id: String { "\(schemaName).\(tableName)" }
    var displayName: String { "[\(schemaName)].[\(tableName)]" }

    var primaryKeyColumns: [TableColumn] {
        columns.filter(\.isPrimaryKey).sorted { $0.ordinal < $1.ordinal }
    }

    var comparableColumns: [TableColumn] {
        columns.filter(\.isComparable).sorted { $0.ordinal < $1.ordinal }
    }

    var insertableColumns: [TableColumn] {
        columns.filter(\.isScriptWritable).sorted { $0.ordinal < $1.ordinal }
    }

    var updatableColumns: [TableColumn] {
        columns
            .filter { $0.isScriptWritable && !$0.isPrimaryKey && !$0.isIdentity }
            .sorted { $0.ordinal < $1.ordinal }
    }

    var hasIdentityColumn: Bool {
        insertableColumns.contains(where: \.isIdentity)
    }
}

struct ComparableTable: Identifiable {
    let schema: TableSchema

    var id: String { schema.id }
    var displayName: String { schema.displayName }
    var columns: [TableColumn] { schema.columns }
    var primaryKeyDisplay: String { schema.primaryKeyColumns.map(\.name).joined(separator: ", ") }
    var columnSummary: String { schema.columns.map { "\($0.name):\($0.dataType)" }.joined(separator: " | ") }
}

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var displayString: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return NumberFormatter.domtaNumber.string(from: NSNumber(value: value)) ?? String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object(let value):
            let body = value.keys.sorted().compactMap { key in
                value[key].map { "\(key):\($0.displayString)" }
            }.joined(separator: ", ")
            return "{\(body)}"
        case .array(let value):
            return "[" + value.map(\.displayString).joined(separator: ", ") + "]"
        case .null:
            return "NULL"
        }
    }
}

struct TableDiff {
    let sourceRowCount: Int
    let targetRowCount: Int
    let inserts: [RowPair]
    let updates: [RowPair]
    let deletes: [RowPair]
}

struct RowPair: Identifiable {
    let id = UUID()
    let key: String
    let source: [String: JSONValue]?
    let target: [String: JSONValue]?
}

enum SampleKind: String {
    case insert
    case update
    case delete

    var label: String {
        switch self {
        case .insert: return "Insert"
        case .update: return "Update"
        case .delete: return "Delete"
        }
    }
}

struct DiffSample: Identifiable {
    let id = UUID()
    let kind: SampleKind
    let keyDisplay: String
    let summary: String
}

struct TableCompareResult: Identifiable {
    let id = UUID()
    let tableName: String
    let comparableColumns: [TableColumn]
    let sourceRowCount: Int
    let targetRowCount: Int
    let insertCount: Int
    let updateCount: Int
    let deleteCount: Int
    let inserts: [RowPair]
    let updates: [RowPair]
    let deletes: [RowPair]
    let samples: [DiffSample]

    func rowPairs(for kind: SampleKind) -> [RowPair] {
        switch kind {
        case .insert:
            return inserts
        case .update:
            return updates
        case .delete:
            return deletes
        }
    }

    var totalDiffCount: Int {
        insertCount + updateCount + deleteCount
    }
}

struct ConnectionTestResult {
    let title: String
    let isSuccess: Bool
    let details: String
}

struct RecentConnectionPair: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceConnectionString: String
    let targetConnectionString: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceConnectionString: String,
        targetConnectionString: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceConnectionString = sourceConnectionString
        self.targetConnectionString = targetConnectionString
        self.createdAt = createdAt
    }

    var displayName: String {
        let sourceLabel = Self.label(for: sourceConnectionString)
        let targetLabel = Self.label(for: targetConnectionString)
        return "\(sourceLabel) -> \(targetLabel)"
    }

    var detailText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Used " + formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    private static func label(for connectionString: String) -> String {
        guard let config = try? ConnectionStringParser.parse(connectionString) else {
            return "Unknown"
        }

        let database = config.database ?? "(no db)"
        return "\(config.server) / \(database)"
    }
}

nonisolated struct ProgressState {
    let message: String
    let completedUnitCount: Int
    let totalUnitCount: Int
    let showsIndeterminateSpinner: Bool

    var fractionCompleted: Double? {
        guard totalUnitCount > 0 else { return nil }
        return Double(completedUnitCount) / Double(totalUnitCount)
    }
}

enum CompareAppError: LocalizedError {
    case invalidConnectionString(String)
    case missingUserID
    case missingPassword
    case integratedSecurityUnsupported
    case unsupportedAuthenticationMethod(String)
    case sqlcmdNotFound
    case sqlPackageNotFound
    case sqlPackageFailed(String)
    case operationCancelled
    case placeholderPassword
    case queryFailed(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidConnectionString(let message):
            return "Connection string ไม่ถูกต้อง: \(message)"
        case .missingUserID:
            return "Connection string ไม่มี `User ID` — Domta รองรับเฉพาะ SQL login"
        case .missingPassword:
            return """
            ยังไม่มีรหัสผ่านสำหรับ connection นี้

            ใส่รหัสผ่านในช่อง Password ใต้ connection string หรือเติม `Password=...` ลงใน connection string โดยตรง
            (vscode-mssql จะ export connection string โดยเว้น `Password=` ว่างเสมอ เพราะเก็บรหัสผ่านไว้ใน Keychain)
            """
        case .integratedSecurityUnsupported:
            return "`Integrated Security` / `Trusted_Connection` ใช้บน macOS ไม่ได้ — ต้องใช้ SQL login (User ID + Password)"
        case .unsupportedAuthenticationMethod(let method):
            return "`Authentication=\(method)` ยังไม่รองรับ — ตอนนี้รองรับเฉพาะ SQL login (`SqlPassword`)"
        case .sqlcmdNotFound:
            return "ไม่พบ `sqlcmd` ในเครื่อง กรุณาติดตั้ง Microsoft sqlcmd ก่อนใช้งาน"
        case .sqlPackageNotFound:
            return """
            ไม่พบ `sqlpackage` ในเครื่อง — โหมด Schema Compare ต้องใช้ sqlpackage

            ติดตั้งด้วย .NET SDK:
                dotnet tool install --global microsoft.sqlpackage

            แล้วตรวจว่า `~/.dotnet/tools` อยู่ใน PATH หรือวางไบนารีไว้ที่ /usr/local/bin/sqlpackage
            """
        case .sqlPackageFailed(let message):
            return "sqlpackage ทำงานไม่สำเร็จ: \(message)"
        case .operationCancelled:
            return "ยกเลิกการทำงานแล้ว"
        case .placeholderPassword:
            return "กรุณาใส่รหัสผ่านจริง ไม่ใช่ค่า placeholder เช่น `<password>`"
        case .queryFailed(let message):
            return "Query failed: \(message)"
        case .invalidJSON(let message):
            return "อ่านผลลัพธ์จาก SQL ไม่สำเร็จ: \(message)"
        }
    }
}

extension NumberFormatter {
    static let domtaNumber: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 16
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        return formatter
    }()
}
