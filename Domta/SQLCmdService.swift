//
//  SQLCmdService.swift
//  Domta
//
//  Created by Codex on 25/3/26.
//

import Foundation

struct SQLCmdService: Sendable {
    nonisolated func testConnection(_ input: ConnectionInput, label: String) throws -> ConnectionTestResult {
        let configuration = try validatedConfiguration(from: input)
        let rows = try runDelimitedQuery(
            """
            SET NOCOUNT ON;
            SELECT
                COALESCE(CONVERT(nvarchar(max), @@SERVERNAME), N''),
                COALESCE(CONVERT(nvarchar(max), DB_NAME()), N''),
                COALESCE(CONVERT(nvarchar(max), SUSER_SNAME()), N''),
                COALESCE(CONVERT(nvarchar(max), SYSTEM_USER), N'');
            """,
            configuration: configuration,
            expectedColumnCount: 4
        )

        let firstRow = rows.first
        let serverName = firstRow?[safe: 0].flatMap(emptyToNil) ?? configuration.server
        let databaseName = firstRow?[safe: 1].flatMap(emptyToNil) ?? configuration.database ?? "(unknown)"
        let loginName = firstRow?[safe: 2].flatMap(emptyToNil) ?? configuration.username ?? "(unknown)"

        return ConnectionTestResult(
            title: label,
            isSuccess: true,
            details: "Connected to \(serverName) / \(databaseName) as \(loginName)"
        )
    }

    nonisolated func loadSchemas(
        source: ConnectionInput,
        target: ConnectionInput,
        progress: (@Sendable (ProgressState) -> Void)? = nil
    ) throws -> [ComparableTable] {
        let sourceConfig = try validatedConfiguration(from: source)
        let targetConfig = try validatedConfiguration(from: target)

        progress?(ProgressState(message: "Loading source schema...", completedUnitCount: 0, totalUnitCount: 4, showsIndeterminateSpinner: true))
        let sourceRows = try runMetadataQuery(configuration: sourceConfig)
        progress?(ProgressState(message: "Loading target schema...", completedUnitCount: 1, totalUnitCount: 4, showsIndeterminateSpinner: true))
        let targetRows = try runMetadataQuery(configuration: targetConfig)

        let sourceSchemas = buildSchemas(from: sourceRows)
        let targetSchemas = buildSchemas(from: targetRows)

        let keys = sourceSchemas.keys.sorted()
        var comparableTables: [ComparableTable] = []
        let progressTotal = max(keys.count, 1)

        for (index, key) in keys.enumerated() {
            guard let left = sourceSchemas[key], let right = targetSchemas[key] else { continue }
            guard schemasMatch(left, right) else { continue }
            guard !left.primaryKeyColumns.isEmpty,
                  left.primaryKeyColumns.map({ $0.name.lowercased() }) == right.primaryKeyColumns.map({ $0.name.lowercased() }) else {
                continue
            }

            comparableTables.append(ComparableTable(schema: left))

            if index.isMultiple(of: 25) || index == keys.count - 1 {
                progress?(
                    ProgressState(
                        message: "Matching tables... \(index + 1)/\(keys.count)",
                        completedUnitCount: index + 1,
                        totalUnitCount: progressTotal,
                        showsIndeterminateSpinner: false
                    )
                )
            }
        }

        progress?(ProgressState(message: "Matched \(comparableTables.count) tables", completedUnitCount: 4, totalUnitCount: 4, showsIndeterminateSpinner: false))
        return comparableTables
    }

    nonisolated func compareTables(
        source: ConnectionInput,
        target: ConnectionInput,
        schemas: [TableSchema],
        progress: (@Sendable (ProgressState) -> Void)? = nil
    ) throws -> (results: [TableCompareResult], script: String) {
        let sourceConfig = try validatedConfiguration(from: source)
        let targetConfig = try validatedConfiguration(from: target)

        var results: [TableCompareResult] = []
        var scripts: [String] = []

        for (index, schema) in schemas.enumerated() {
            progress?(
                ProgressState(
                    message: "Comparing \(schema.displayName) (\(index + 1)/\(schemas.count))",
                    completedUnitCount: index,
                    totalUnitCount: schemas.count,
                    showsIndeterminateSpinner: false
                )
            )
            let sourceRows = try runTableDataRows(schema: schema, configuration: sourceConfig)
            let targetRows = try runTableDataRows(schema: schema, configuration: targetConfig)

            let diff = CompareEngine.diff(sourceRows: sourceRows, targetRows: targetRows, schema: schema)
            results.append(CompareEngine.makeResult(diff: diff, schema: schema))
            scripts.append(ScriptGenerator.makeScript(diff: diff, schema: schema))
        }

        progress?(ProgressState(message: "Compare complete", completedUnitCount: schemas.count, totalUnitCount: schemas.count, showsIndeterminateSpinner: false))

        let script = scripts
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return (results.sorted { $0.tableName < $1.tableName }, ScriptGenerator.wrapScriptBody(script))
    }

