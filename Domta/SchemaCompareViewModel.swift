//
//  SchemaCompareViewModel.swift
//  Domta
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SchemaCompareViewModel: ObservableObject {
    @Published var options = SchemaCompareOptions()
    @Published var report: SchemaCompareReport?
    @Published var isBusy = false
    @Published var progressState: ProgressState?
    @Published var operationStartedAt: Date?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    @Published var searchText = ""
    @Published var categoryFilter: SchemaObjectCategory?
    @Published var kindFilter: SchemaChangeKind?
    @Published var selectedRowID: SchemaCompareRow.ID?
    @Published var includedRowIDs: Set<SchemaCompareRow.ID> = []
    @Published var definitionState: SchemaDefinitionState = .idle
    @Published var diffViewMode: SchemaDiffViewMode = .sideBySide
    @Published var showsFullScript = false
    @Published var scriptFormat: SchemaScriptFormat = .plainTSQL
    @Published private(set) var scriptFilter: DeploymentScriptFilterResult?
    @Published private(set) var selectedScriptState: SelectedScriptState = .idle

    private let sqlPackageService = SqlPackageService()
    private let sqlCmdService = SQLCmdService()
    private let dacFxService = DacFxScriptService()
    private let definitionService = DacFxScriptService()
    /// definition จาก dacpac ของ report ปัจจุบัน — helper อ่านทุก object รอบเดียวแล้วใช้ซ้ำทุกแถว
    private var dacpacDefinitionsTask: Task<[String: DacFxObjectDefinition], Error>?
    private var definitionTaskToken = 0
    private var scriptTaskToken = 0
    /// selection ที่ script ปัจจุบันถูกออกมาให้ — เปลี่ยนติ๊กแล้วกลับมาหน้า script จะออกใหม่
    private var scriptSelection: Set<SchemaCompareRow.ID>?

    // MARK: - Tool availability

    var sqlPackagePath: String? {
        sqlPackageService.resolvedSqlPackageURL()?.path
    }

    var isSqlPackageAvailable: Bool {
        sqlPackagePath != nil
    }

    var isDotnetAvailable: Bool {
        dacFxService.isAvailable
    }

    // MARK: - Derived state

    var differences: [SchemaDifference] {
        report?.differences ?? []
    }

    /// ทุกความต่างที่ยุบเป็นระดับ object แล้ว — หนึ่งแถวต่อหนึ่ง object
    var rows: [SchemaCompareRow] {
        SchemaCompareRow.rows(from: differences)
    }

    var filteredRows: [SchemaCompareRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return rows.filter { row in
            if let categoryFilter, row.category != categoryFilter { return false }
            if let kindFilter, row.kind != kindFilter { return false }
            guard !query.isEmpty else { return true }

            return row.plainName.localizedCaseInsensitiveContains(query)
                || row.typeDisplay.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Row inclusion

    /// ติ๊กทุกแถวไว้ตั้งแต่แรกเหมือน mssql extension แล้วให้ผู้ใช้เอาที่ไม่ต้องการออก
    func toggleInclusion(_ row: SchemaCompareRow) {
        if includedRowIDs.contains(row.id) {
            includedRowIDs.remove(row.id)
        } else {
            includedRowIDs.insert(row.id)
        }
    }

    /// checkbox บนหัวตาราง — ทำงานกับแถวที่ตัวกรองแสดงอยู่เท่านั้น
    func setInclusionForVisibleRows(_ isIncluded: Bool) {
        let visible = filteredRows.map(\.id)

        if isIncluded {
            includedRowIDs.formUnion(visible)
        } else {
            includedRowIDs.subtract(visible)
        }
    }

    var areAllVisibleRowsIncluded: Bool {
        let visible = filteredRows
        return !visible.isEmpty && visible.allSatisfy { includedRowIDs.contains($0.id) }
    }

    var includedRows: [SchemaCompareRow] {
        rows.filter { includedRowIDs.contains($0.id) }
    }

    var hasIncludedRows: Bool { !includedRowIDs.isEmpty }

    func count(for category: SchemaObjectCategory) -> Int {
        rows.filter { $0.category == category }.count
    }

    func count(for kind: SchemaChangeKind) -> Int {
        rows.filter { $0.kind == kind }.count
    }

    var populatedCategories: [SchemaObjectCategory] {
        SchemaObjectCategory.allCases.filter { count(for: $0) > 0 }
    }

    var selectedRow: SchemaCompareRow? {
        guard let selectedRowID else { return nil }
        return rows.first { $0.id == selectedRowID }
    }

    var generatedScript: String {
        report?.script ?? ""
    }

    var hasScript: Bool {
        !generatedScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// script ที่แสดงและคัดลอกจริง — ค่าเริ่มต้นคือเฉพาะ object ที่ติ๊กไว้ ในรูป T-SQL ล้วน
    var displayedScript: String {
        let base: String
        if showsFullScript {
            base = generatedScript
        } else if let result = selectedScriptState.result {
            base = result.script
        } else {
            base = ""
        }

        switch scriptFormat {
        case .plainTSQL:
            return DeploymentScriptSanitizer.plainTSQL(base).script
        case .sqlcmd:
            return base
        }
    }

    /// คัดลอก/บันทึกได้เมื่อมี script และไม่ได้กำลังออก script อยู่
    var canExportScript: Bool {
        !selectedScriptState.isGenerating && !displayedScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// key ที่ helper ใช้จับคู่กับ difference ของ DacFx — `schema.object` ตัวพิมพ์เล็ก
    /// (object ที่ไม่มี schema เช่น `SqlSchema` ใช้ชื่อเดี่ยว ๆ ตรงกับ name parts ของ DacFx)
    static func objectKey(for row: SchemaCompareRow) -> String {
        objectKey(schemaName: row.schemaName, objectName: row.objectName)
    }

    static func objectKey(schemaName: String, objectName: String) -> String {
        let object = objectName.lowercased()
        return schemaName.isEmpty ? object : "\(schemaName.lowercased()).\(object)"
    }

    /// ออก script เฉพาะ object ที่ติ๊กไว้ — เรียกก่อนเปิดหน้า script ทุกครั้ง
    ///
    /// ทางหลักคือ DacFx helper (exclude แล้วให้ DacFx ลาก dependency มาเอง) ถ้า helper ใช้ไม่ได้
    /// จะถอยไปใช้ตัวตัด script แบบข้อความ พร้อมบอกเหตุผล — script ทางสำรองอาจรันไม่ผ่านถ้าติด dependency
    func prepareScript() {
        guard let report else {
            scriptFilter = nil
            selectedScriptState = .idle
            scriptSelection = nil
            return
        }

        let selection = includedRowIDs
        if scriptSelection == selection, selectedScriptState.result != nil || selectedScriptState.isGenerating {
            return
        }

        let allRows = rows
        let knownNames = Set(allRows.map(Self.objectKey))
        let includedKeys = allRows.filter { selection.contains($0.id) }.map(Self.objectKey)

        let fallback = DeploymentScriptFilter.filter(
            script: report.script,
            includedNames: Set(includedKeys),
            knownNames: knownNames
        )
        scriptFilter = fallback
        scriptSelection = selection
        scriptTaskToken += 1
        let token = scriptTaskToken

        // ไม่ได้ติ๊กอะไรเลย — ไม่ต้องรัน helper (DacFx ถือว่า "ไม่มีอะไรจะ deploy" เป็น error)
        guard !includedKeys.isEmpty else {
            selectedScriptState = .ready(
                SelectedScriptResult(
                    script: "-- No objects selected: nothing to deploy.\n",
                    source: .dacFx,
                    included: [],
                    forcedIncluded: [],
                    excludedCount: allRows.count,
                    differenceCount: allRows.count,
                    warnings: [],
                    fallbackReason: nil,
                    filter: nil
                )
            )
            return
        }

        guard dacFxService.isAvailable else {
            selectedScriptState = .ready(Self.fallbackResult(fallback, reason: CompareAppError.dotnetNotFound.localizedDescription))
            return
        }

        selectedScriptState = .generating("กำลังให้ DacFx ออก script สำหรับ \(includedKeys.count) object...")

        let service = dacFxService
        let workspace = report.workspace
        let currentOptions = options

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try service.generateScript(
                        workspace: workspace,
                        options: currentOptions,
                        includedObjectKeys: includedKeys,
                        progress: { message in
                            Task { @MainActor in
                                guard token == self.scriptTaskToken else { return }
                                self.selectedScriptState = .generating(message)
                            }
                        }
                    )
                }.value

                guard token == scriptTaskToken else { return }
                selectedScriptState = .ready(
                    SelectedScriptResult(
                        script: outcome.script,
                        source: .dacFx,
                        included: outcome.included,
                        forcedIncluded: outcome.forcedIncluded,
                        excludedCount: outcome.excludedCount,
                        differenceCount: outcome.differenceCount,
                        warnings: outcome.warnings,
                        fallbackReason: nil,
                        filter: nil
                    )
                )
            } catch {
                guard token == scriptTaskToken else { return }
                selectedScriptState = .ready(Self.fallbackResult(fallback, reason: error.localizedDescription))
            }
        }
    }

    private static func fallbackResult(_ filter: DeploymentScriptFilterResult, reason: String) -> SelectedScriptResult {
        SelectedScriptResult(
            script: filter.script,
            source: .textFilter,
            included: [],
            forcedIncluded: [],
            excludedCount: filter.removedSectionCount,
            differenceCount: filter.keptSectionCount + filter.removedSectionCount,
            warnings: [],
            fallbackReason: reason,
            filter: filter
        )
    }

    var operationElapsedText: String? {
        guard let operationStartedAt else { return nil }
        let elapsed = Int(Date().timeIntervalSince(operationStartedAt))
        return elapsed < 60 ? "\(elapsed)s elapsed" : "\(elapsed / 60)m \(elapsed % 60)s elapsed"
    }

    // MARK: - Compare

    func compareSchema(source: SchemaCompareEndpoint, target: SchemaCompareEndpoint, onSuccess: (() -> Void)? = nil) {
        guard !isBusy else { return }

        guard options.hasSelectedCategory else {
            errorMessage = "เลือกอย่างน้อยหนึ่งกลุ่ม object ใน Options ก่อนเริ่ม compare"
            return
        }

        let service = sqlPackageService
        let currentOptions = options

        isBusy = true
        operationStartedAt = Date()
        errorMessage = nil
        statusMessage = "กำลังเทียบ schema ด้วย sqlpackage..."
        progressState = ProgressState(
            message: "Preparing schema compare...",
            completedUnitCount: 0,
            totalUnitCount: 3,
            showsIndeterminateSpinner: true
        )
        discardScriptWork()
        report = nil
        selectedRowID = nil
        includedRowIDs = []
        definitionState = .idle

        Task {
            defer { isBusy = false }

            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try service.compareSchema(
                        source: source,
                        target: target,
                        options: currentOptions,
                        progress: { state in
                            Task { @MainActor in
                                self.progressState = state
                            }
                        }
                    )
                }.value

                report = outcome
                includedRowIDs = Set(rows.map(\.id))
                progressState = nil
                operationStartedAt = nil
                statusMessage = outcome.isEmpty
                    ? "schema ทั้งสองฝั่งตรงกันแล้ว ไม่พบความต่าง"
                    : "พบ \(rows.count) object ที่ต่างกัน"
                onSuccess?()
            } catch {
                report = nil
                progressState = nil
                operationStartedAt = nil
                statusMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelCompare() {
        guard isBusy else { return }
        sqlPackageService.cancel()
        statusMessage = "กำลังยกเลิก..."
    }

    func clearReport() {
        discardScriptWork()
        report = nil
        selectedRowID = nil
        includedRowIDs = []
        scriptFilter = nil
        searchText = ""
        categoryFilter = nil
        kindFilter = nil
        definitionState = .idle
        statusMessage = nil
        errorMessage = nil
    }

    /// หยุด helper ที่อาจกำลังรัน ลบ dacpac ของรอบก่อน และล้างสถานะ script กับ definition ที่อ่านจาก dacpac
    private func discardScriptWork() {
        scriptTaskToken += 1
        definitionTaskToken += 1
        dacFxService.cancel()
        definitionService.cancel()
        dacpacDefinitionsTask = nil
        report?.workspace.cleanUp()
        selectedScriptState = .idle
        scriptSelection = nil
        scriptFilter = nil
    }

    // MARK: - Filtering

    func setCategoryFilter(_ category: SchemaObjectCategory?) {
        categoryFilter = (categoryFilter == category) ? nil : category
    }

    func setKindFilter(_ kind: SchemaChangeKind?) {
        kindFilter = (kindFilter == kind) ? nil : kind
    }

    // MARK: - Definition detail

    func select(row: SchemaCompareRow, source: SchemaCompareEndpoint, target: SchemaCompareEndpoint) {
        selectedRowID = row.id
        loadDefinition(for: row.representative, source: source, target: target)
    }

    private func selectFirstRow(source: SchemaCompareEndpoint, target: SchemaCompareEndpoint) {
        guard let first = filteredRows.first else { return }
        select(row: first, source: source, target: target)
    }

    func toggleCategory(_ category: SchemaObjectCategory) {
        if options.selectedCategories.contains(category) {
            options.selectedCategories.remove(category)
        } else {
            options.selectedCategories.insert(category)
        }
    }

    /// ดึง definition สองฝั่งมาเทียบ — object ที่มีฝั่งเดียวจะได้ `nil` อีกฝั่งซึ่งถูกต้องอยู่แล้ว
    ///
    /// ทั้งสองฝั่งเป็น database จะ query ผ่าน sqlcmd ถ้ามีฝั่งใดเป็นไฟล์ dacpac จะอ่านจาก dacpac ด้วย DacFx ทั้งคู่
    func loadDefinition(for difference: SchemaDifference, source: SchemaCompareEndpoint, target: SchemaCompareEndpoint) {
        guard difference.category.supportsDefinitionDiff else {
            definitionState = .unsupported("object ชนิด \(difference.typeDisplay) ยังไม่รองรับการดู definition — ดูรายละเอียดได้จาก deployment script")
            return
        }

        definitionTaskToken += 1
        let token = definitionTaskToken
        definitionState = .loading

        guard let sourceInput = source.connectionInput, let targetInput = target.connectionInput else {
            loadDacpacDefinition(for: difference, token: token)
            return
        }

        let service = sqlCmdService

        Task {
            do {
                let definition = try await Task.detached(priority: .userInitiated) { () -> SchemaObjectDefinition in
                    let sourceText = try service.loadObjectDefinition(sourceInput, difference: difference)
                    let targetText = try service.loadObjectDefinition(targetInput, difference: difference)
                    return SchemaDiffEngine.diff(sourceText: sourceText, targetText: targetText)
                }.value

                guard token == definitionTaskToken else { return }
                definitionState = .loaded(definition)
            } catch {
                guard token == definitionTaskToken else { return }
                definitionState = .failed(error.localizedDescription)
            }
        }
    }

    /// อ่าน definition ของทุก object ที่ดูได้จาก dacpac ทั้งสองฝั่งในการรัน helper ครั้งแรก แล้วเก็บไว้ใช้กับแถวต่อ ๆ ไป
    private func loadDacpacDefinition(for difference: SchemaDifference, token: Int) {
        guard let report else {
            definitionState = .idle
            return
        }

        let definitionsTask: Task<[String: DacFxObjectDefinition], Error>
        if let existing = dacpacDefinitionsTask {
            definitionsTask = existing
        } else {
            let service = definitionService
            let workspace = report.workspace
            let keys = rows.filter { $0.category.supportsDefinitionDiff }.map { Self.objectKey(for: $0) }

            definitionsTask = Task.detached(priority: .userInitiated) {
                try service.loadDefinitions(workspace: workspace, objectKeys: keys)
            }
            dacpacDefinitionsTask = definitionsTask
        }

        let key = Self.objectKey(schemaName: difference.schemaName, objectName: difference.objectName)

        Task {
            do {
                let definitions = try await definitionsTask.value
                guard token == definitionTaskToken else { return }

                guard let entry = definitions[key] else {
                    definitionState = .unsupported("DacFx ไม่มี script ของ \(difference.plainName) ใน dacpac ทั้งสองฝั่ง — ดูรายละเอียดได้จาก deployment script")
                    return
                }

                let definition = await Task.detached(priority: .userInitiated) {
                    SchemaDiffEngine.diff(sourceText: entry.source, targetText: entry.target)
                }.value

                guard token == definitionTaskToken else { return }
                definitionState = .loaded(definition)
            } catch {
                // ไม่เก็บรอบที่ล้มเหลวไว้ — คลิกแถวครั้งถัดไปจะรัน helper ใหม่
                if dacpacDefinitionsTask == definitionsTask {
                    dacpacDefinitionsTask = nil
                }
                guard token == definitionTaskToken else { return }
                definitionState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Script output

    func copyScriptToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayedScript, forType: .string)
        statusMessage = "คัดลอก deployment script ไปที่ clipboard แล้ว"
    }

    func saveScriptToFile() {
        guard canExportScript else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "domta-schema-\(Self.fileTimestamp()).sql"
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try displayedScript.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "บันทึก script ไปที่ \(url.lastPathComponent) แล้ว"
        } catch {
            errorMessage = "บันทึกไฟล์ไม่สำเร็จ: \(error.localizedDescription)"
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
