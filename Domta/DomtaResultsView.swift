import AppKit
import SwiftUI

private struct ComparePreviewSelection: Equatable {
    let tableID: TableCompareResult.ID
    let kind: SampleKind
}

private enum PreviewCellStyle: Equatable {
    case plain
    case sourceChanged
    case targetChanged
    case inserted
    case deleted

    func backgroundColor(_ scheme: ColorScheme) -> Color {
        switch self {
        case .plain:
            return .clear
        case .targetChanged, .deleted:
            return DomtaTheme.target(scheme).opacity(0.12)
        case .sourceChanged, .inserted:
            return DomtaTheme.source(scheme).opacity(0.12)
        }
    }
}

private struct ComparePreviewCellData: Identifiable, Equatable {
    let id: String
    let text: String
    let style: PreviewCellStyle
}

private struct ComparePreviewRowData: Identifiable, Equatable {
    let id: UUID
    let cells: [ComparePreviewCellData]
}

private struct ComparePreviewTableData: Equatable {
    let headers: [String]
    let rows: [ComparePreviewRowData]
}

private struct ComparePreviewRowView: View, Equatable {
    let row: ComparePreviewRowData
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: ComparePreviewRowView, rhs: ComparePreviewRowView) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(row.cells) { cell in
                Text(cell.text)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: 170, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 52, alignment: .leading)
                    .textSelection(.enabled)
                    .help(cell.text)
                    .background(
                        cell.style.backgroundColor(colorScheme).overlay(
                            Rectangle()
                                .stroke(DomtaTheme.rule(colorScheme).opacity(0.5), lineWidth: 0.5)
                        )
                    )
            }
        }
    }
}

struct DomtaResultsView: View {
    @ObservedObject var viewModel: CompareViewModel
    let onEditConnections: () -> Void
    let onChooseTables: () -> Void
    let onShowScript: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewSelection: ComparePreviewSelection?
    @State private var compareSplitRatio: CGFloat = 0.42
    @State private var compareSplitDragStartTopHeight: CGFloat?