    private nonisolated func validatedConfiguration(from input: ConnectionInput) throws -> SQLConnectionConfiguration {
        let configuration = try ConnectionStringParser.validatedConfiguration(from: input)

        guard resolvedSQLCmdURL() != nil else {
            throw CompareAppError.sqlcmdNotFound
        }

        return configuration
    }

    private nonisolated func buildSchemas(from rows: [MetadataRow]) -> [String: TableSchema] {
        let grouped = Dictionary(grouping: rows) { "\($0.schemaName.lowercased()).\($0.tableName.lowercased())" }

        return grouped.reduce(into: [String: TableSchema]()) { partialResult, item in
            let ordered = item.value.sorted { $0.columnID < $1.columnID }
            guard let first = ordered.first else { return }

            let columns = ordered.map {
                TableColumn(
                    name: $0.columnName,
                    ordinal: $0.columnID,
                    dataType: $0.dataType,
                    maxLength: $0.maxLength,
                    precision: $0.precisionValue,
                    scale: $0.scaleValue,
                    isNullable: $0.isNullable,
                    isIdentity: $0.isIdentity,
                    isComputed: $0.isComputed,
                    isPrimaryKey: $0.isPrimaryKey
                )
            }

            partialResult[item.key] = TableSchema(schemaName: first.schemaName, tableName: first.tableName, columns: columns)
        }
    }

    private nonisolated func schemasMatch(_ left: TableSchema, _ right: TableSchema) -> Bool {
        guard left.columns.count == right.columns.count else { return false }

        let leftSignature = left.columns.sorted { $0.ordinal < $1.ordinal }.map(\.comparisonSignature)
        let rightSignature = right.columns.sorted { $0.ordinal < $1.ordinal }.map(\.comparisonSignature)

        return leftSignature == rightSignature
    }

    private nonisolated func runMetadataQuery(configuration: SQLConnectionConfiguration) throws -> [MetadataRow] {
        let rows = try runDelimitedQuery(
            MetadataQuery.schemaRowset,
            configuration: configuration,
            expectedColumnCount: 12
        )

        return try rows.map { row in
            guard row.count >= 12 else {
                throw CompareAppError.invalidJSON("schema row มี column ไม่ครบ")
            }

            return MetadataRow(
                schemaName: row[0],
                tableName: row[1],
                columnID: try parseInt(row[2], field: "column_id"),
                columnName: row[3],
                dataType: row[4],
                maxLength: try parseInt(row[5], field: "max_length"),
                precisionValue: try parseInt(row[6], field: "precision_value"),
                scaleValue: try parseInt(row[7], field: "scale_value"),
                isNullable: parseBoolFlag(row[8]),
                isIdentity: parseBoolFlag(row[9]),
                isComputed: parseBoolFlag(row[10]),
                isPrimaryKey: parseBoolFlag(row[11])
            )
        }
    }

    private nonisolated func runTableDataRows(schema: TableSchema, configuration: SQLConnectionConfiguration) throws -> [[String: JSONValue]] {
        let columns = schema.comparableColumns.sorted { $0.ordinal < $1.ordinal }
        let rows = try runDelimitedQuery(
            MetadataQuery.dataRowset(for: schema),
            configuration: configuration,
            expectedColumnCount: columns.count
        )

        return try rows.map { row in
            var decoded: [String: JSONValue] = [:]

            for (index, column) in columns.enumerated() {
                let rawValue = index < row.count ? row[index] : MetadataQuery.nullToken
                decoded[column.name] = try decodeRowValue(rawValue, for: column)
            }

            return decoded
        }
    }

    private nonisolated func runJSONQuery<T: Decodable>(_ query: String, configuration: SQLConnectionConfiguration) throws -> T {
        let output = try runRawQuery(query, configuration: configuration)
        let jsonPayload = normalizedJSONPayload(from: output)

        guard let data = jsonPayload.data(using: .utf8) else {
            throw CompareAppError.invalidJSON("ไม่สามารถแปลงผลลัพธ์เป็น UTF-8 ได้")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let snippet = String(jsonPayload.prefix(500))
            throw CompareAppError.invalidJSON("\(error.localizedDescription)\n\nRaw payload:\n\(snippet)")
        }
    }

    private nonisolated func runRawQuery(_ query: String, configuration: SQLConnectionConfiguration) throws -> String {
        try runRawQuery(query, configuration: configuration, additionalArguments: [])
    }

