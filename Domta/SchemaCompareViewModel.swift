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
    @Published private(set) var scriptFilter: DeploymentScriptFilterResult?

    private let sqlPackageService = SqlPackageService()
    private let sqlCmdService = SQLCmdService()
    private var definitionTaskToken = 0

    // MARK: - Tool availability

    var sqlPackagePath: String? {
        sqlPackageService.resolvedSqlPackageURL()?.path
    }

    var isSqlPackageAvailable: Bool {
        sqlPackagePath != nil
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

    /// script ที่แสดงและคัดลอกจริง — ค่าเริ่มต้นคือเฉพาะ object ที่ติ๊กไว้
    var displayedScript: String {
        guard !showsFullScript, let scriptFilter else { return generatedScript }
        return scriptFilter.script
    }

    /// ตัด script ให้เหลือเฉพาะ object ที่ติ๊กไว้ — เรียกก่อนเปิดหน้า script ทุกครั้ง
    func prepareScript() {
        guard let report else {
            scriptFilter = nil
            return
        }

        let allRows = rows
        let knownNames = Set(allRows.map { "\($0.schemaName.lowercased()).\($0.objectName.lowercased())" })
        let includedNames = Set(
            allRows
                .filter { includedRowIDs.contains($0.id) }
                .map { "\($0.schemaName.lowercased()).\($0.objectName.lowercased())" }
        )

        scriptFilter = DeploymentScriptFilter.filter(
            script: report.script,
            includedNames: includedNames,
            knownNames: knownNames
        )
    }

    var operationElapsedText: String? {
        guard let operationStartedAt else { return nil }
        let elapsed = Int(Date().timeIntervalSince(operationStartedAt))
        return elapsed < 60 ? "\(elapsed)s elapsed" : "\(elapsed / 60)m \(elapsed % 60)s elapsed"
    }

    // MARK: - Compare

    func compareSchema(source: ConnectionInput, target: ConnectionInput, onSuccess: (() -> Void)? = nil) {
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

    // MARK: - Filtering

    func setCategoryFilter(_ category: SchemaObjectCategory?) {
        categoryFilter = (categoryFilter == category) ? nil : category
    }

    func setKindFilter(_ kind: SchemaChangeKind?) {
        kindFilter = (kindFilter == kind) ? nil : kind
    }

    // MARK: - Definition detail

    func select(row: SchemaCompareRow, source: ConnectionInput, target: ConnectionInput) {
        selectedRowID = row.id
        loadDefinition(for: row.representative, source: source, target: target)
    }

    private func selectFirstRow(source: ConnectionInput, target: ConnectionInput) {
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
    func loadDefinition(for difference: SchemaDifference, source: ConnectionInput, target: ConnectionInput) {
        guard difference.category.supportsDefinitionDiff else {
            definitionState = .unsupported("object ชนิด \(difference.typeDisplay) ยังไม่รองรับการดู definition — ดูรายละเอียดได้จาก deployment script")
            return
        }

        definitionTaskToken += 1
        let token = definitionTaskToken
        let service = sqlCmdService
        definitionState = .loading

        Task {
            do {
                let definition = try await Task.detached(priority: .userInitiated) { () -> SchemaObjectDefinition in
                    let sourceText = try service.loadObjectDefinition(source, difference: difference)
                    let targetText = try service.loadObjectDefinition(target, difference: difference)
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

    // MARK: - Script output

    func copyScriptToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayedScript, forType: .string)
        statusMessage = "คัดลอก deployment script ไปที่ clipboard แล้ว"
    }

    func saveScriptToFile() {
        guard hasScript else { return }

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
