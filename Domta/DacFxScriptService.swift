//
//  DacFxScriptService.swift
//  Domta
//

import Foundation

/// object ที่ผู้ใช้ไม่ได้ติ๊ก แต่ DacFx เก็บไว้ใน script เพราะ object ที่ติ๊กต้องพึ่งมัน
nonisolated struct DacFxForcedObject: Decodable, Hashable, Sendable {
    let key: String
    let type: String
    let action: String
}

/// ผลจาก helper: script ของ object ที่เลือก พร้อมสิ่งที่ DacFx ตัดสินใจเพิ่มเติม
nonisolated struct DacFxScriptOutcome: Sendable {
    let script: String
    let included: [String]
    let forcedIncluded: [DacFxForcedObject]
    let excludedCount: Int
    let differenceCount: Int
    let warnings: [String]
}

/// CREATE script ของ object หนึ่งตัวจาก dacpac ทั้งสองฝั่ง — `nil` ฝั่งที่ไม่มี object นี้
nonisolated struct DacFxObjectDefinition: Decodable, Sendable {
    let key: String
    let source: String?
    let target: String?
}

/// รัน helper .NET (`DacFxHelperSource`) ด้วย `dotnet run` เพื่อออก script เฉพาะ object ที่เลือก
/// และอ่าน definition ของ object จาก dacpac
///
/// ทำงานกับ dacpac สองไฟล์ที่ extract ไว้ตอน compare — ไม่แตะ database อีกเลย จึงไม่มีปัญหา
/// "target database was modified after schema comparison was completed" ที่ Compare API ของ DacFx
/// ฟ้องเมื่อ target ถูกแตะระหว่าง Compare กับ GenerateScript (เช่น job ของแอปที่รันอยู่บน target)
nonisolated final class DacFxScriptService: @unchecked Sendable {
    private struct Request: Encodable {
        let mode: String
        let sourceDacpac: String
        let targetDacpac: String
        let targetDatabaseName: String
        let options: RequestOptions?
        let includedObjects: [String]
        let outputScript: String
        let outputResult: String
    }

    private struct RequestOptions: Encodable {
        let dropObjectsNotInSource: Bool
        let blockOnPossibleDataLoss: Bool
        let ignorePermissions: Bool
        let ignoreUserSettingsObjects: Bool
        let ignoreExtendedProperties: Bool
        let ignoreWhitespace: Bool
        let ignoreComments: Bool
        let excludeObjectTypes: [String]
    }

    private struct Response: Decodable {
        let success: Bool
        let message: String
        let differenceCount: Int
        let excludedCount: Int
        let included: [String]
        let forcedIncluded: [DacFxForcedObject]
        let warnings: [String]
        let definitions: [DacFxObjectDefinition]?
    }

    /// `dotnet run` ของไฟล์ .cs เดียวกันสองตัวพร้อมกันแย่ง build output กัน — การดู definition กับ
    /// การออก script อาจเริ่มพร้อมกันได้ จึงให้ helper รันทีละตัวทั้งแอป
    private static let helperRunLock = NSLock()

    private let processLock = NSLock()
    private var runningProcess: Process?
    private var isCancelled = false

    // MARK: - Tool discovery

    nonisolated func resolvedDotnetURL() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let pathVariable = ProcessInfo.processInfo.environment["PATH"] ?? ""

        let candidates = pathVariable
            .split(separator: ":")
            .map { String($0) + "/dotnet" } + [
                "/usr/local/share/dotnet/dotnet",
                "\(home)/.dotnet/dotnet",
                "/opt/homebrew/bin/dotnet",
                "/usr/local/bin/dotnet"
            ]

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        return nil
    }

    var isAvailable: Bool {
        resolvedDotnetURL() != nil
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

    private var cancellationRequested: Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return isCancelled
    }

    // MARK: - Generate

    nonisolated func generateScript(
        workspace: SchemaCompareWorkspace,
        options: SchemaCompareOptions,
        includedObjectKeys: [String],
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> DacFxScriptOutcome {
        let outcome = try runHelper(workspace: workspace, progress: progress) { scriptURL, resultURL in
            Request(
                mode: "script",
                sourceDacpac: workspace.sourceDacpac.path,
                targetDacpac: workspace.targetDacpac.path,
                targetDatabaseName: workspace.targetDatabaseName,
                options: RequestOptions(
                    dropObjectsNotInSource: options.reportObjectsOnlyInTarget,
                    blockOnPossibleDataLoss: options.blockOnPossibleDataLoss,
                    ignorePermissions: options.ignorePermissions,
                    ignoreUserSettingsObjects: options.ignoreUserSettingsObjects,
                    ignoreExtendedProperties: options.ignoreExtendedProperties,
                    ignoreWhitespace: options.ignoreWhitespaceInModules,
                    ignoreComments: options.ignoreWhitespaceInModules,
                    excludeObjectTypes: options.excludedObjectTypes
                ),
                includedObjects: includedObjectKeys,
                outputScript: scriptURL.path,
                outputResult: resultURL.path
            )
        }

        return DacFxScriptOutcome(
            script: outcome.script,
            included: outcome.response.included,
            forcedIncluded: outcome.response.forcedIncluded,
            excludedCount: outcome.response.excludedCount,
            differenceCount: outcome.response.differenceCount,
            warnings: outcome.response.warnings
        )
    }

    // MARK: - Definitions

    /// CREATE script ของ object ตาม key (`schema.object` ตัวพิมพ์เล็ก) จาก dacpac ทั้งสองฝั่ง
    ///
    /// ใช้แสดง Comparison Details เมื่อฝั่งใดเป็นไฟล์ dacpac ซึ่ง query ด้วย sqlcmd ไม่ได้ — อ่านจาก
    /// DacFx ทั้งสองฝั่งเสมอ เพราะถ้าผสมกับ definition ที่ประกอบจาก `sys.columns` รูปแบบจะต่างกันทุกบรรทัด
    nonisolated func loadDefinitions(
        workspace: SchemaCompareWorkspace,
        objectKeys: [String],
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> [String: DacFxObjectDefinition] {
        let outcome = try runHelper(workspace: workspace, progress: progress) { scriptURL, resultURL in
            Request(
                mode: "definitions",
                sourceDacpac: workspace.sourceDacpac.path,
                targetDacpac: workspace.targetDacpac.path,
                targetDatabaseName: workspace.targetDatabaseName,
                options: nil,
                includedObjects: objectKeys,
                outputScript: scriptURL.path,
                outputResult: resultURL.path
            )
        }

        let definitions = outcome.response.definitions ?? []
        return Dictionary(definitions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Process execution

    /// เขียน request แล้วรัน helper หนึ่งรอบ — คืน response ที่สำเร็จแล้วพร้อม script ที่ helper เขียนไว้
    private nonisolated func runHelper(
        workspace: SchemaCompareWorkspace,
        progress: (@Sendable (String) -> Void)?,
        makeRequest: (_ scriptURL: URL, _ resultURL: URL) -> Request
    ) throws -> (response: Response, script: String) {
        processLock.lock()
        isCancelled = false
        processLock.unlock()

        guard let dotnetURL = resolvedDotnetURL() else {
            throw CompareAppError.dotnetNotFound
        }

        Self.helperRunLock.lock()
        defer { Self.helperRunLock.unlock() }

        // ผู้ใช้ยกเลิกระหว่างรอ helper ตัวก่อนหน้า — ไม่ต้องเริ่ม
        if cancellationRequested {
            throw CompareAppError.operationCancelled
        }

        let helperURL = try installedHelperURL()

        let runID = UUID().uuidString
        let requestURL = workspace.directory.appendingPathComponent("dacfx-request-\(runID).json")
        let scriptURL = workspace.directory.appendingPathComponent("dacfx-script-\(runID).sql")
        let resultURL = workspace.directory.appendingPathComponent("dacfx-result-\(runID).json")
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: resultURL)
        }

        do {
            let data = try JSONEncoder().encode(makeRequest(scriptURL, resultURL))
            try data.write(to: requestURL, options: .atomic)
        } catch {
            throw CompareAppError.dacFxHelperFailed("เขียน request ให้ helper ไม่สำเร็จ: \(error.localizedDescription)")
        }

        progress?("กำลังรัน DacFx helper (ครั้งแรกจะดาวน์โหลด package Microsoft.SqlServer.DacFx สักครู่)...")

        let process = Process()
        process.executableURL = dotnetURL
        process.arguments = ["run", helperURL.path, "--", requestURL.path]
        process.currentDirectoryURL = helperURL.deletingLastPathComponent()

        var environment = ProcessInfo.processInfo.environment
        environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        environment["DOTNET_NOLOGO"] = "1"
        environment["DOTNET_CLI_UI_LANGUAGE"] = "en"
        process.environment = environment

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
            throw CompareAppError.dacFxHelperFailed("เรียก dotnet ไม่สำเร็จ: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        collector.appendStandardOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
        collector.appendStandardError(errorPipe.fileHandleForReading.readDataToEndOfFile())

        processLock.lock()
        runningProcess = nil
        processLock.unlock()

        if cancellationRequested {
            throw CompareAppError.operationCancelled
        }

        // helper เขียน result.json แม้ตอนล้มเหลว — ข้อความในนั้นตรงประเด็นกว่า stderr ของ dotnet
        let response = try? JSONDecoder().decode(Response.self, from: Data(contentsOf: resultURL))

        guard process.terminationStatus == 0, let response, response.success else {
            let detail = response?.message
                ?? Self.summarize(standardError: collector.standardErrorText, standardOutput: collector.standardOutputText)
            throw CompareAppError.dacFxHelperFailed(detail)
        }

        let script = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
        return (response, script)
    }

    /// เขียน helper ลง `~/Library/Application Support/Domta/DacFxHelper/` เมื่อยังไม่มีหรือเนื้อหาไม่ตรง
    ///
    /// path คงที่สำคัญ: `dotnet run <file>.cs` cache ผลคอมไพล์ตาม path ของไฟล์ — ถ้าเขียนลง temp
    /// ใหม่ทุกครั้งจะเสียเวลา restore + build ราว 10 วินาทีทุกรอบ
    private nonisolated func installedHelperURL() throws -> URL {
        let fileManager = FileManager.default

        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CompareAppError.dacFxHelperFailed("หาโฟลเดอร์ Application Support ไม่พบ")
        }

        let directory = supportDirectory
            .appendingPathComponent("Domta", isDirectory: true)
            .appendingPathComponent("DacFxHelper", isDirectory: true)
        let fileURL = directory.appendingPathComponent(DacFxHelperSource.fileName)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let existing = try? String(contentsOf: fileURL, encoding: .utf8)
            if existing != DacFxHelperSource.text {
                try DacFxHelperSource.text.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            throw CompareAppError.dacFxHelperFailed("เขียนไฟล์ helper ไม่สำเร็จ: \(error.localizedDescription)")
        }

        return fileURL
    }

    private static func summarize(standardError: String, standardOutput: String) -> String {
        let combined = (standardError + "\n" + standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return "dotnet จบการทำงานด้วย error โดยไม่มีข้อความ" }

        // เอาเฉพาะบรรทัดที่มีสาระ — ตัด warning ของ compiler และบรรทัดว่าง
        let lines = combined
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(": warning ") }

        return lines.suffix(12).joined(separator: "\n")
    }
}