    private nonisolated func runRawQuery(_ query: String, configuration: SQLConnectionConfiguration, additionalArguments: [String]) throws -> String {
        guard let sqlcmdURL = resolvedSQLCmdURL() else {
            throw CompareAppError.sqlcmdNotFound
        }

        let process = Process()
        process.executableURL = sqlcmdURL

        var arguments = [
            "-S", configuration.server,
            "-h", "-1",
            "-W",
            "-w", "65535",
            "-y", "0",
            "-Y", "0",
            "-Q", query
        ]

        arguments.append(contentsOf: additionalArguments)

        if let database = configuration.database, !database.isEmpty {
            arguments += ["-d", database]
        }

        if let username = configuration.username {
            arguments += ["-U", username]
        }

        let shouldEncrypt = configuration.encrypt ?? configuration.server.lowercased().contains(".database.windows.net")
        if shouldEncrypt {
            arguments += ["-N", "true"]
        }

        if configuration.trustServerCertificate {
            arguments.append("-C")
        }

        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["SQLCMDPASSWORD"] = configuration.password
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var stdoutData = Data()
        var stderrData = Data()
        let stdoutLock = NSLock()
        let stderrLock = NSLock()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutLock.lock()
            stdoutData.append(chunk)
            stdoutLock.unlock()
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrLock.lock()
            stderrData.append(chunk)
            stderrLock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw CompareAppError.queryFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let remainingStdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutLock.lock()
            stdoutData.append(remainingStdout)
            stdoutLock.unlock()
        }

        let remainingStderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrLock.lock()
            stderrData.append(remainingStderr)
            stderrLock.unlock()
        }

        stdoutLock.lock()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        stdoutLock.unlock()

        stderrLock.lock()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        stderrLock.unlock()

        guard process.terminationStatus == 0 else {
            throw CompareAppError.queryFailed(diagnoseQueryError(stderr.isEmpty ? stdout : stderr, configuration: configuration))
        }

        return stdout
    }

    private nonisolated func runDelimitedQuery(_ query: String, configuration: SQLConnectionConfiguration, expectedColumnCount: Int) throws -> [[String]] {
        let output = try runRawQuery(
            query,
            configuration: configuration,
            additionalArguments: ["-s", "\u{001F}"]
        )

        let lines = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("(") }

        return lines.map { line in
            let fields = line.components(separatedBy: "\u{001F}")
            if fields.count < expectedColumnCount {
                return fields + Array(repeating: "", count: expectedColumnCount - fields.count)
            }
            return Array(fields.prefix(expectedColumnCount))
        }
    }

    /// sqlcmd พิมพ์ error บรรทัดเดิมซ้ำทุกครั้งที่ retry — ยุบให้เหลือบรรทัดละครั้ง
    private nonisolated func collapsingRepeatedLines(_ rawMessage: String) -> String {
        var seen: Set<String> = []

        return rawMessage
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let key = line.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return true }
                return seen.insert(key).inserted
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func diagnoseQueryError(_ rawMessage: String, configuration: SQLConnectionConfiguration) -> String {
        let message = collapsingRepeatedLines(rawMessage)
        let lowered = message.lowercased()

        if lowered.contains("login failed for user") {
            return """
            \(message)

            Diagnosis:
            - SQL login หรือ password ไม่ถูกต้อง
            - หรือ Azure SQL server นี้เปิด Entra-only authentication อยู่
            - หรือ login `\(configuration.username ?? "(unknown)")` ไม่มีสิทธิ์ใน server/database นี้
            """
        }

        if lowered.contains("certificate")
            || lowered.contains("x509")
            || lowered.contains("tls handshake")
            || lowered.contains("ssl provider") {
            return """
            \(message)

            Diagnosis:
            - SQL Server ฝั่งนี้ใช้ self-signed certificate (ค่าปกติของ container และเครื่อง local)
            - เพิ่ม `Trust Server Certificate=True` ใน connection string
            - หรือถ้าไม่ต้องการ TLS ให้ตั้ง `Encrypt=False`
            """
        }

        if lowered.contains("cannot open database") {
            return """
            \(message)

            Diagnosis:
            - login ผ่านแล้ว แต่ไม่มีสิทธิ์เข้า database `\(configuration.database ?? "(unknown)")`
            - หรือชื่อ database ไม่ถูกต้อง
            """
        }

        if lowered.contains("client with ip address")
            || lowered.contains("firewall")
            || lowered.contains("server was not found")
            || lowered.contains("tcp provider")
            || lowered.contains("connection refused")
            || lowered.contains("unable to open tcp connection") {
            if configuration.isLocalServer {
                return """
                \(message)

                Diagnosis:
                - container ของ SQL Server ยังไม่ได้รัน (`docker ps` เพื่อตรวจ)
                - หรือยังไม่ได้ map port ออกมาที่เครื่อง (`-p 1433:1433`)
                - หรือ port ใน `\(configuration.server)` ไม่ตรงกับที่ container map ไว้
                """
            }

            return """
            \(message)

            Diagnosis:
            - firewall/network ของ Azure SQL ยังไม่อนุญาตเครื่องนี้
            - หรือ server name / port ไม่ถูกต้อง
            """
        }

        return message
    }

    private nonisolated func normalizedJSONPayload(from output: String) -> String {
        let trimmed = output
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return "[]"
        }

        if let arrayStart = trimmed.firstIndex(of: "["),
           let arrayEnd = trimmed.lastIndex(of: "]"),
           arrayStart <= arrayEnd {
            return String(trimmed[arrayStart...arrayEnd])
        }

        if trimmed.hasPrefix("{") {
            let normalized = "[" + trimmed + "]"
            if normalized.contains("},{") || normalized.contains("{\"") {
                return normalized
            }
        }

        if let objectStart = trimmed.firstIndex(of: "{"),
           let objectEnd = trimmed.lastIndex(of: "}"),
           objectStart <= objectEnd {
            return "[" + String(trimmed[objectStart...objectEnd]) + "]"
        }

        return trimmed
    }

    private nonisolated func resolvedSQLCmdURL() -> URL? {
        let fileManager = FileManager.default
        let pathVariable = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidatePaths = pathVariable
            .split(separator: ":")
            .map { String($0) + "/sqlcmd" } + [
                "/opt/homebrew/bin/sqlcmd",
                "/usr/local/bin/sqlcmd",
                "/usr/bin/sqlcmd"
            ]

        for candidate in candidatePaths {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    private nonisolated func parseInt(_ raw: String, field: String) throws -> Int {
        guard let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CompareAppError.invalidJSON("ค่า \(field) ไม่ใช่ตัวเลข: \(raw)")
        }
        return value
    }

    private nonisolated func parseBoolFlag(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "1" || normalized == "true"
    }

    private nonisolated func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated func decodeRowValue(_ raw: String, for column: TableColumn) throws -> JSONValue {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized == MetadataQuery.nullToken {
            return .null
        }

        if MetadataQuery.isBinaryType(column.dataType) {
            return .string(normalized)
        }

        return .string(unescapeRowValue(normalized))
    }

    private nonisolated func unescapeRowValue(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()

        while let character = iterator.next() {
            if character == "\\" {
                guard let next = iterator.next() else {
                    result.append(character)
                    continue
                }

                switch next {
                case "\\":
                    result.append("\\")
                case "n":
                    result.append("\n")
                case "r":
                    result.append("\r")
                case "u":
                    guard iterator.next() == "{",
                          let scalar1 = iterator.next(),
                          let scalar2 = iterator.next(),
                          let closing = iterator.next(),
                          closing == "}" else {
                        result.append("\\u")
                        continue
                    }

                    let hex = String([scalar1, scalar2])
                    if let scalarValue = UInt32(hex, radix: 16), let scalar = UnicodeScalar(scalarValue) {
                        result.append(Character(scalar))
                    }
                default:
                    result.append(next)
                }
            } else {
                result.append(character)
            }
        }

        return result
    }
}

