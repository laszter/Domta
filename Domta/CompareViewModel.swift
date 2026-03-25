//
//  CompareViewModel.swift
//  Domta
//
//  Created by Codex on 25/3/26.
//

import AppKit
import Combine
import Foundation

@MainActor
final class CompareViewModel: ObservableObject {
    private static let recentConnectionsKey = "domta.recent.connection.pairs"

    @Published var sourceConnectionString: String = ""
    @Published var targetConnectionString: String = ""
    @Published var recentConnectionPairs: [RecentConnectionPair] = []
    @Published var comparableTables: [ComparableTable] = []
    @Published var selectedTableKeys: Set<String> = []
    @Published var results: [TableCompareResult] = []
    @Published var generatedScript: String = ""
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var sourceTestMessage: String?
    @Published var targetTestMessage: String?
    @Published var isTestingSourceConnection = false
    @Published var isTestingTargetConnection = false
    @Published var progressState: ProgressState?
    @Published var activeOperationTitle: String?
    @Published var operationStartedAt: Date?
    @Published var isBusy = false

    private let service = SQLCmdService()

    init() {
        loadRecentConnections()
    }

    func loadComparableTables(onSuccess: (() -> Void)? = nil) {
        let source = sourceConnectionString
        let target = targetConnectionString
        let service = self.service

        saveCurrentConnectionPair()
        isBusy = true
        activeOperationTitle = "Loading Comparable Tables"
        operationStartedAt = Date()
        errorMessage = nil
        statusMessage = "กำลังอ่าน schema จาก source และ target..."
        progressState = ProgressState(message: "Preparing schema load...", completedUnitCount: 0, totalUnitCount: 0, showsIndeterminateSpinner: true)
        results = []
        generatedScript = ""

        Task {
            defer { isBusy = false }

            do {
                let tables = try await Task.detached(priority: .userInitiated) {
                    try service.loadSchemas(
                        source: source,
                        target: target,
                        progress: { state in
                            Task { @MainActor in
                                self.progressState = state
                            }
                        }
                    )
                }.value

                comparableTables = tables.sorted { $0.displayName < $1.displayName }
                selectedTableKeys = Set(comparableTables.map(\.id))
                progressState = nil
                activeOperationTitle = nil
                operationStartedAt = nil
                statusMessage = comparableTables.isEmpty
                    ? "ไม่พบตารางที่มี schema และ primary key ตรงกันทั้งสองฝั่ง"
                    : "พร้อม compare \(comparableTables.count) ตาราง"
                onSuccess?()
            } catch {
                errorMessage = error.localizedDescription
                comparableTables = []
                selectedTableKeys = []
                progressState = nil
                activeOperationTitle = nil
                operationStartedAt = nil
                statusMessage = nil
            }
        }
    }

    func selectAllTables() {
        selectedTableKeys = Set(comparableTables.map(\.id))
    }

    func clearSelection() {
        selectedTableKeys.removeAll()
    }

    func setSelection(for tableKey: String, isSelected: Bool) {
        if isSelected {
            selectedTableKeys.insert(tableKey)
        } else {
            selectedTableKeys.remove(tableKey)
        }
    }

