//
//  SchemaCompareView.swift
//  Domta
//

import SwiftUI

/// หน้า schema compare ที่จัดวางตาม Schema Compare ของ mssql extension
///
/// แถบบนคือ source / target และปุ่ม Compare, กลางคือตารางความต่างที่ติ๊กเลือกได้
/// และล่างคือ Comparison Details ที่แสดง definition ของทั้งสองฝั่งเทียบกัน
struct SchemaCompareView: View {
    @ObservedObject var viewModel: SchemaCompareViewModel
    let source: ConnectionInput
    let target: ConnectionInput
    let onEditConnections: () -> Void
    let onShowScript: () -> Void

    @State private var isShowingOptions = false
    @State private var splitRatio: CGFloat = 0.42
    @State private var dragStartTopHeight: CGFloat?

    private enum Layout {
        static let typeWidth: CGFloat = 130
        static let nameWidth: CGFloat = 360
        static let checkWidth: CGFloat = 44
        static let actionWidth: CGFloat = 110
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar

            if viewModel.isBusy {
                busyBanner
            }

            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }

            if viewModel.report == nil {
                emptyState
                Spacer(minLength: 0)
            } else {
                splitContent
            }
        }
        .padding(20)
        .frame(minWidth: 1180, minHeight: 860)
        .background(DomtaPageBackground())
        .navigationTitle("Schema Compare")
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                connectionField(title: "Source", value: sourceLabel, tint: .green)

                Button("...") {
                    onEditConnections()
                }
                .buttonStyle(.bordered)
                .help("กลับไปแก้ connection string")

                connectionField(title: "Target", value: targetLabel, tint: .red)

                Button("...") {
                    onEditConnections()
                }
                .buttonStyle(.bordered)
                .help("กลับไปแก้ connection string")

                Button("Options") {
                    isShowingOptions.toggle()
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $isShowingOptions, arrowEdge: .bottom) {
                    optionsPopover
                }

                Button(viewModel.isBusy ? "Comparing..." : "Compare") {
                    viewModel.compareSchema(source: source, target: target)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || !viewModel.isSqlPackageAvailable)

                Button("Generate Script") {
                    onShowScript()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasScript)
            }

            HStack(spacing: 10) {
                if !viewModel.isSqlPackageAvailable {
                    Label("ไม่พบ sqlpackage — `dotnet tool install --global microsoft.sqlpackage`", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.report != nil {
                    Text("\(viewModel.includedRowIDs.count) / \(viewModel.rows.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DomtaSearchField(prompt: "ค้นหา object", text: $viewModel.searchText)
                        .frame(width: 240)
                }
            }
        }
    }

    private func connectionField(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity)
    }

    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Object Types")
                .font(.subheadline.weight(.semibold))

            ForEach(SchemaObjectCategory.allCases.filter { $0 != .other }) { category in
                Toggle(category.title, isOn: Binding(
                    get: { viewModel.options.selectedCategories.contains(category) },
                    set: { _ in viewModel.toggleCategory(category) }
                ))
            }

            Text("กลุ่มที่ไม่ติ๊กจะถูกส่งเป็น `/p:ExcludeObjectTypes` ให้ sqlpackage — ไม่โผล่ทั้งในตารางและใน script")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Compare Behavior")
                .font(.subheadline.weight(.semibold))

            Toggle("แสดง object ที่มีเฉพาะฝั่ง target (DropObjectsNotInSource)", isOn: $viewModel.options.reportObjectsOnlyInTarget)
            Toggle("ข้าม whitespace และ comment", isOn: $viewModel.options.ignoreWhitespaceInModules)
            Toggle("ข้าม permission", isOn: $viewModel.options.ignorePermissions)
            Toggle("ข้าม user / role setting", isOn: $viewModel.options.ignoreUserSettingsObjects)
            Toggle("ข้าม extended property", isOn: $viewModel.options.ignoreExtendedProperties)
            Toggle("หยุด script เมื่ออาจเกิด data loss", isOn: $viewModel.options.blockOnPossibleDataLoss)
        }
        .toggleStyle(.checkbox)
        .font(.subheadline)
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    private var sourceLabel: String { Self.databaseLabel(for: source, fallback: "Source") }
    private var targetLabel: String { Self.databaseLabel(for: target, fallback: "Target") }

    private static func databaseLabel(for input: ConnectionInput, fallback: String) -> String {
        guard let configuration = try? ConnectionStringParser.parse(input.connectionString) else { return fallback }
        guard let database = configuration.database, !database.isEmpty else {
            return configuration.server.isEmpty ? fallback : configuration.server
        }
        return "\(configuration.server).\(database)"
    }

    // MARK: - Banners

    private var busyBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                Text("Comparing Schema")
                    .font(.subheadline.weight(.semibold))

                if let progress = viewModel.progressState {
                    Text(progress.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let elapsed = viewModel.operationElapsedText {
                Text(elapsed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel") {
                viewModel.cancelCompare()
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.10))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        ScrollView {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.08))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ยังไม่มีผล schema compare")
                .font(.headline)
            Text("กด Compare เพื่อให้ sqlpackage extract schema ของ source ออกมาเป็น dacpac แล้วเทียบกับ target")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
        }
    }

    // MARK: - Split layout

    private var splitContent: some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = 12
            let minTopHeight: CGFloat = 150
            let minBottomHeight: CGFloat = 220
            let totalHeight = max(geometry.size.height, minTopHeight + minBottomHeight + dividerHeight)
            let availableHeight = totalHeight - dividerHeight
            let maxTopHeight = max(minTopHeight, availableHeight - minBottomHeight)
            let topHeight = min(max(availableHeight * splitRatio, minTopHeight), maxTopHeight)

            VStack(spacing: 0) {
                differenceGrid
                    .frame(height: topHeight)

                splitDivider(
                    totalHeight: totalHeight,
                    dividerHeight: dividerHeight,
                    minTopHeight: minTopHeight,
                    minBottomHeight: minBottomHeight,
                    currentTopHeight: topHeight
                )

                detailsPane
                    .frame(height: max(minBottomHeight, totalHeight - topHeight - dividerHeight))
            }
        }
    }

    private func splitDivider(
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
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 68, height: 4)
            }
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartTopHeight == nil { dragStartTopHeight = currentTopHeight }

                        let availableHeight = totalHeight - dividerHeight
                        let maxTopHeight = max(minTopHeight, availableHeight - minBottomHeight)
                        let proposed = (dragStartTopHeight ?? currentTopHeight) + value.translation.height
                        splitRatio = min(max(proposed, minTopHeight), maxTopHeight) / availableHeight
                    }
                    .onEnded { _ in dragStartTopHeight = nil }
            )
    }

    // MARK: - Difference grid

    private var differenceGrid: some View {
        VStack(spacing: 0) {
            gridHeader

            if viewModel.filteredRows.isEmpty {
                Text(viewModel.rows.isEmpty
                     ? "schema ทั้งสองฝั่งตรงกันแล้ว ไม่พบความต่าง"
                     : "ไม่พบ object ที่ตรงกับคำค้นหา")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredRows) { row in
                            gridRow(row)
                        }
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var gridHeader: some View {
        HStack(spacing: 0) {
            headerCell("Type", width: Layout.typeWidth)
            headerCell("Source Name", width: Layout.nameWidth)

            Button {
                viewModel.setInclusionForVisibleRows(!viewModel.areAllVisibleRowsIncluded)
            } label: {
                Image(systemName: viewModel.areAllVisibleRowsIncluded ? "checkmark.square.fill" : "square")
                    .foregroundStyle(viewModel.areAllVisibleRowsIncluded ? Color.accentColor : Color.secondary)
                    .frame(width: Layout.checkWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("ติ๊ก/เอาออกทุกแถวที่แสดงอยู่")

            headerCell("Action", width: Layout.actionWidth)
            headerCell("Target Name", width: Layout.nameWidth)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
        }
    }

    private func headerCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func gridRow(_ row: SchemaCompareRow) -> some View {
        let isSelected = viewModel.selectedRowID == row.id
        let isIncluded = viewModel.includedRowIDs.contains(row.id)

        return HStack(spacing: 0) {
            Text(row.typeDisplay)
                .frame(width: Layout.typeWidth, alignment: .leading)

            Text(row.sourceName ?? "")
                .frame(width: Layout.nameWidth, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                viewModel.toggleInclusion(row)
            } label: {
                Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary)
                    .frame(width: Layout.checkWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(row.kind.actionTitle)
                .foregroundStyle(row.kind.tint)
                .frame(width: Layout.actionWidth, alignment: .leading)

            Text(row.targetName ?? "")
                .frame(width: Layout.nameWidth, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.select(row: row, source: source, target: target)
        }
    }

    // MARK: - Comparison details

    private var detailsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Comparison Details")
                    .font(.headline)

                if let row = viewModel.selectedRow {
                    Text(row.plainName)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Picker("View", selection: $viewModel.diffViewMode) {
                    ForEach(SchemaDiffViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }

            if let row = viewModel.selectedRow, !row.memberSummaryLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(row.memberSummaryLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                }
            }

            definitionContent
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var definitionContent: some View {
        switch viewModel.definitionState {
        case .idle:
            centeredHint("เลือกแถวด้านบนเพื่อดู definition ของทั้งสองฝั่ง")

        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("กำลังอ่าน definition จากทั้งสองฝั่ง...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .unsupported(let message):
            centeredHint(message)

        case .failed(let message):
            ScrollView {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .loaded(let definition):
            definitionDiff(definition)
        }
    }

    private func centeredHint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func definitionDiff(_ definition: SchemaObjectDefinition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if definition.isTruncated {
                Text("definition ยาวเกินกว่าที่จะจับคู่บรรทัดได้ — แสดงเป็นสองฝั่งเต็ม ๆ แทน")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 6)
            }

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    switch viewModel.diffViewMode {
                    case .sideBySide:
                        Section {
                            ForEach(definition.sideBySideRows) { row in
                                SchemaSideBySideRowView(row: row)
                                    .equatable()
                            }
                        } header: {
                            sideBySideHeader
                        }

                    case .unified:
                        ForEach(definition.lines) { line in
                            SchemaDiffLineView(line: line)
                                .equatable()
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private var sideBySideHeader: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: SchemaSideBySideRowView.gutterWidth)
            Text(sourceLabel)
                .foregroundStyle(.green)
                .frame(width: SchemaSideBySideRowView.columnWidth, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("")
                .frame(width: SchemaSideBySideRowView.gutterWidth)
            Text(targetLabel)
                .foregroundStyle(.red)
                .frame(width: SchemaSideBySideRowView.columnWidth, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.weight(.semibold))
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
        }
    }
}

/// หนึ่งบรรทัดของมุมมองเทียบสองฝั่ง — เลขบรรทัดกับเครื่องหมาย +/- อยู่ติดกันแบบ mssql extension
private struct SchemaSideBySideRowView: View, Equatable {
    static let columnWidth: CGFloat = 460
    static let gutterWidth: CGFloat = 52

    let row: SchemaSideBySideRow

    static func == (lhs: SchemaSideBySideRowView, rhs: SchemaSideBySideRowView) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 0) {
            gutter(number: row.sourceNumber, marker: sourceMarker)
            textCell(row.sourceText, background: row.kind.sourceBackground, isMissing: row.sourceText == nil)
            gutter(number: row.targetNumber, marker: targetMarker)
            textCell(row.targetText, background: row.kind.targetBackground, isMissing: row.targetText == nil)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceMarker: String {
        switch row.kind {
        case .changed, .sourceOnly: return "+"
        case .unchanged, .targetOnly: return " "
        }
    }

    private var targetMarker: String {
        switch row.kind {
        case .changed, .targetOnly: return "-"
        case .unchanged, .sourceOnly: return " "
        }
    }

    private func gutter(number: Int?, marker: String) -> some View {
        HStack(spacing: 2) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(width: 8, alignment: .leading)
        }
        .frame(width: SchemaSideBySideRowView.gutterWidth)
        .padding(.vertical, 1)
    }

    private func textCell(_ text: String?, background: Color, isMissing: Bool) -> some View {
        Group {
            if let text {
                Text(SQLSyntaxHighlighter.highlight(text))
            } else {
                Text("")
            }
        }
        .frame(width: SchemaSideBySideRowView.columnWidth, alignment: .leading)
        .padding(.leading, 6)
        .padding(.vertical, 1)
        .background(isMissing ? Color.primary.opacity(0.05) : background)
    }
}

/// หนึ่งบรรทัดของ unified diff
private struct SchemaDiffLineView: View, Equatable {
    let line: SchemaDiffLine

    static func == (lhs: SchemaDiffLineView, rhs: SchemaDiffLineView) -> Bool {
        lhs.line == rhs.line
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(line.sourceNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.targetNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.kind.gutterSymbol)
                .frame(width: 20, alignment: .center)
                .foregroundStyle(.secondary)
            Text(SQLSyntaxHighlighter.highlight(line.text))
                .frame(minWidth: 480, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind.backgroundColor)
    }
}

// MARK: - Script page

struct SchemaScriptView: View {
    @ObservedObject var viewModel: SchemaCompareViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deployment Script")
                        .font(.title2.weight(.semibold))
                    Text("script นี้มาจาก `sqlpackage /Action:Script` — รันบน target เพื่อทำให้ schema เท่ากับ source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Copy Script") {
                    viewModel.copyScriptToPasteboard()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasScript)

                Button("Save as .sql") {
                    viewModel.saveScriptToFile()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.hasScript)
            }

            scopePicker

            if let filter = viewModel.scriptFilter {
                filterSummary(filter)
            }

            Label("ตรวจ script ให้ครบก่อนรันจริง โดยเฉพาะส่วน DROP และ ALTER TABLE ที่อาจทำให้ข้อมูลหาย", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)

            TextEditor(text: .constant(viewModel.displayedScript))
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .textBackgroundColor))
                }
        }
        .padding(24)
        .frame(minWidth: 1180, minHeight: 860)
        .navigationTitle("Deployment Script")
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $viewModel.showsFullScript) {
            Text("Selected objects (\(viewModel.includedRowIDs.count))").tag(false)
            Text("Full script (\(viewModel.rows.count))").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 420)
    }

    @ViewBuilder
    private func filterSummary(_ filter: DeploymentScriptFilterResult) -> some View {
        if viewModel.showsFullScript {
            Label(
                "script เต็มจาก sqlpackage — ครอบคลุมทุก object ในกลุ่มที่เปิดไว้ใน Options",
                systemImage: "doc.text"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    filter.didFilterAnything
                        ? "ตัด \(filter.removedSectionCount) ส่วนที่เป็นของ object ที่ไม่ได้ติ๊กออกแล้ว เหลือ \(filter.keptSectionCount) ส่วน"
                        : "ทุก object ในตารางถูกติ๊กไว้ script จึงเท่ากับ script เต็ม",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .foregroundStyle(.secondary)

                if filter.unattributedSectionCount > 0 {
                    Label(
                        "เก็บอีก \(filter.unattributedSectionCount) ส่วนที่ระบุไม่ได้ว่าเป็นของ object ไหนไว้ทั้งหมด (preamble, SET options และท้าย script)",
                        systemImage: "shield.lefthalf.filled"
                    )
                    .foregroundStyle(.secondary)
                }

                if filter.didFilterAnything {
                    Label(
                        "ถ้า object ที่เก็บไว้อ้างถึง object ที่ตัดออก script จะรันไม่ผ่าน — ตรวจ dependency ก่อนรัน",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }
}
