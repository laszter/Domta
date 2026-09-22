//
//  SqlPackageService.swift
//  Domta
//

import Foundation

/// เรียก `sqlpackage` เพื่อเทียบ schema ระหว่าง source กับ target
///
/// flow: Extract **ทั้งสองฝั่ง** ออกมาเป็น `.dacpac` ก่อน แล้วค่อย Script แบบ dacpac ต่อ dacpac
/// โดยขอ deployment report (XML) ออกมาพร้อมกันในรอบเดียว
///
/// เหตุที่ extract target ด้วยแทนที่จะ Script ใส่ database สด:
/// - dacpac ทั้งคู่ถูกเก็บไว้ใน `SchemaCompareWorkspace` ตลอด session ให้ `DacFxScriptService`
///   ออก script เฉพาะ object ที่เลือกได้โดยไม่ต้องต่อ database อีก (เร็ว และทำซ้ำได้ผลเดิม)
/// - Compare API ของ DacFx จะฟ้อง "target database was modified after schema comparison was
///   completed" ถ้า catalog ของ target ขยับระหว่าง compare กับ generate (job ของแอปบน target,
///   auto-created statistics) — snapshot เป็นไฟล์ตัดปัญหานี้ทิ้งทั้งชั้น
/// - ต้นทุนเท่าเดิม: Script ใส่ database สดก็ต้องโหลด model ของ target ทั้งก้อนอยู่แล้ว
///
/// ฝั่งที่ผู้ใช้เลือกเป็นไฟล์ `.dacpac` ข้ามขั้น Extract ไปเลย — ไฟล์นั้นคือ snapshot อยู่แล้ว
nonisolated final class SqlPackageService: @unchecked Sendable {
    /// ฝั่งหนึ่งที่ตรวจแล้ว — database ต้อง extract ก่อน ส่วนไฟล์ dacpac ส่งให้ sqlpackage ได้ทันที
    private enum ResolvedEndpoint {
        case database(SQLConnectionConfiguration)
        case dacpac(URL)

        var dacpacURL: URL? {
            if case .dacpac(let url) = self { return url }
            return nil
        }

        /// ชื่อที่ใส่ใน `/TargetDatabaseName` และหัว script — ไฟล์ dacpac ไม่มีชื่อ database จึงใช้ชื่อไฟล์
        var databaseName: String {
            switch self {
            case .database(let configuration): return configuration.database ?? "Target"
            case .dacpac(let url): return url.deletingPathExtension().lastPathComponent
            }
        }
    }

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

    // MARK: - Standalone schema export

    /// Use a fresh service per export so cancellation also works before the worker starts.
    /// Stage beside the destination; a failed/cancelled extraction never replaces an existing file.
    func exportDacpac(input: ConnectionInput, to destination: URL,
                      progress: (@Sendable (String) -> Void)? = nil) throws {
        let configuration = try ConnectionStringParser.validatedConfiguration(from: input)
        guard let database = configuration.database, !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompareAppError.invalidConnectionString("ระบุ Database หรือ Initial Catalog ก่อน export DACPAC")
        }
        guard resolvedSqlPackageURL() != nil else { throw CompareAppError.sqlPackageNotFound }
        if cancellationRequested { throw CompareAppError.operationCancelled }

        let files = FileManager.default
        let stagingDirectory = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                             appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: stagingDirectory) }
        let stagedFile = stagingDirectory.appendingPathComponent("schema.dacpac")
        try runSqlPackage(arguments: Self.schemaExportArguments(configuration: configuration, outputURL: stagedFile),
                          configuration: configuration, stage: "Export DACPAC", progress: progress)
        if cancellationRequested { throw CompareAppError.operationCancelled }
        let attributes = try files.attributesOfItem(atPath: stagedFile.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw CompareAppError.sqlPackageFailed("sqlpackage ไม่ได้สร้างไฟล์ DACPAC ที่สมบูรณ์")
        }
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: stagedFile)
        } else {
            try files.moveItem(at: stagedFile, to: destination)
        }
    }

    static func schemaExportArguments(configuration: SQLConnectionConfiguration, outputURL: URL) -> [String] {
        [
            "/Action:Extract",
            "/SourceConnectionString:\(connectionString(for: configuration))",
            "/TargetFile:\(outputURL.path)",
            "/p:ExtractTarget=DacPac",
            "/p:ExtractAllTableData=False",
            "/p:ExtractUsageProperties=False",
            "/p:VerifyExtraction=True",
            "/p:IgnorePermissions=False",
            "/p:IgnoreUserLoginMappings=False",
            "/p:IgnoreExtendedProperties=False"
        ]
    }

    // MARK: - Compare

    nonisolated func compareSchema(
        source: SchemaCompareEndpoint,
        target: SchemaCompareEndpoint,
        options: SchemaCompareOptions,
        progress: (@Sendable (ProgressState) -> Void)? = nil
    ) throws -> SchemaCompareReport {
        resetCancellation()

        guard resolvedSqlPackageURL() != nil else {
            throw CompareAppError.sqlPackageNotFound
        }

        let resolvedSource = try resolve(source)
        let resolvedTarget = try resolve(target)

        let workspace = try makeWorkspace(source: resolvedSource, target: resolvedTarget)

        do {
            try runCompare(source: resolvedSource, target: resolvedTarget, options: options, workspace: workspace, progress: progress)
        } catch {
            workspace.cleanUp()
            throw error
        }

        let reportURL = workspace.directory.appendingPathComponent("report.xml")
        let scriptURL = workspace.directory.appendingPathComponent("deploy.sql")

        progress?(
            ProgressState(message: "Reading deployment report...", completedUnitCount: 3, totalUnitCount: 4, showsIndeterminateSpinner: false)
        )

        let report: DeployReportParser.Output
        do {
            report = try DeployReportParser.parse(contentsOf: reportURL)
        } catch {
            workspace.cleanUp()
            throw error
        }

        let script = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""

        // report บอกแค่ `[schema].[ConstraintName]` สำหรับ FK/default/check constraint — หา table แม่จาก
        // ALTER TABLE ใน script เพื่อให้ตารางยุบมันเข้าแถวของ table แทนที่จะโผล่เป็นแถวของตัวเอง
        let differences = DeployReportParser.resolvingParents(of: report.differences, script: script)

        progress?(
            ProgressState(
                message: "Found \(report.differences.count) schema differences",
                completedUnitCount: 4,
                totalUnitCount: 4,
                showsIndeterminateSpinner: false
            )
        )

        return SchemaCompareReport(
            differences: differences,
            alerts: report.alerts,
            script: script,
            generatedAt: Date(),
            workspace: workspace
        )
    }

    private nonisolated func resolve(_ endpoint: SchemaCompareEndpoint) throws -> ResolvedEndpoint {
        switch endpoint {
        case .database(let input):
            return .database(try ConnectionStringParser.validatedConfiguration(from: input))

        case .dacpac(let url):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw CompareAppError.dacpacNotFound(url.path)
            }
            return .dacpac(url)
        }
    }

    private nonisolated func runCompare(
        source: ResolvedEndpoint,
        target: ResolvedEndpoint,
        options: SchemaCompareOptions,
        workspace: SchemaCompareWorkspace,
        progress: (@Sendable (ProgressState) -> Void)?
    ) throws {
        let stages: [(label: String, endpoint: ResolvedEndpoint, output: URL)] = [
            ("source", source, workspace.sourceDacpac),
            ("target", target, workspace.targetDacpac)
        ]

        for (index, stage) in stages.enumerated() {
            // ฝั่งที่เป็นไฟล์ dacpac อยู่แล้วไม่ต้อง extract — workspace ชี้ไปที่ไฟล์นั้นตรง ๆ
            guard case .database(let configuration) = stage.endpoint else { continue }

            progress?(
                ProgressState(
                    message: "Extracting \(stage.label) schema (\(configuration.database ?? configuration.server))...",
                    completedUnitCount: index,
                    totalUnitCount: 4,
                    showsIndeterminateSpinner: false
                )
            )

            try runSqlPackage(
                arguments: extractArguments(configuration: configuration, outputURL: stage.output),
                configuration: configuration,
                stage: "Extract \(stage.label)",
                progress: { message in
                    progress?(
                        ProgressState(message: message, completedUnitCount: index, totalUnitCount: 4, showsIndeterminateSpinner: false)
                    )
                }
            )
        }

        progress?(
            ProgressState(
                message: "Comparing dacpacs (\(workspace.targetDatabaseName))...",
                completedUnitCount: 2,
                totalUnitCount: 4,
                showsIndeterminateSpinner: false
            )
        )

        try runSqlPackage(
            arguments: scriptArguments(
                sourceFile: workspace.sourceDacpac,
                targetFile: workspace.targetDacpac,
                targetDatabaseName: workspace.targetDatabaseName,
                scriptURL: workspace.directory.appendingPathComponent("deploy.sql"),
                reportURL: workspace.directory.appendingPathComponent("report.xml"),
                options: options
            ),
            configuration: nil,
            stage: "Script",
            progress: { message in
                progress?(
                    ProgressState(message: message, completedUnitCount: 2, totalUnitCount: 4, showsIndeterminateSpinner: false)
                )
            }
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

    /// Script แบบ dacpac ต่อ dacpac — ต้องส่ง `/TargetDatabaseName` เพราะไฟล์ไม่มีชื่อ database ในตัว
    private nonisolated func scriptArguments(
        sourceFile: URL,
        targetFile: URL,
        targetDatabaseName: String,
        scriptURL: URL,
        reportURL: URL,
        options: SchemaCompareOptions
    ) -> [String] {
        var arguments = [
            "/Action:Script",
            "/SourceFile:\(sourceFile.path)",
            "/TargetFile:\(targetFile.path)",
            "/TargetDatabaseName:\(targetDatabaseName)",
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

    /// โฟลเดอร์ชั่วคราวของ compare รอบนี้ — อยู่ต่อจน view model ล้างทิ้ง (compare ใหม่ / ปิดหน้า)
    /// เพราะ dacpac ข้างในถูกใช้ต่อตอนออก script เฉพาะ object ที่เลือก
    ///
    /// ฝั่งที่เป็นไฟล์ dacpac ไม่ถูก copy เข้ามา — ให้ reference ไปยัง dacpac อื่นที่วางคู่กัน
    /// (เช่น master.dacpac ใน bin ของ SQL project) ยัง resolve ได้จากโฟลเดอร์เดิม
    private nonisolated func makeWorkspace(source: ResolvedEndpoint, target: ResolvedEndpoint) throws -> SchemaCompareWorkspace {
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

        return SchemaCompareWorkspace(
            directory: url,
            sourceDacpac: source.dacpacURL ?? url.appendingPathComponent("source.dacpac"),
            targetDacpac: target.dacpacURL ?? url.appendingPathComponent("target.dacpac"),
            targetDatabaseName: target.databaseName
        )
    }

    /// เขียน argument ลง response file แล้วส่งเป็น `@file`
    ///
    /// connection string มีรหัสผ่านอยู่ด้วย — การส่งผ่านไฟล์สิทธิ์ 0600 ทำให้รหัสผ่าน
    /// ไม่โผล่ใน process list ของเครื่อง เหมือนที่ฝั่ง sqlcmd ใช้ `SQLCMDPASSWORD`
    @discardableResult
    private func runSqlPackage(
        arguments: [String],
        configuration: SQLConnectionConfiguration?,
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

        // Serialize starting with cancel(): cancellation must not miss a not-yet-running process.
        processLock.lock()
        guard !isCancelled else {
            processLock.unlock()
            throw CompareAppError.operationCancelled
        }
        do {
            try process.run()
            runningProcess = process
            processLock.unlock()
        } catch {
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

    /// `configuration` เป็น `nil` ใน stage ที่ไม่ได้ต่อ database (Script แบบ dacpac ต่อ dacpac)
    static func diagnose(rawMessage: String, stage: String, configuration: SQLConnectionConfiguration?) -> String {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()

        if lowered.contains("login failed for user") {
            return """
            \(message)

            Diagnosis (\(stage)):
            - SQL login หรือ password ไม่ถูกต้อง
            - หรือ login `\(configuration?.username ?? "(unknown)")` ไม่มีสิทธิ์ในฐานข้อมูลนี้
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
            if let configuration, configuration.isLocalServer {
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
            - login ผ่านแล้ว แต่ไม่มีสิทธิ์เข้า database `\(configuration?.database ?? "(unknown)")`
            - หรือชื่อ database ไม่ถูกต้อง
            """
        }

        return message.isEmpty ? "sqlpackage จบการทำงานด้วย error โดยไม่มีข้อความ (\(stage))" : message
    }
}

/// รวบรวม stdout/stderr แบบ thread-safe และส่งบรรทัดล่าสุดออกไปเป็น progress
/// ใช้ร่วมกันระหว่าง `SqlPackageService` กับ `DacFxScriptService`
nonisolated final class OutputCollector: @unchecked Sendable {
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