    func compareSelectedTables(onSuccess: (() -> Void)? = nil) {
        let selectedSchemas = comparableTables
            .filter { selectedTableKeys.contains($0.id) }
            .map(\.schema)
        let source = sourceConnectionString
        let target = targetConnectionString
        let service = self.service

        guard !selectedSchemas.isEmpty else { return }

        isBusy = true
        activeOperationTitle = "Comparing Selected Tables"
        operationStartedAt = Date()
        errorMessage = nil
        statusMessage = "กำลัง compare ข้อมูล \(selectedSchemas.count) ตาราง..."
        progressState = ProgressState(message: "Preparing compare...", completedUnitCount: 0, totalUnitCount: 0, showsIndeterminateSpinner: true)
        results = []
        generatedScript = ""

        Task {
            defer { isBusy = false }

            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try service.compareTables(
                        source: source,
                        target: target,
                        schemas: selectedSchemas,
                        progress: { state in
                            Task { @MainActor in
                                self.progressState = state
                            }
                        }
                    )
                }.value

                results = outcome.results
                generatedScript = outcome.script
                progressState = nil
                activeOperationTitle = nil
                operationStartedAt = nil
                let totalChanges = results.reduce(0) { partial, item in
                    partial + item.insertCount + item.updateCount + item.deleteCount
                }
                statusMessage = "compare เสร็จแล้ว พบความต่าง \(totalChanges) รายการ"
                onSuccess?()
            } catch {
                errorMessage = error.localizedDescription
                progressState = nil
                activeOperationTitle = nil
                operationStartedAt = nil
                statusMessage = nil
            }
        }
    }

    func copyScriptToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(generatedScript, forType: .string)
        statusMessage = "คัดลอก script ไปที่ clipboard แล้ว"
    }

    func applyRecentConnectionPair(_ pair: RecentConnectionPair) {
        sourceConnectionString = pair.sourceConnectionString
        targetConnectionString = pair.targetConnectionString
    }

    func clearRecentConnections() {
        recentConnectionPairs = []
        UserDefaults.standard.removeObject(forKey: Self.recentConnectionsKey)
        statusMessage = "ล้าง recent connections แล้ว"
    }

    func revealPreferencesFile() {
        let url = preferencesFileURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func toggleSelection(for tableID: String) {
        setSelection(for: tableID, isSelected: !selectedTableKeys.contains(tableID))
    }

    func resetTableSelectionState() {
        comparableTables = []
        selectedTableKeys = []
    }

    func clearCompareResultState() {
        results = []
        generatedScript = ""
    }

    func testSourceConnection() {
        testConnection(
            sourceConnectionString,
            label: "Source",
            setTesting: { [weak self] isTesting in
                self?.isTestingSourceConnection = isTesting
            }
        ) { [weak self] message in
            self?.sourceTestMessage = message
        }
    }

    func testTargetConnection() {
        testConnection(
            targetConnectionString,
            label: "Target",
            setTesting: { [weak self] isTesting in
                self?.isTestingTargetConnection = isTesting
            }
        ) { [weak self] message in
            self?.targetTestMessage = message
        }
    }

    private func testConnection(
        _ connectionString: String,
        label: String,
        setTesting: @escaping @MainActor (Bool) -> Void,
        assign: @escaping @MainActor (String) -> Void
    ) {
        let service = self.service

        Task { @MainActor in
            setTesting(true)
        }
        errorMessage = nil
        statusMessage = "กำลังทดสอบการเชื่อมต่อ \(label.lowercased())..."

        Task {
            defer {
                Task { @MainActor in
                    setTesting(false)
                }
            }

            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try service.testConnection(connectionString, label: label)
                }.value

                await assign(result.details)
                statusMessage = "\(label) connection ผ่านแล้ว"
            } catch {
                await assign(error.localizedDescription)
                statusMessage = "\(label) connection ไม่ผ่าน"
            }
        }
    }

    var operationElapsedText: String? {
        guard let operationStartedAt else { return nil }
        let elapsed = Int(Date().timeIntervalSince(operationStartedAt))
        return elapsed < 60 ? "\(elapsed)s elapsed" : "\(elapsed / 60)m \(elapsed % 60)s elapsed"
    }

    var preferencesFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Preferences")
            .appendingPathComponent("com.etc.Domta.plist")
    }

    private func saveCurrentConnectionPair() {
        let source = sourceConnectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetConnectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !target.isEmpty else { return }

        let pair = RecentConnectionPair(sourceConnectionString: source, targetConnectionString: target)
        recentConnectionPairs.removeAll { $0.sourceConnectionString == source && $0.targetConnectionString == target }
        recentConnectionPairs.insert(pair, at: 0)
        recentConnectionPairs = Array(recentConnectionPairs.prefix(8))
        persistRecentConnections()
    }

    private func loadRecentConnections() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentConnectionsKey),
              let decoded = try? JSONDecoder().decode([RecentConnectionPair].self, from: data) else {
            recentConnectionPairs = []
            return
        }

        recentConnectionPairs = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persistRecentConnections() {
        guard let data = try? JSONEncoder().encode(recentConnectionPairs) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentConnectionsKey)
    }
}
