//
//  SqlPackageService.swift
//  Domta
//

import Foundation

/// เรียก `sqlpackage` เพื่อเทียบ schema ระหว่าง source กับ target
///
/// `sqlpackage /Action:Script` ไม่รับ database ทั้งสองฝั่ง — source ต้องเป็นไฟล์ `.dacpac`
/// flow จึงเป็น Extract source ออกมาเป็น dacpac ก่อน แล้วค่อย Script เทียบกับ target
/// โดยขอ deployment report (XML) ออกมาพร้อมกันในรอบเดียว
nonisolated final class SqlPackageService: @unchecked Sendable {
    private let processLock = NSLock()
    private var runningProcess: Process?
    private var isCancelled = false

    // MARK: - Tool discovery

    nonisolated func resolvedSqlPackageURL() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let pathVariable = ProcessInfo.processInfo.environment["PATH"] ?? ""

        let candidatePaths = pathVariable
            .split(separator: ":")
            .map { String($0) + "/sqlpackage" } + [
                "\(home)/.dotnet/tools/sqlpackage",
                "/opt/homebrew/bin/sqlpackage",
                "/usr/local/bin/sqlpackage",
                "/usr/bin/sqlpackage",
                "/opt/sqlpackage/sqlpackage",
                "/usr/local/share/sqlpackage/sqlpackage",
                "\(home)/sqlpackage/sqlpackage"
            ]

        for candidate in candidatePaths where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        return nil
    }

    // MARK: - Cancellation

    func cancel() {
        processLock.lock()
        isCancelled = true
        let process = runningProcess
        processLock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func resetCancellation() {
        processLock.lock()
        isCancelled = false
        processLock.unlock()
    }

    private var cancellationRequested: Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return isCancelled
    }

    // MARK: - Compare

    nonisolated func compareSchema(
        source: ConnectionInput,
        target: ConnectionInput,
        options: SchemaCompareOptions,
        progress: (@Sendable (ProgressState) -> Void)? = nil
    ) throws -> SchemaCompareReport {
        resetCancellation()

        guard resolvedSqlPackageURL() != nil else {
            throw CompareAppError.sqlPackageNotFound
        }

        let sourceConfig = try ConnectionStringParser.validatedConfiguration(from: source)
        let targetConfig = try ConnectionStringParser.validatedConfiguration(from: target)

        let workingDirectory = try makeWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let dacpacURL = workingDirectory.appendingPathComponent("source.dacpac")
        let scriptURL = workingDirectory.appendingPathComponent("deploy.sql")
        let reportURL = workingDirectory.appendingPathComponent("report.xml")

        progress?(
            ProgressState(
                message: "Extracting source schema (\(sourceConfig.database ?? sourceConfig.server))...",
                completedUnitCount: 0,
                totalUnitCount: 3,
                showsIndeterminateSpinner: false
            )
        )

        try runSqlPackage(
            arguments: extractArguments(configuration: sourceConfig, outputURL: dacpacURL),
            configuration: sourceConfig,
            stage: "Extract",
            progress: { message in
                progress?(
                    ProgressState(message: message, completedUnitCount: 0, totalUnitCount: 3, showsIndeterminateSpinner: false)
                )
            }
        )

        progress?(
            ProgressState(
                message: "Comparing against target (\(targetConfig.database ?? targetConfig.server))...",
                completedUnitCount: 1,
                totalUnitCount: 3,
                showsIndeterminateSpinner: false
            )
        )

        try runSqlPackage(
            arguments: scriptArguments(
                sourceFile: dacpacURL,
                configuration: targetConfig,
                scriptURL: scriptURL,
                reportURL: reportURL,
                options: options
            ),
            configuration: targetConfig,
            stage: "Script",
            progress: { message in
                progress?(
                    ProgressState(message: message, completedUnitCount: 1, totalUnitCount: 3, showsIndeterminateSpinner: false)
                )
            }
        )

        progress?(
            ProgressState(message: "Reading deployment report...", completedUnitCount: 2, totalUnitCount: 3, showsIndeterminateSpinner: false)
        )

        let report = try DeployReportParser.parse(contentsOf: reportURL)
        let script = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""

        progress?(
            ProgressState(
                message: "Found \(report.differences.count) schema differences",
                completedUnitCount: 3,
                totalUnitCount: 3,
                showsIndeterminateSpinner: false
            )
        )

        return SchemaCompareReport(
            differences: report.differences,
            alerts: report.alerts,
            script: script,
            generatedAt: Date()
        )
    }

    // MARK: - Argument building

    private nonisolated func extractArguments(configuration: SQLConnectionConfiguration, outputURL: URL) -> [String] {
        [
            "/Action:Extract",
            "/SourceConnectionString:\(Self.connectionString(for: configuration))",
            "/TargetFile:\(outputURL.path)",
            "/OverwriteFiles:True",
            "/p:ExtractAllTableData=False",
            "/p:VerifyExtraction=False",
            "/p:IgnorePermissions=True",
            "/p:IgnoreUserLoginMappings=True",
            "/p:IgnoreExtendedProperties=True"
        ]
    }

    private nonisolated func scriptArguments(
        sourceFile: URL,
        configuration: SQLConnectionConfiguration,
        scriptURL: URL,
        reportURL: URL,
        options: SchemaCompareOptions
    ) -> [String] {
        var arguments = [
            "/Action:Script",
            "/SourceFile:\(sourceFile.path)",
            "/TargetConnectionString:\(Self.connectionString(for: configuration))",
            "/DeployScriptPath:\(scriptURL.path)",
            "/DeployReportPath:\(reportURL.path)",
            "/OverwriteFiles:True",
            "/p:ScriptDatabaseOptions=False",
            "/p:AllowIncompatiblePlatform=True",
            "/p:CommentOutSetVarDeclarations=False",
            "/p:DropObjectsNotInSource=\(options.reportObjectsOnlyInTarget ? "True" : "False")",
            "/p:BlockOnPossibleDataLoss=\(options.blockOnPossibleDataLoss ? "True" : "False")",
            "/p:IgnorePermissions=\(options.ignorePermissions ? "True" : "False")",
            "/p:IgnoreUserSettingsObjects=\(options.ignoreUserSettingsObjects ? "True" : "False")",
            "/p:IgnoreExtendedProperties=\(options.ignoreExtendedProperties ? "True" : "False")",
            "/p:IgnoreWhitespace=\(options.ignoreWhitespaceInModules ? "True" : "False")",
            "/p:IgnoreComments=\(options.ignoreWhitespaceInModules ? "True" : "False")"
        ]

        let excluded = options.excludedObjectTypes
        if !excluded.isEmpty {
            arguments.append("/p:ExcludeObjectTypes=\(excluded.joined(separator: ";"))")
        }

        return arguments
    }

    /// สร้าง connection string ตามรูปแบบ SqlClient จาก config ที่ parse แล้ว
    ///
    /// รหัสผ่านที่ผู้ใช้กรอกแยกถูกเติมเข้ามาแล้วตั้งแต่ `applyingFallbackPassword`
    static func connectionString(for configuration: SQLConnectionConfiguration) -> String {
        var parts = ["Server=\(quotedConnectionValue(configuration.server))"]

        if let database = configuration.database, !database.isEmpty {
            parts.append("Initial Catalog=\(quotedConnectionValue(database))")
        }

        if let username = configuration.username, !username.isEmpty {
            parts.append("User ID=\(quotedConnectionValue(username))")
        }

        if let password = configuration.password, !password.isEmpty {
            parts.append("Password=\(quotedConnectionValue(password))")
        }

        let shouldEncrypt = configuration.encrypt ?? configuration.server.lowercased().contains(".database.windows.net")
        parts.append("Encrypt=\(shouldEncrypt ? "True" : "False")")
        parts.append("TrustServerCertificate=\(configuration.trustServerCertificate ? "True" : "False")")
        parts.append("Persist Security Info=False")
        parts.append("Connect Timeout=60")

        return parts.joined(separator: ";")
    }

    /// ครอบด้วย single quote เสมอเมื่อค่ามีอักขระพิเศษ — เลี่ยง double quote เพราะ response file
    /// ของ sqlpackage ใช้ double quote เป็นตัวคุมขอบเขต argument
    private static func quotedConnectionValue(_ value: String) -> String {
        let needsQuoting = value.isEmpty
            || value.contains(";")
            || value.contains("'")
            || value.contains("\"")
            || value.contains("=")
            || value != value.trimmingCharacters(in: .whitespaces)

        guard needsQuoting else { return value }

        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: - Process execution

    private nonisolated func makeWorkingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("domta-schema-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CompareAppError.sqlPackageFailed("สร้างโฟลเดอร์ชั่วคราวไม่สำเร็จ: \(error.localizedDescription)")
        }

        return url
    }

    /// เขียน argument ลง response file แล้วส่งเป็น `@file`
    ///
    /// connection string มีรหัสผ่านอยู่ด้วย — การส่งผ่านไฟล์สิทธิ์ 0600 ทำให้รหัสผ่าน
    /// ไม่โผล่ใน process list ของเครื่อง เหมือนที่ฝั่ง sqlcmd ใช้ `SQLCMDPASSWORD`
    @discardableResult
    private func runSqlPackage(
        arguments: [String],
        configuration: SQLConnectionConfiguration,
        stage: String,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> String {
        guard let executableURL = resolvedSqlPackageURL() else {
            throw CompareAppError.sqlPackageNotFound
        }

        // ผู้ใช้กดยกเลิกระหว่างช่วงต่อของสอง stage — ไม่ต้องเริ่ม process ถัดไป
        if cancellationRequested {
            throw CompareAppError.operationCancelled
        }

        let responseFileURL = try writeResponseFile(arguments: arguments)
        defer { try? FileManager.default.removeItem(at: responseFileURL) }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["@\(responseFileURL.path)"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let collector = OutputCollector(progress: progress)

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.appendStandardOutput(handle.availableData)
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.appendStandardError(handle.availableData)
        }

        processLock.lock()
        runningProcess = process
        processLock.unlock()

        do {
            try process.run()
        } catch {
            processLock.lock()
            runningProcess = nil
            processLock.unlock()
            throw CompareAppError.sqlPackageFailed("เรียก sqlpackage ไม่สำเร็จ: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        collector.appendStandardOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
        collector.appendStandardError(errorPipe.fileHandleForReading.readDataToEndOfFile())

        processLock.lock()
        runningProcess = nil
        processLock.unlock()

        let standardOutput = collector.standardOutputText
        let standardError = collector.standardErrorText

        if cancellationRequested {
            throw CompareAppError.operationCancelled
        }

        guard process.terminationStatus == 0 else {
            let rawMessage = standardError.isEmpty ? standardOutput : standardError + "\n" + standardOutput
            throw CompareAppError.sqlPackageFailed(
                Self.diagnose(rawMessage: rawMessage, stage: stage, configuration: configuration)
            )
        }

        return standardOutput
    }

    private nonisolated func writeResponseFile(arguments: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("domta-sqlpackage-\(UUID().uuidString).txt")

        let body = arguments
            .map { argument -> String in
                guard let separator = argument.firstIndex(of: ":") else { return argument }
                let name = String(argument[..<separator])
                let value = String(argument[argument.index(after: separator)...])
                return "\(name):\"\(value)\""
            }
            .joined(separator: "\n") + "\n"

        guard let data = body.data(using: .utf8) else {
            throw CompareAppError.sqlPackageFailed("เขียน argument ของ sqlpackage ไม่สำเร็จ")
        }

        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CompareAppError.sqlPackageFailed("เขียนไฟล์ argument ชั่วคราวไม่สำเร็จ")
        }

        return url
    }

    // MARK: - Diagnosis

    static func diagnose(rawMessage: String, stage: String, configuration: SQLConnectionConfiguration) -> String {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()

        if lowered.contains("login failed for user") {
            return """
            \(message)

            Diagnosis (\(stage)):
            - SQL login หรือ password ไม่ถูกต้อง
            - หรือ login `\(configuration.username ?? "(unknown)")` ไม่มีสิทธิ์ในฐานข้อมูลนี้
            - schema compare ต้องการสิทธิ์อ่าน metadata (`VIEW DEFINITION`) ของทุก object
            """
        }

        if lowered.contains("unresolved reference") || lowered.contains("could not be resolved") {
            return """
            \(message)

            Diagnosis (\(stage)):
            - database ฝั่งนี้อ้างถึง object ข้าม database หรือ object ที่ไม่มีอยู่จริง
            - sqlpackage ต้อง resolve ทุก reference ให้ได้ก่อนจึงจะ extract เป็น dacpac ได้
            - แก้ที่ต้นทาง (ลบ view/proc ที่อ้าง object ที่หายไป) หรือเทียบเฉพาะบางกลุ่ม object
            """
        }

        if lowered.contains("certificate") || lowered.contains("ssl") || lowered.contains("tls") {
            return """
            \(message)

            Diagnosis (\(stage)):
            - server ฝั่งนี้ใช้ self-signed certificate
            - เพิ่ม `Trust Server Certificate=True` ใน connection string
            - หรือถ้าไม่ต้องการ TLS ให้ตั้ง `Encrypt=False`
            """
        }

        if lowered.contains("network-related")
            || lowered.contains("connection refused")
            || lowered.contains("server was not found")
            || lowered.contains("firewall") {
            if configuration.isLocalServer {
                return """
                \(message)

                Diagnosis (\(stage)):
                - container ของ SQL Server ยังไม่ได้รัน (`docker ps` เพื่อตรวจ)
                - หรือ port ใน `\(configuration.server)` ไม่ตรงกับที่ container map ไว้
                """
            }

            return """
            \(message)

            Diagnosis (\(stage)):
            - firewall/network ยังไม่อนุญาตเครื่องนี้ หรือ server name / port ไม่ถูกต้อง
            """
        }

        if lowered.contains("cannot open database") || lowered.contains("permission was denied") {
            return """
            \(message)

            Diagnosis (\(stage)):
            - login ผ่านแล้ว แต่ไม่มีสิทธิ์เข้า database `\(configuration.database ?? "(unknown)")`
            - หรือชื่อ database ไม่ถูกต้อง
            """
        }

        return message.isEmpty ? "sqlpackage จบการทำงานด้วย error โดยไม่มีข้อความ (\(stage))" : message
    }
}

/// รวบรวม stdout/stderr แบบ thread-safe และส่งบรรทัดล่าสุดออกไปเป็น progress
private nonisolated final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutputData = Data()
    private var standardErrorData = Data()
    private var pendingLine = ""
    private let progress: (@Sendable (String) -> Void)?

    init(progress: (@Sendable (String) -> Void)?) {
        self.progress = progress
    }

    func appendStandardOutput(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        standardOutputData.append(data)
        let chunk = String(data: data, encoding: .utf8) ?? ""
        pendingLine += chunk
        var completedLines: [String] = []

        while let newlineIndex = pendingLine.firstIndex(of: "\n") {
            completedLines.append(String(pendingLine[..<newlineIndex]))
            pendingLine = String(pendingLine[pendingLine.index(after: newlineIndex)...])
        }
        lock.unlock()

        for line in completedLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            progress?(trimmed)
        }
    }

    func appendStandardError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        standardErrorData.append(data)
        lock.unlock()
    }

    var standardOutputText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: standardOutputData, encoding: .utf8) ?? ""
    }

    var standardErrorText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: standardErrorData, encoding: .utf8) ?? ""
    }
}
