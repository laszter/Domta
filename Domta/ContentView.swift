//
//  ContentView.swift
//  Domta
//
//  Created by Ratchapol Vanavichit on 25/3/26.
//

import AppKit
import SwiftUI

private enum AppRoute: Hashable {
    case tables
    case results
    case script
}

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

    var backgroundColor: Color {
        switch self {
        case .plain:
            return .clear
        case .sourceChanged, .deleted:
            return Color.red.opacity(0.16)
        case .targetChanged, .inserted:
            return Color.green.opacity(0.18)
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

    static func == (lhs: ComparePreviewRowView, rhs: ComparePreviewRowView) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(row.cells) { cell in
                Text(cell.text)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(width: 170, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        cell.style.backgroundColor.overlay(
                            Rectangle()
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    )
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = CompareViewModel()
    @State private var path: [AppRoute] = []
    @State private var previewSelection: ComparePreviewSelection?
    @State private var compareSplitRatio: CGFloat = 0.42
    @State private var compareSplitDragStartTopHeight: CGFloat?

    var body: some View {
        NavigationStack(path: $path) {
            connectionPage
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .tables:
                        tablesPage
                    case .results:
                        resultsPage
                    case .script:
                        scriptPage
                    }
                }
        }
    }

    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let operationTitle = viewModel.activeOperationTitle {
                    busyBanner(title: operationTitle)
                }

                recentConnectionsSection
                connectionEditorsSection
            }
            .padding(28)
        }
        .frame(minWidth: 1180, minHeight: 860)
        .background(connectionPageBackground)
        .navigationTitle("Connections")
    }

    private func busyBanner(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.headline)
                Spacer()
                if let elapsed = viewModel.operationElapsedText {
                    Text(elapsed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = viewModel.progressState {
                if let fraction = progress.fractionCompleted, !progress.showsIndeterminateSpinner {
                    ProgressView(value: fraction)
                }

                Text(progress.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.14), lineWidth: 1)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Domta")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)

                    Text("Compare SQL Server\nwith confidence")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("ใส่ connection string 2 ฝั่ง, ตรวจตารางที่เทียบกันได้, compare ข้อมูล และ generate sync script สำหรับ target ใน flow เดียว")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 680, alignment: .leading)
                }

                Spacer(minLength: 20)

                VStack(alignment: .leading, spacing: 10) {
                    headerStat(title: "Workflow", value: "Load > Compare > Sync")
                    headerStat(title: "Supported", value: "SQL Server / Azure SQL")
                    headerStat(title: "Auth", value: "SQL Authentication")
                }
                .frame(width: 260, alignment: .leading)
            }

            HStack(spacing: 12) {
                headerBadge("ต้องมี `sqlcmd` อยู่ในเครื่อง", systemImage: "terminal")
                headerBadge("รองรับ SQL authentication จาก connection string", systemImage: "key.horizontal")
                headerBadge("เหมาะกับการตรวจ diff ก่อน sync", systemImage: "arrow.trianglehead.branch")
            }
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.14),
                            Color(nsColor: .windowBackgroundColor),
                            Color.orange.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var recentConnectionsSection: some View {
        sectionCard(title: "Recent Connections", subtitle: "หยิบชุด connection ล่าสุดกลับมาใช้ได้ทันที") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Open Preferences File") {
                        viewModel.revealPreferencesFile()
                    }
                    .buttonStyle(.bordered)

                    Button("Clear Recent Connections") {
                        viewModel.clearRecentConnections()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.recentConnectionPairs.isEmpty)

                    Spacer()
                }

                if viewModel.recentConnectionPairs.isEmpty {
                    Text("ยังไม่มี recent connection")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.recentConnectionPairs) { pair in
                                Button {
                                    viewModel.applyRecentConnectionPair(pair)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(pair.displayName)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            Text(pair.detailText)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Label("Use", systemImage: "arrow.up.forward.square")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background {
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                }
            }
        }
    }

    private var connectionEditorsSection: some View {
        sectionCard(title: "Connections", subtitle: "วาง source และ target connection string แล้วเริ่มโหลดตารางที่เทียบกันได้") {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    connectionEditor(
                        title: "Source",
                        text: $viewModel.sourceConnectionString,
                        prompt: "Data Source=your-server-name.database.windows.net,1433;Database=your-database-name;User ID=your-username;Password=your-password;Encrypt=True;Trust Server Certificate=True;",
                        isTesting: viewModel.isTestingSourceConnection,
                        testAction: viewModel.testSourceConnection,
                        testMessage: viewModel.sourceTestMessage
                    )

                    connectionEditor(
                        title: "Target",
                        text: $viewModel.targetConnectionString,
                        prompt: "Data Source=your-server-name.database.windows.net,1433;Database=your-database-name;User ID=your-username;Password=your-password;Encrypt=True;Trust Server Certificate=True;",
                        isTesting: viewModel.isTestingTargetConnection,
                        testAction: viewModel.testTargetConnection,
                        testMessage: viewModel.targetTestMessage
                    )
                }

                HStack {
                    Button(viewModel.isBusy && viewModel.activeOperationTitle == "Loading Comparable Tables" ? "Loading..." : "Load Comparable Tables") {
                        viewModel.resetTableSelectionState()
                        path.append(.tables)
                        viewModel.loadComparableTables()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBusy)

                    Text("เริ่มจากตรวจ connection แล้วค่อยโหลด comparable tables")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
            }
        }
    }

    private func connectionEditor(
        title: String,
        text: Binding<String>,
        prompt: String,
        isTesting: Bool,
        testAction: @escaping () -> Void,
        testMessage: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(title == "Source" ? "ฝั่งต้นทางที่ถือข้อมูลอ้างอิง" : "ฝั่งปลายทางที่จะ sync ตาม")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Test Connection") {
                    testAction()
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || viewModel.isBusy)
            }

            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .textBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .padding(14)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(prompt)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }

            if let testMessage, !testMessage.isEmpty {
                Text(testMessage)
                    .font(.caption)
                    .foregroundStyle(testMessage.lowercased().contains("connected to") ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var connectionPageBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.05),
                    Color.orange.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 340, height: 340)
                .blur(radius: 70)
                .offset(x: -360, y: -250)

            Circle()
                .fill(Color.orange.opacity(0.08))
                .frame(width: 280, height: 280)
                .blur(radius: 70)
                .offset(x: 420, y: -180)
        }
        .ignoresSafeArea()
    }

    private func headerBadge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
            )
    }

    private func headerStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.78))
        )
    }

    private func sectionCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.04), radius: 16, x: 0, y: 8)
    }

    private var tablesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                tablesHero

                if let operationTitle = viewModel.activeOperationTitle {
                    busyBanner(title: operationTitle)
                }

                sectionCard(
                    title: "Comparable Tables",
                    subtitle: "เลือกตารางที่ schema และ primary key ตรงกันเพื่อส่งต่อไปยังขั้นตอน compare"
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center, spacing: 14) {
                            tablesSummaryChip(
                                title: "Ready",
                                value: "\(viewModel.comparableTables.count)"
                            )
                            tablesSummaryChip(
                                title: "Selected",
                                value: "\(viewModel.selectedTableKeys.count)"
                            )

                            Spacer()

                            Button(viewModel.isBusy && viewModel.activeOperationTitle == "Comparing Selected Tables" ? "Comparing..." : "Compare Selected") {
                                viewModel.clearCompareResultState()
                                path.append(.results)
                                viewModel.compareSelectedTables()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.selectedTableKeys.isEmpty || viewModel.isBusy)
                        }

                        HStack(spacing: 10) {
                            Button("Select All") {
                                viewModel.selectAllTables()
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.comparableTables.isEmpty || viewModel.isBusy)

                            Button("Clear Selection") {
                                viewModel.clearSelection()
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.selectedTableKeys.isEmpty || viewModel.isBusy)

                            Text("คลิกที่ card ของแต่ละตารางเพื่อเลือกหรือยกเลิกการเลือก")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()
                        }

                        if viewModel.comparableTables.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(viewModel.isBusy ? "กำลังโหลด comparable tables..." : "ยังไม่มีตารางที่พร้อม compare")
                                    .font(.headline)
                                Text("เมื่อระบบเจอตารางที่ schema และ primary key ตรงกัน รายการจะแสดงที่นี่")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
                            }
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(viewModel.comparableTables) { table in
                                        tableRow(table)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(minHeight: 220)
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(minWidth: 1180, minHeight: 860)
        .background(connectionPageBackground)
        .navigationTitle("Comparable Tables")
    }

    private func tableRow(_ table: ComparableTable) -> some View {
        let isSelected = viewModel.selectedTableKeys.contains(table.id)

        return Button {
            viewModel.toggleSelection(for: table.id)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10))
                        .frame(width: 28, height: 28)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }

                Text(table.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Text(isSelected ? "Selected" : "Select")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .windowBackgroundColor).opacity(0.75))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var tablesHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comparable Tables")
                .font(.system(size: 22, weight: .semibold, design: .rounded))

            Text("รายการนี้แสดงเฉพาะตารางที่ schema และ primary key match กันแล้ว คุณสามารถเลือกบางตารางหรือทั้งหมดก่อนเริ่ม compare ได้ทันที")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.green.opacity(0.12),
                            Color(nsColor: .windowBackgroundColor),
                            Color.accentColor.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func tablesSummaryChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.78))
        )
    }

    private var resultsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let operationTitle = viewModel.activeOperationTitle {
                busyBanner(title: operationTitle)
            }

            GroupBox("Compare Result") {
            VStack(alignment: .leading, spacing: 14) {
                if let message = viewModel.statusMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if viewModel.results.isEmpty {
                    Text(viewModel.isBusy ? "กำลัง compare..." : "ยังไม่มีผล compare")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    compareSplitView
                        .frame(minHeight: 520, maxHeight: .infinity)

                    HStack {
                        Button("Generate Script") {
                            path.append(.script)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.generatedScript.isEmpty)
                    }
                }
            }
        }
        }
        .padding(24)
        .frame(minWidth: 1180, minHeight: 860)
        .navigationTitle("Compare Result")
        .onAppear {
            syncPreviewSelectionWithResults()
        }
        .onChange(of: viewModel.results.map(\.id)) { _, _ in
            syncPreviewSelectionWithResults()
        }
    }

    private var compareSplitView: some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = 12
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

    private var scriptPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Generated Script")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Copy Script") {
                    viewModel.copyScriptToPasteboard()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.generatedScript.isEmpty)
            }

            TextEditor(text: .constant(viewModel.generatedScript))
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
        .navigationTitle("Generated Script")
    }

    private var compareSummaryTable: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                compareSummaryHeaderRow

                ForEach(viewModel.results) { result in
                    compareSummaryDataRow(result)
                }
            }
            .padding(.vertical, 4)
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var compareSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tables Summary")
                    .font(.headline)

                Spacer()

                Text("\(viewModel.results.count) tables")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("คลิกที่จำนวน Insert, Update หรือ Delete เพื่อเปิด preview ของตารางนั้น")
                .font(.caption)
                .foregroundStyle(.secondary)

            compareSummaryTable
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var comparePreviewContainer: some View {
        Group {
            if let selection = effectivePreviewSelection,
               let result = viewModel.results.first(where: { $0.id == selection.tableID }) {
                comparePreviewSection(result: result, kind: selection.kind)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.headline)
                    Text("เลือกจำนวน Insert, Update หรือ Delete เพื่อดู preview")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .windowBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
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
                VStack(spacing: 3) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.32))
                        .frame(width: 68, height: 4)
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 42, height: 3)
                }
            }
            .contentShape(Rectangle())
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
            summaryCell("Table", width: 260, alignment: .leading, isHeader: true)
            summaryCell("Source Rows", width: 110, alignment: .trailing, isHeader: true)
            summaryCell("Target Rows", width: 110, alignment: .trailing, isHeader: true)
            summaryCell("Insert", width: 90, alignment: .trailing, isHeader: true)
            summaryCell("Update", width: 90, alignment: .trailing, isHeader: true)
            summaryCell("Delete", width: 90, alignment: .trailing, isHeader: true)
        }
    }

    private func compareSummaryDataRow(_ result: TableCompareResult) -> some View {
        HStack(spacing: 0) {
            summaryCell(result.tableName, width: 260, alignment: .leading)
            summaryCell("\(result.sourceRowCount)", width: 110, alignment: .trailing)
            summaryCell("\(result.targetRowCount)", width: 110, alignment: .trailing)
            summaryActionCell(count: result.insertCount, kind: .insert, result: result, width: 90)
            summaryActionCell(count: result.updateCount, kind: .update, result: result, width: 90)
            summaryActionCell(count: result.deleteCount, kind: .delete, result: result, width: 90)
        }
        .background(rowHighlight(for: result))
    }

    private func summaryCell(_ text: String, width: CGFloat, alignment: Alignment, isHeader: Bool = false) -> some View {
        Text(text)
            .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
            .foregroundStyle(isHeader ? .primary : .secondary)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Rectangle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    private func summaryActionCell(count: Int, kind: SampleKind, result: TableCompareResult, width: CGFloat) -> some View {
        let isActive = previewSelection == ComparePreviewSelection(tableID: result.id, kind: kind)
        let isEnabled = count > 0

        return Button {
            previewSelection = ComparePreviewSelection(tableID: result.id, kind: kind)
        } label: {
            Text("\(count)")
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: width, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            Rectangle()
                .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func rowHighlight(for result: TableCompareResult) -> some View {
        let isSelectedRow = previewSelection?.tableID == result.id
        return (isSelectedRow ? Color.accentColor.opacity(0.06) : Color.clear)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(result.tableName) \(kind.label) Preview")
                    .font(.headline)

                Spacer()

                Text("\(result.rowPairs(for: kind).count) rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("คลิกที่จำนวนของแต่ละประเภทเพื่อสลับ preview ตาราง")
                .font(.caption)
                .foregroundStyle(.secondary)

            comparePreviewTable(result: result, kind: kind)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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
            .padding(.vertical, 4)
        }
        .frame(minHeight: 260)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func previewHeaderCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        Rectangle()
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            )
    }

    private func previewValueCell(_ text: String, width: CGFloat, background: Color, font: Font = .system(.caption, design: .monospaced)) -> some View {
        Text(text)
            .font(font)
            .lineLimit(3)
            .truncationMode(.tail)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                background.overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            )
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
            ? result.comparableColumns.flatMap { [$0.name, $0.name] }
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