    private var accent: Color { DomtaTheme.accent(colorScheme) }
    private var muted: Color { DomtaTheme.placeholder(colorScheme) }
    private var totalChanges: Int { viewModel.results.reduce(0) { $0 + $1.totalDiffCount } }
    private var tableCountLabel: String { "\(viewModel.results.count) \(viewModel.results.count == 1 ? "table" : "tables")" }
    private var resultSummary: String {
        if viewModel.isBusy { return "Comparison in progress" }
        if viewModel.errorMessage != nil { return "Comparison incomplete" }
        if viewModel.results.isEmpty { return "No comparison yet" }
        return "\(totalChanges) \(totalChanges == 1 ? "change" : "changes") · \(tableCountLabel)"
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                DomtaDataSidebar(viewModel: viewModel, step: .results, onEditConnections: onEditConnections, onChooseTables: onChooseTables)
                    .frame(width: geometry.size.width < 1200 ? 238 : 268)
                VStack(alignment: .leading, spacing: 20) {
                    workspaceHeader
                    if viewModel.isBusy {
                        operationStatus
                    }
                    if let error = viewModel.errorMessage {
                        errorState(error)
                    } else if viewModel.results.isEmpty {
                        emptyState
                    } else {
                        compareSplitView
                            .frame(minHeight: 424, maxHeight: .infinity)
                    }
                    nextAction
                }
                .padding(32)
                .frame(maxWidth: 1240)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(DomtaTheme.canvas(colorScheme))
            }
        }
        .frame(minWidth: 1180, minHeight: 780)
        .tint(accent)
        .navigationTitle("Compare Result")
        .toolbarBackground(DomtaTheme.canvas(colorScheme), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onAppear { syncPreviewSelectionWithResults() }
        .onChange(of: viewModel.results.map(\.id)) { _, _ in syncPreviewSelectionWithResults() }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review what changed.")
                .font(.system(size: 36, weight: .semibold)).tracking(-1.1)
            Text("ตรวจความต่างของข้อมูลก่อนสร้างสคริปต์สำหรับ Target")
                .font(.system(size: 13)).foregroundStyle(muted)
        }
    }

    private var operationStatus: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.activeOperationTitle ?? "Comparing Selected Tables")
                    .font(.system(size: 13, weight: .medium))
                if let progress = viewModel.progressState {
                    Text(progress.message).font(.system(size: 12)).foregroundStyle(muted).lineLimit(2)
                    if let fraction = progress.fractionCompleted, !progress.showsIndeterminateSpinner {
                        ProgressView(value: fraction)
                    }
                }
            }
            Spacer()
            if let elapsed = viewModel.operationElapsedText {
                Text(elapsed).font(.system(size: 11)).monospacedDigit().foregroundStyle(muted)
            }
        }
        .padding(14)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        resultMessage(
            title: viewModel.isBusy ? "กำลังเปรียบเทียบข้อมูล…" : "ยังไม่มีผล compare",
            detail: viewModel.isBusy ? "ผลลัพธ์จะแสดงที่นี่เมื่อเปรียบเทียบตารางที่เลือกครบแล้ว" : "กลับไปเลือกตารางแล้วเริ่ม Compare เพื่อดูความต่าง",
            symbol: "tablecells"
        )
        .frame(maxHeight: .infinity)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28)).foregroundStyle(DomtaTheme.target(colorScheme))
            Text("เปรียบเทียบข้อมูลไม่สำเร็จ").font(.system(size: 15, weight: .semibold))
            ScrollView {
                Text(error).font(.system(size: 12)).foregroundStyle(muted)
                    .textSelection(.enabled).frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 100)
            Button("Try Again") { viewModel.compareSelectedTables() }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy || viewModel.selectedTableKeys.isEmpty)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DomtaTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(DomtaTheme.rule(colorScheme), lineWidth: 1) }
    }

    private func resultMessage(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(accent)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DomtaTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(DomtaTheme.rule(colorScheme), lineWidth: 1) }
    }

    private var nextAction: some View {
        VStack(alignment: .leading, spacing: 18) {
            Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1)
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(resultSummary)
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    Text("สคริปต์จะปรับข้อมูล Target ให้ตรงกับ Source")
                        .font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer(minLength: 0)
                Button(action: onShowScript) {
                    HStack(spacing: 10) {
                        Text("Generate Script")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(DomtaPrimaryButtonStyle())
                .disabled(viewModel.generatedScript.isEmpty || viewModel.isBusy || viewModel.errorMessage != nil)
            }
        }
    }

    private var compareSplitView: some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = 24
            let minTopHeight: CGFloat = 180
            let minBottomHeight: CGFloat = 220
            let totalHeight = max(geometry.size.height, minTopHeight + minBottomHeight + dividerHeight)
            let availableHeight = totalHeight - dividerHeight
            let maxTopHeight = max(minTopHeight, availableHeight - minBottomHeight)
            let proposedTopHeight = availableHeight * compareSplitRatio
            let topHeight = min(max(proposedTopHeight, minTopHeight), maxTopHeight)
            let bottomHeight = max(minBottomHeight, totalHeight - topHeight - dividerHeight)

            VStack(spacing: 0) {
                compareSummarySection
                    .frame(maxWidth: .infinity)
                    .frame(height: topHeight)

                compareSplitDivider(
                    totalHeight: totalHeight,
                    dividerHeight: dividerHeight,
                    minTopHeight: minTopHeight,
                    minBottomHeight: minBottomHeight,
                    currentTopHeight: topHeight
                )

                comparePreviewContainer
                    .frame(maxWidth: .infinity)
                    .frame(height: bottomHeight)
            }
        }
    }

    private var compareSummaryTable: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(viewModel.results) { result in
                        compareSummaryDataRow(result)
                    }
                } header: {
                    compareSummaryHeaderRow
                }
            }
        }
        .background(DomtaTheme.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(DomtaTheme.rule(colorScheme), lineWidth: 1) }
    }

    private var compareSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tables Summary").font(.system(size: 19, weight: .semibold))
                Spacer()
                Text(tableCountLabel)
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(muted)
            }
            Text("คลิกจำนวน Insert, Update หรือ Delete เพื่อดูข้อมูลของตารางนั้น")
                .font(.system(size: 12)).foregroundStyle(muted)
            compareSummaryTable
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var comparePreviewContainer: some View {
        Group {
            if let selection = effectivePreviewSelection,
               let result = viewModel.results.first(where: { $0.id == selection.tableID }) {
                comparePreviewSection(result: result, kind: selection.kind)
            } else {
                resultMessage(
                    title: totalChanges == 0 ? "ข้อมูลตรงกันแล้ว" : "เลือกข้อมูลเพื่อดู Preview",
                    detail: totalChanges == 0 ? "ไม่พบรายการ Insert, Update หรือ Delete ในตารางที่เปรียบเทียบ" : "เลือกจำนวน Insert, Update หรือ Delete ในตารางด้านบน",
                    symbol: totalChanges == 0 ? "checkmark.circle" : "tablecells"
                )
            }
        }
    }

    private func compareSplitDivider(
        totalHeight: CGFloat,
        dividerHeight: CGFloat,
        minTopHeight: CGFloat,
        minBottomHeight: CGFloat,
        currentTopHeight: CGFloat
    ) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: dividerHeight)
            .overlay {
                Capsule()
                    .fill(DomtaTheme.rule(colorScheme))
                    .frame(width: 48, height: 4)
            }
            .contentShape(Rectangle())
            .help("Drag to resize summary and preview")
            .accessibilityLabel("Resize summary and preview")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: compareSplitRatio = min(0.8, compareSplitRatio + 0.05)
                case .decrement: compareSplitRatio = max(0.2, compareSplitRatio - 0.05)
                @unknown default: break
                }
            }
            .onHover { isHovering in
                if isHovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if compareSplitDragStartTopHeight == nil {
                            compareSplitDragStartTopHeight = currentTopHeight
                        }

                        let proposedTopHeight = (compareSplitDragStartTopHeight ?? currentTopHeight) + value.translation.height
                        let availableHeight = totalHeight - dividerHeight
                        let maxTopHeight = max(minTopHeight, availableHeight - minBottomHeight)
                        let clampedTopHeight = min(max(proposedTopHeight, minTopHeight), maxTopHeight)
                        compareSplitRatio = clampedTopHeight / availableHeight
                    }
                    .onEnded { _ in
                        compareSplitDragStartTopHeight = nil
                    }
            )
    }

    private var compareSummaryHeaderRow: some View {
        HStack(spacing: 0) {
            summaryCell("Table", width: nil, alignment: .leading, isHeader: true)
            summaryCell("Source Rows", width: 96, alignment: .trailing, isHeader: true)
            summaryCell("Target Rows", width: 96, alignment: .trailing, isHeader: true)
            summaryCell("Insert", width: 76, alignment: .trailing, isHeader: true)
            summaryCell("Update", width: 76, alignment: .trailing, isHeader: true)
            summaryCell("Delete", width: 76, alignment: .trailing, isHeader: true)
        }
        .background(DomtaTheme.sidebar(colorScheme).opacity(0.45))
        .background(DomtaTheme.surface(colorScheme))
        .overlay(alignment: .bottom) { Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1) }
    }

    private func compareSummaryDataRow(_ result: TableCompareResult) -> some View {
        HStack(spacing: 0) {
            summaryCell(result.tableName, width: nil, alignment: .leading)
            summaryCell("\(result.sourceRowCount)", width: 96, alignment: .trailing)
            summaryCell("\(result.targetRowCount)", width: 96, alignment: .trailing)
            summaryActionCell(count: result.insertCount, kind: .insert, result: result, width: 76)
            summaryActionCell(count: result.updateCount, kind: .update, result: result, width: 76)
            summaryActionCell(count: result.deleteCount, kind: .delete, result: result, width: 76)
        }
        .background(effectivePreviewSelection?.tableID == result.id ? DomtaTheme.selection(colorScheme).opacity(0.4) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(DomtaTheme.rule(colorScheme).opacity(0.5)).frame(height: 0.5) }
    }

    private func summaryCell(_ text: String, width: CGFloat?, alignment: Alignment, isHeader: Bool = false) -> some View {
        Text(text)
            .font(.system(size: isHeader ? 11 : 12, weight: isHeader ? .medium : .regular, design: !isHeader && width == nil ? .monospaced : .default))
            .foregroundStyle(isHeader ? DomtaTheme.sidebarMuted(colorScheme) : (width == nil ? .primary : muted))
            .monospacedDigit().lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 12)
            .frame(width: width, height: 36, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .help(text)
    }

    private func summaryActionCell(count: Int, kind: SampleKind, result: TableCompareResult, width: CGFloat) -> some View {
        let isActive = effectivePreviewSelection == ComparePreviewSelection(tableID: result.id, kind: kind)
        return Button {
            previewSelection = ComparePreviewSelection(tableID: result.id, kind: kind)
        } label: {
            Text("\(count)")
                .font(.system(size: 12, weight: count > 0 ? .semibold : .regular)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .underline(count > 0)
                .foregroundStyle(count > 0 ? accent : muted)
                .padding(.horizontal, 12)
                .frame(width: width, height: 36, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .background(isActive ? DomtaTheme.selection(colorScheme) : .clear)
        .overlay(alignment: .bottom) {
            if isActive { Rectangle().fill(accent).frame(height: 2) }
        }
        .accessibilityLabel("\(result.tableName), \(kind.label), \(count) rows")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .help("Preview \(kind.label.lowercased()) rows in \(result.tableName)")
    }

    private var effectivePreviewSelection: ComparePreviewSelection? {
        guard let previewSelection,
              let result = viewModel.results.first(where: { $0.id == previewSelection.tableID }),
              !result.rowPairs(for: previewSelection.kind).isEmpty else {
            return defaultPreviewSelection()
        }

        return previewSelection
    }

    private func defaultPreviewSelection() -> ComparePreviewSelection? {
        for result in viewModel.results {
            for kind in [SampleKind.insert, .update, .delete] {
                if !result.rowPairs(for: kind).isEmpty {
                    return ComparePreviewSelection(tableID: result.id, kind: kind)
                }
            }
        }

        return nil
    }

    private func syncPreviewSelectionWithResults() {
        previewSelection = effectivePreviewSelection
    }

    private func comparePreviewSection(result: TableCompareResult, kind: SampleKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(result.tableName)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).help(result.tableName)
                Text("\(kind.label) Preview")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(DomtaTheme.selection(colorScheme), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                Spacer(minLength: 0)
                Text("\(result.rowPairs(for: kind).count) \(result.rowPairs(for: kind).count == 1 ? "row" : "rows")")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(muted).fixedSize()
            }
            Text(kind == .update ? "Source คือค่าอ้างอิง · Target คือค่าปัจจุบัน · ช่องสีคือค่าที่ต่างกัน" : (kind == .insert ? "ข้อมูลจาก Source ที่จะเพิ่มใน Target" : "ข้อมูลที่มีเฉพาะใน Target และจะถูกลบ"))
                .font(.system(size: 12)).foregroundStyle(muted)
            comparePreviewTable(result: result, kind: kind)
        }
    }

    private func comparePreviewTable(result: TableCompareResult, kind: SampleKind) -> some View {
        let previewData = makePreviewTableData(result: result, kind: kind)

        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(previewData.rows) { row in
                        ComparePreviewRowView(row: row)
                            .equatable()
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(Array(previewData.headers.enumerated()), id: \.offset) { _, header in
                            previewHeaderCell(header, width: 170)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DomtaTheme.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(DomtaTheme.rule(colorScheme), lineWidth: 1) }
    }

    private func previewHeaderCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DomtaTheme.sidebarInk(colorScheme))
            .lineLimit(2).truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 40, alignment: .leading)
            .background(DomtaTheme.sidebar(colorScheme))
            .overlay { Rectangle().stroke(DomtaTheme.rule(colorScheme).opacity(0.5), lineWidth: 0.5) }
            .help(text)
    }

    private func compareDisplayValue(for row: [String: JSONValue]?, column: TableColumn) -> String {
        guard let row else { return "NULL" }
        return (row[column.name] ?? .null).displayString
    }

    private func compareValuesDiffer(source: [String: JSONValue]?, target: [String: JSONValue]?, column: TableColumn) -> Bool {
        (source?[column.name] ?? .null) != (target?[column.name] ?? .null)
    }

    private func makePreviewTableData(result: TableCompareResult, kind: SampleKind) -> ComparePreviewTableData {
        let usesCrossColumns = kind == .update
        let headers: [String] = usesCrossColumns
            ? result.comparableColumns.flatMap { ["\($0.name) · Source", "\($0.name) · Target"] }
            : result.comparableColumns.map(\.name)

        let rows = result.rowPairs(for: kind).map { pair in
            ComparePreviewRowData(
                id: pair.id,
                cells: makePreviewCells(pair: pair, columns: result.comparableColumns, kind: kind)
            )
        }

        return ComparePreviewTableData(headers: headers, rows: rows)
    }

    private func makePreviewCells(pair: RowPair, columns: [TableColumn], kind: SampleKind) -> [ComparePreviewCellData] {
        switch kind {
        case .update:
            return columns.flatMap { column in
                let sourceValue = compareDisplayValue(for: pair.source, column: column)
                let targetValue = compareDisplayValue(for: pair.target, column: column)
                let changed = compareValuesDiffer(source: pair.source, target: pair.target, column: column)

                return [
                    ComparePreviewCellData(
                        id: "\(column.name)-source",
                        text: sourceValue,
                        style: changed ? .sourceChanged : .plain
                    ),
                    ComparePreviewCellData(
                        id: "\(column.name)-target",
                        text: targetValue,
                        style: changed ? .targetChanged : .plain
                    )
                ]
            }
        case .insert:
            return columns.map { column in
                ComparePreviewCellData(
                    id: column.name,
                    text: compareDisplayValue(for: pair.source, column: column),
                    style: .inserted
                )
            }
        case .delete:
            return columns.map { column in
                ComparePreviewCellData(
                    id: column.name,
                    text: compareDisplayValue(for: pair.target, column: column),
                    style: .deleted
                )
            }
        }
    }

}
