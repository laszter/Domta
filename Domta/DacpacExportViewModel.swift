import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class DacpacExportViewModel: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    @Published private(set) var exportedURL: URL?
    @Published private(set) var exportingLabel = ""
    private var service: SqlPackageService?

    func chooseDestinationAndExport(input: ConnectionInput, side: String) {
        guard !isExporting else { return }
        do {
            let configuration = try ConnectionStringParser.validatedConfiguration(from: input)
            guard let database = configuration.database, !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CompareAppError.invalidConnectionString("ระบุ Database หรือ Initial Catalog ก่อน export DACPAC")
            }
            let exporter = SqlPackageService()
            guard exporter.resolvedSqlPackageURL() != nil else { throw CompareAppError.sqlPackageNotFound }

            if isError { message = nil; isError = false }
            let panel = NSSavePanel()
            panel.title = "Export \(side) DACPAC"
            panel.message = "\(database) · เฉพาะ schema ไม่รวมข้อมูลในตาราง"
            panel.allowedContentTypes = [UTType(filenameExtension: "dacpac", conformingTo: .data) ?? .data]
            panel.nameFieldStringValue = database.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "_") + ".dacpac"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }

            service = exporter
            isExporting = true
            isError = false
            exportedURL = nil
            exportingLabel = "\(side) · \(database)"
            message = "กำลังอ่าน schema…"
            Task {
                defer { isExporting = false; service = nil }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try exporter.exportDacpac(input: input, to: destination) { progress in
                            Task { @MainActor in
                                guard self.isExporting, self.service === exporter else { return }
                                self.message = progress
                            }
                        }
                    }.value
                    exportedURL = destination
                    message = "บันทึก \(destination.lastPathComponent) แล้ว · เฉพาะ schema ไม่รวม data"
                } catch CompareAppError.operationCancelled {
                    message = "ยกเลิก Export DACPAC แล้ว"
                } catch {
                    isError = true
                    message = error.localizedDescription
                }
            }
        } catch {
            isError = true
            exportedURL = nil
            message = error.localizedDescription
        }
    }

    func cancel() { service?.cancel() }

    func revealExport() {
        guard let exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
    }
}