nonisolated enum MetadataQuery {
    static let nullToken = "__DOMTA_NULL__"

    /// ครอบค่าที่ส่งกลับมาทีละชิ้น เพื่อกันไม่ให้ sqlcmd ตัดช่องว่างหัวท้ายทิ้ง
    /// และเพื่อแยกบรรทัดผลลัพธ์จริงออกจากบรรทัดอื่นที่ sqlcmd พิมพ์แทรกมา
    static let chunkMarker = "|"

    static let schema = """
    SET NOCOUNT ON;
    SELECT
        s.name AS schema_name,
        t.name AS table_name,
        c.column_id AS column_id,
        c.name AS column_name,
        ty.name AS data_type,
        c.max_length AS max_length,
        c.precision AS precision_value,
        c.scale AS scale_value,
        c.is_nullable AS is_nullable,
        c.is_identity AS is_identity,
        c.is_computed AS is_computed,
        CASE WHEN pk.column_id IS NULL THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END AS is_primary_key
    FROM sys.tables t
    INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
    INNER JOIN sys.columns c ON c.object_id = t.object_id
    INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    LEFT JOIN (
        SELECT ic.object_id, ic.column_id
        FROM sys.indexes i
        INNER JOIN sys.index_columns ic
            ON ic.object_id = i.object_id
            AND ic.index_id = i.index_id
        WHERE i.is_primary_key = 1
    ) pk
        ON pk.object_id = c.object_id
        AND pk.column_id = c.column_id
    WHERE t.is_ms_shipped = 0
    ORDER BY s.name, t.name, c.column_id
    FOR JSON PATH, INCLUDE_NULL_VALUES;
    """

    static let schemaRowset = """
    SET NOCOUNT ON;
    SELECT
        COALESCE(CONVERT(nvarchar(max), s.name), N''),
        COALESCE(CONVERT(nvarchar(max), t.name), N''),
        COALESCE(CONVERT(nvarchar(max), c.column_id), N'0'),
        COALESCE(CONVERT(nvarchar(max), c.name), N''),
        COALESCE(CONVERT(nvarchar(max), ty.name), N''),
        COALESCE(CONVERT(nvarchar(max), c.max_length), N'0'),
        COALESCE(CONVERT(nvarchar(max), c.precision), N'0'),
        COALESCE(CONVERT(nvarchar(max), c.scale), N'0'),
        COALESCE(CONVERT(nvarchar(max), CASE WHEN c.is_nullable = 1 THEN 1 ELSE 0 END), N'0'),
        COALESCE(CONVERT(nvarchar(max), CASE WHEN c.is_identity = 1 THEN 1 ELSE 0 END), N'0'),
        COALESCE(CONVERT(nvarchar(max), CASE WHEN c.is_computed = 1 THEN 1 ELSE 0 END), N'0'),
        COALESCE(CONVERT(nvarchar(max), CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END), N'0')
    FROM sys.tables t
    INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
    INNER JOIN sys.columns c ON c.object_id = t.object_id
    INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    LEFT JOIN (
        SELECT ic.object_id, ic.column_id
        FROM sys.indexes i
        INNER JOIN sys.index_columns ic
            ON ic.object_id = i.object_id
            AND ic.index_id = i.index_id
        WHERE i.is_primary_key = 1
    ) pk
        ON pk.object_id = c.object_id
        AND pk.column_id = c.column_id
    WHERE t.is_ms_shipped = 0
    ORDER BY s.name, t.name, c.column_id;
    """

    static func dataRowset(for schema: TableSchema) -> String {
        let columnList = schema.comparableColumns
            .sorted { $0.ordinal < $1.ordinal }
            .map { dataSelectExpression(for: $0) }
            .joined(separator: ",\n        ")

        let orderBy = schema.primaryKeyColumns
            .sorted { $0.ordinal < $1.ordinal }
            .map { quoteIdentifier($0.name) }
            .joined(separator: ", ")

        return """
        SET NOCOUNT ON;
        SELECT
        \(columnList)
        FROM \(qualifiedName(for: schema))
        ORDER BY \(orderBy);
        """
    }

    static func dataSelectExpression(for column: TableColumn) -> String {
        let identifier = quoteIdentifier(column.name)
        let dataType = column.dataType.lowercased()

        if isBinaryType(dataType) {
            return "CASE WHEN \(identifier) IS NULL THEN N'\(nullToken)' ELSE master.dbo.fn_varbintohexstr(CONVERT(varbinary(max), \(identifier))) END AS \(identifier)"
        }

        let canonicalValueExpression = canonicalStringExpression(for: column)
        let escapedExpression = escapedStringExpression(for: canonicalValueExpression)
        return "CASE WHEN \(identifier) IS NULL THEN N'\(nullToken)' ELSE \(escapedExpression) END AS \(identifier)"
    }

    static func canonicalStringExpression(for column: TableColumn) -> String {
        let identifier = quoteIdentifier(column.name)
        let dataType = column.dataType.lowercased()

        switch dataType {
        case "date":
            return "CONVERT(nvarchar(max), \(identifier), 23)"
        case "datetime", "smalldatetime", "datetime2":
            return "CONVERT(nvarchar(max), \(identifier), 126)"
        case "datetimeoffset":
            return "CONVERT(nvarchar(max), \(identifier), 127)"
        case "time":
            return "CONVERT(nvarchar(max), \(identifier), 114)"
        case "xml":
            return "CONVERT(nvarchar(max), \(identifier))"
        default:
            return "CONVERT(nvarchar(max), \(identifier))"
        }
    }

    static func escapedStringExpression(for expression: String) -> String {
        """
        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(\(expression), N'\\', N'\\\\'),
                    NCHAR(31), N'\\u{1F}'
                ),
                CHAR(13), N'\\r'
            ),
            CHAR(10), N'\\n'
        )
        """
    }

    static func isBinaryType(_ dataType: String) -> Bool {
        ["binary", "varbinary", "image"].contains(dataType.lowercased())
    }

    static func qualifiedName(for schema: TableSchema) -> String {
        "\(quoteIdentifier(schema.schemaName)).\(quoteIdentifier(schema.tableName))"
    }

    static func quoteIdentifier(_ value: String) -> String {
        "[\(value.replacingOccurrences(of: "]", with: "]]"))]"
    }

    /// ค่า literal สำหรับใส่ในตัว query — escape single quote ตามกติกาของ T-SQL
    static func stringLiteral(_ value: String) -> String {
        "N'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// definition ของ view / procedure / function โดยตัดเป็นชิ้นละ 4000 ตัวอักษร
    ///
    /// sqlcmd ตัดบรรทัดที่ความกว้าง `-w` — ส่งออกมาเป็นชิ้นสั้น ๆ แล้วต่อกลับใน Swift
    /// จึงปลอดภัยกว่าการหวังว่า definition ยาว ๆ จะไม่โดนตัด
    static func moduleDefinition(schemaName: String, objectName: String) -> String {
        """
        SET NOCOUNT ON;
        DECLARE @definition nvarchar(max) = (
            SELECT TOP 1 m.definition
            FROM sys.sql_modules m
            INNER JOIN sys.objects o ON o.object_id = m.object_id
            INNER JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE s.name = \(stringLiteral(schemaName)) AND o.name = \(stringLiteral(objectName))
        );

        IF @definition IS NULL
        BEGIN
            SELECT N'\(chunkMarker)\(nullToken)\(chunkMarker)';
        END
        ELSE
        BEGIN
            WITH chunks AS (
                SELECT 1 AS chunk_index
                UNION ALL
                SELECT chunk_index + 1 FROM chunks WHERE chunk_index * 4000 < DATALENGTH(@definition) / 2
            )
            SELECT N'\(chunkMarker)' + \(escapedStringExpression(for: "SUBSTRING(@definition, (chunk_index - 1) * 4000 + 1, 4000)")) + N'\(chunkMarker)'
            FROM chunks
            ORDER BY chunk_index
            OPTION (MAXRECURSION 0);
        END
        """
    }

    /// column ของ table หนึ่งตัว พร้อม computed / default / collation
    static func tableColumnDefinition(schemaName: String, objectName: String) -> String {
        """
        SET NOCOUNT ON;
        SELECT
            COALESCE(CONVERT(nvarchar(max), c.column_id), N'0'),
            COALESCE(CONVERT(nvarchar(max), c.name), N''),
            COALESCE(CONVERT(nvarchar(max), ty.name), N''),
            COALESCE(CONVERT(nvarchar(max), c.max_length), N'0'),
            COALESCE(CONVERT(nvarchar(max), c.precision), N'0'),
            COALESCE(CONVERT(nvarchar(max), c.scale), N'0'),
            CONVERT(nvarchar(max), CASE WHEN c.is_nullable = 1 THEN 1 ELSE 0 END),
            CONVERT(nvarchar(max), CASE WHEN c.is_identity = 1 THEN 1 ELSE 0 END),
            CONVERT(nvarchar(max), CASE WHEN c.is_computed = 1 THEN 1 ELSE 0 END),
            COALESCE(\(escapedStringExpression(for: "CONVERT(nvarchar(max), cc.definition)")), N''),
            COALESCE(\(escapedStringExpression(for: "CONVERT(nvarchar(max), dc.definition)")), N''),
            CONVERT(nvarchar(max), CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END),
            COALESCE(CONVERT(nvarchar(max), c.collation_name), N'')
        FROM sys.tables t
        INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
        INNER JOIN sys.columns c ON c.object_id = t.object_id
        INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
        LEFT JOIN sys.computed_columns cc
            ON cc.object_id = c.object_id AND cc.column_id = c.column_id
        LEFT JOIN sys.default_constraints dc
            ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
        LEFT JOIN (
            SELECT ic.object_id, ic.column_id
            FROM sys.indexes i
            INNER JOIN sys.index_columns ic
                ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            WHERE i.is_primary_key = 1
        ) pk
            ON pk.object_id = c.object_id AND pk.column_id = c.column_id
        WHERE s.name = \(stringLiteral(schemaName)) AND t.name = \(stringLiteral(objectName))
        ORDER BY c.column_id;
        """
    }

    /// index และ key constraint ของ table หนึ่งตัว — หนึ่งแถวต่อหนึ่ง index column
    static func tableIndexDefinition(schemaName: String, objectName: String) -> String {
        """
        SET NOCOUNT ON;
        SELECT
            COALESCE(CONVERT(nvarchar(max), i.name), N''),
            CONVERT(nvarchar(max), CASE WHEN i.is_unique = 1 THEN 1 ELSE 0 END),
            CONVERT(nvarchar(max), CASE WHEN i.is_primary_key = 1 THEN 1 ELSE 0 END),
            CONVERT(nvarchar(max), CASE WHEN i.is_unique_constraint = 1 THEN 1 ELSE 0 END),
            COALESCE(CONVERT(nvarchar(max), i.type_desc), N''),
            COALESCE(CONVERT(nvarchar(max), c.name), N''),
            CONVERT(nvarchar(max), CASE WHEN ic.is_descending_key = 1 THEN 1 ELSE 0 END),
            CONVERT(nvarchar(max), CASE WHEN ic.is_included_column = 1 THEN 1 ELSE 0 END)
        FROM sys.indexes i
        INNER JOIN sys.tables t ON t.object_id = i.object_id
        INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
        LEFT JOIN sys.index_columns ic
            ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        LEFT JOIN sys.columns c
            ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE s.name = \(stringLiteral(schemaName))
            AND t.name = \(stringLiteral(objectName))
            AND i.type > 0
        ORDER BY i.index_id, ic.is_included_column, ic.key_ordinal, ic.index_column_id;
        """
    }

    /// ชื่อชนิดข้อมูลพร้อมความยาว/ความละเอียด ในรูปแบบเดียวกับที่เขียนใน DDL
    static func formattedTypeName(_ dataType: String, maxLength: Int, precision: Int, scale: Int) -> String {
        let normalized = dataType.lowercased()

        switch normalized {
        case "nvarchar", "nchar":
            return maxLength == -1 ? "\(normalized)(max)" : "\(normalized)(\(maxLength / 2))"
        case "varchar", "char", "varbinary", "binary":
            return maxLength == -1 ? "\(normalized)(max)" : "\(normalized)(\(maxLength))"
        case "decimal", "numeric":
            return "\(normalized)(\(precision), \(scale))"
        case "datetime2", "time", "datetimeoffset":
            return "\(normalized)(\(scale))"
        case "float":
            return "\(normalized)(\(precision))"
        default:
            return normalized
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - Schema object definitions

extension SQLCmdService {
    /// ดึง definition ของ object หนึ่งตัวจากฝั่งใดฝั่งหนึ่ง เพื่อเอาไปเทียบรายบรรทัด
    ///
    /// คืน `nil` เมื่อ object ไม่มีอยู่ในฝั่งนั้น (เช่น object ที่มีเฉพาะฝั่ง source)
    nonisolated func loadObjectDefinition(_ input: ConnectionInput, difference: SchemaDifference) throws -> String? {
        let configuration = try validatedConfiguration(from: input)
        let schemaName = difference.schemaName.isEmpty ? "dbo" : difference.schemaName
        let objectName = difference.objectName

        switch difference.category {
        case .view, .storedProcedure, .function:
            return try loadModuleDefinition(schemaName: schemaName, objectName: objectName, configuration: configuration)
        case .table:
            return try loadTableDefinition(schemaName: schemaName, objectName: objectName, configuration: configuration)
        case .other:
            return nil
        }
    }

    /// definition ของ view / procedure / function จาก `sys.sql_modules`
    private nonisolated func loadModuleDefinition(
        schemaName: String,
        objectName: String,
        configuration: SQLConnectionConfiguration
    ) throws -> String? {
        try runChunkedDefinitionQuery(
            MetadataQuery.moduleDefinition(schemaName: schemaName, objectName: objectName),
            configuration: configuration
        )
    }

    /// อ่านผลลัพธ์ที่ถูกครอบด้วย marker แล้วต่อกลับเป็น definition เดียว
    ///
    /// ไม่ใช้ `runDelimitedQuery` เพราะตัวนั้น trim ช่องว่างและตัดบรรทัดที่ขึ้นต้นด้วย `(` ทิ้ง
    /// ซึ่งจะทำให้ definition ที่ย่อหน้าไว้เพี้ยน
    private nonisolated func runChunkedDefinitionQuery(
        _ query: String,
        configuration: SQLConnectionConfiguration
    ) throws -> String? {
        let output = try runRawQuery(query, configuration: configuration)
        let marker = MetadataQuery.chunkMarker

        let chunks = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix(marker) && $0.hasSuffix(marker) && $0.count >= 2 }
            .map { String($0.dropFirst().dropLast()) }

        guard !chunks.isEmpty else { return nil }
        guard chunks != [MetadataQuery.nullToken] else { return nil }

        return chunks.map { unescapeRowValue($0) }.joined()
    }

    /// ประกอบ definition ของ table ขึ้นมาจาก `sys.columns` และ `sys.indexes`
    ///
    /// ไม่ใช่ DDL ที่รันได้จริง แต่เป็นรูปแบบคงที่ที่เทียบสองฝั่งแล้วอ่านความต่างได้ง่าย
    private nonisolated func loadTableDefinition(
        schemaName: String,
        objectName: String,
        configuration: SQLConnectionConfiguration
    ) throws -> String? {
        let columnRows = try runDelimitedQuery(
            MetadataQuery.tableColumnDefinition(schemaName: schemaName, objectName: objectName),
            configuration: configuration,
            expectedColumnCount: 13
        )

        guard !columnRows.isEmpty else { return nil }

        let indexRows = try runDelimitedQuery(
            MetadataQuery.tableIndexDefinition(schemaName: schemaName, objectName: objectName),
            configuration: configuration,
            expectedColumnCount: 8
        )

        var lines = ["CREATE TABLE [\(schemaName)].[\(objectName)] ("]
        var bodyLines = columnRows.map { columnDefinitionLine(from: $0) }
        bodyLines.append(contentsOf: constraintDefinitionLines(from: indexRows))

        for (index, line) in bodyLines.enumerated() {
            lines.append("    " + line + (index == bodyLines.count - 1 ? "" : ","))
        }

        lines.append(");")
        lines.append(contentsOf: indexDefinitionLines(from: indexRows))

        return lines.joined(separator: "\n")
    }

    private nonisolated func columnDefinitionLine(from row: [String]) -> String {
        let name = row[1]
        let dataType = row[2]
        let maxLength = Int(row[3]) ?? 0
        let precision = Int(row[4]) ?? 0
        let scale = Int(row[5]) ?? 0
        let isNullable = parseBoolFlag(row[6])
        let isIdentity = parseBoolFlag(row[7])
        let isComputed = parseBoolFlag(row[8])
        let computedDefinition = unescapeRowValue(row[9])
        let defaultDefinition = unescapeRowValue(row[10])
        let collation = row[12]

        if isComputed {
            return "[\(name)] AS \(computedDefinition)"
        }

        var parts = ["[\(name)]", MetadataQuery.formattedTypeName(dataType, maxLength: maxLength, precision: precision, scale: scale)]

        if !collation.isEmpty {
            parts.append("COLLATE \(collation)")
        }

        if isIdentity {
            parts.append("IDENTITY")
        }

        parts.append(isNullable ? "NULL" : "NOT NULL")

        if !defaultDefinition.isEmpty {
            parts.append("DEFAULT \(defaultDefinition)")
        }

        return parts.joined(separator: " ")
    }

    /// primary key และ unique constraint เขียนไว้ในตัว table เหมือน DDL จริง
    private nonisolated func constraintDefinitionLines(from rows: [[String]]) -> [String] {
        groupedIndexes(from: rows).compactMap { index in
            if index.isPrimaryKey {
                return "CONSTRAINT [\(index.name)] PRIMARY KEY \(index.typeDescription) (\(index.keyColumns.joined(separator: ", ")))"
            }

            if index.isUniqueConstraint {
                return "CONSTRAINT [\(index.name)] UNIQUE \(index.typeDescription) (\(index.keyColumns.joined(separator: ", ")))"
            }

            return nil
        }
    }

    private nonisolated func indexDefinitionLines(from rows: [[String]]) -> [String] {
        groupedIndexes(from: rows).compactMap { index in
            guard !index.isPrimaryKey, !index.isUniqueConstraint else { return nil }

            var line = "CREATE \(index.isUnique ? "UNIQUE " : "")\(index.typeDescription) INDEX [\(index.name)] (\(index.keyColumns.joined(separator: ", ")))"

            if !index.includedColumns.isEmpty {
                line += " INCLUDE (\(index.includedColumns.joined(separator: ", ")))"
            }

            return line + ";"
        }
    }

    private nonisolated func groupedIndexes(from rows: [[String]]) -> [IndexDefinition] {
        var ordered: [String] = []
        var indexes: [String: IndexDefinition] = [:]

        for row in rows {
            let name = row[0]
            guard !name.isEmpty else { continue }

            if indexes[name] == nil {
                ordered.append(name)
                indexes[name] = IndexDefinition(
                    name: name,
                    isUnique: parseBoolFlag(row[1]),
                    isPrimaryKey: parseBoolFlag(row[2]),
                    isUniqueConstraint: parseBoolFlag(row[3]),
                    typeDescription: row[4].uppercased(),
                    keyColumns: [],
                    includedColumns: []
                )
            }

            let columnName = row[5]
            guard !columnName.isEmpty else { continue }

            if parseBoolFlag(row[7]) {
                indexes[name]?.includedColumns.append("[\(columnName)]")
            } else {
                indexes[name]?.keyColumns.append("[\(columnName)]" + (parseBoolFlag(row[6]) ? " DESC" : ""))
            }
        }

        return ordered.compactMap { indexes[$0] }
    }
}

private nonisolated struct IndexDefinition {
    let name: String
    let isUnique: Bool
    let isPrimaryKey: Bool
    let isUniqueConstraint: Bool
    let typeDescription: String
    var keyColumns: [String]
    var includedColumns: [String]
}
