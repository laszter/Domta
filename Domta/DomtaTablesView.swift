import SwiftUI

/// Table selection uses the same workspace and palette as Connections.
struct DomtaTablesView: View {
    @ObservedObject var viewModel: CompareViewModel
    let onEditConnections: () -> Void
    let onCompare: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""

    private var accent: Color { DomtaTheme.accent(colorScheme) }
    private var filteredTables: [ComparableTable] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.comparableTables }
        return viewModel.comparableTables.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                DomtaDataSidebar(viewModel: viewModel, step: .tables, onEditConnections: onEditConnections)
                    .frame(width: geometry.size.width < 1200 ? 238 : 268)
                VStack(alignment: .leading, spacing: 24) {
                    workspaceHeader
                    if let title = viewModel.activeOperationTitle {
                        operationStatus(title)
                    }
                    tableWorkspace
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
        .navigationTitle("Comparable Tables")
        .toolbarBackground(DomtaTheme.canvas(colorScheme), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose what to compare.")
                .font(.system(size: 36, weight: .semibold)).tracking(-1.1)
                .fixedSize(horizontal: false, vertical: true)
            Text("เลือกตารางที่ต้องการตรวจความต่างระหว่าง Source และ Target")
                .font(.system(size: 13)).foregroundStyle(DomtaTheme.placeholder(colorScheme))
        }
    }

    private var tableWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Comparable Tables").font(.system(size: 19, weight: .semibold))
                Spacer()
                Text("\(viewModel.comparableTables.count) ready · \(viewModel.selectedTableKeys.count) selected")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(DomtaTheme.placeholder(colorScheme))
            }
            Text("แสดงเฉพาะตารางที่ schema และ primary key ตรงกันทั้งสองฝั่ง")
                .font(.system(size: 12)).foregroundStyle(DomtaTheme.placeholder(colorScheme))

            HStack(spacing: 12) {
                searchField
                Button("Select All") { viewModel.selectAllTables() }
                    .disabled(viewModel.comparableTables.isEmpty || viewModel.isBusy)
                Button("Clear Selection") { viewModel.clearSelection() }
                    .disabled(viewModel.selectedTableKeys.isEmpty || viewModel.isBusy)
            }
            .buttonStyle(.bordered)

            tableList
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(DomtaTheme.placeholder(colorScheme))
            TextField("", text: $searchText, prompt: Text("ค้นหาชื่อ table หรือ schema").foregroundStyle(DomtaTheme.placeholder(colorScheme)))
                .textFieldStyle(.plain)
                .accessibilityLabel("Search tables or schemas")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DomtaTheme.placeholder(colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(DomtaTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(DomtaTheme.rule(colorScheme), lineWidth: 1) }
    }

    private var tableColumnHeaders: some View {
        HStack(spacing: 16) {
            Text("Table").frame(maxWidth: .infinity, alignment: .leading)
            Text("Primary key").frame(width: 180, alignment: .leading)
            Text("Columns").frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
        .padding(.leading, 36).padding(.trailing, 16).padding(.vertical, 11)
        .background(DomtaTheme.sidebar(colorScheme).opacity(0.45))
        .background(DomtaTheme.surface(colorScheme))
        .overlay(alignment: .bottom) { Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1) }
    }

    private var tableList: some View {
        VStack(spacing: 0) {
            if viewModel.comparableTables.isEmpty {
                tableColumnHeaders
                emptyState
            } else if filteredTables.isEmpty {
                tableColumnHeaders
                tableMessage("ไม่พบตารางที่ตรงกับคำค้นหา", detail: "ลองค้นหาด้วยชื่อ table หรือ schema อื่น", symbol: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(filteredTables) { table in
                                DomtaComparableTableRow(
                                    table: table,
                                    isSelected: Binding(
                                        get: { viewModel.selectedTableKeys.contains(table.id) },
                                        set: { viewModel.setSelection(for: table.id, isSelected: $0) }
                                    )
                                )
                                .disabled(viewModel.isBusy)
                            }
                        } header: {
                            tableColumnHeaders
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

    @ViewBuilder private var emptyState: some View {
        if viewModel.isBusy {
            tableMessage("กำลังโหลดตาราง…", detail: "ตรวจสอบ schema และ primary key ของทั้งสองฐานข้อมูล", symbol: "tablecells")
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 28)).foregroundStyle(DomtaTheme.target(colorScheme))
                Text("โหลดตารางไม่สำเร็จ").font(.system(size: 15, weight: .semibold))
                ScrollView {
                    Text(error).font(.system(size: 12)).foregroundStyle(DomtaTheme.placeholder(colorScheme)).textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 100)
                Button("Try Again") { viewModel.loadComparableTables() }.buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            tableMessage("ยังไม่มีตารางที่พร้อม compare", detail: "ตรวจสอบว่า Source และ Target มีตารางที่ schema และ primary key ตรงกัน", symbol: "tablecells")
        }
    }

    private func tableMessage(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(accent)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(DomtaTheme.placeholder(colorScheme))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func operationStatus(_ title: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let progress = viewModel.progressState {
                    Text(progress.message).font(.system(size: 12)).foregroundStyle(DomtaTheme.placeholder(colorScheme))
                        .lineLimit(2)
                    if let fraction = progress.fractionCompleted, !progress.showsIndeterminateSpinner {
                        ProgressView(value: fraction)
                    }
                }
            }
            Spacer()
            if let elapsed = viewModel.operationElapsedText {
                Text(elapsed).font(.system(size: 11)).monospacedDigit().foregroundStyle(DomtaTheme.placeholder(colorScheme))
            }
        }
        .padding(14)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var nextAction: some View {
        VStack(alignment: .leading, spacing: 18) {
            Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1)
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(viewModel.selectedTableKeys.count) tables selected")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    Text("ตรวจความต่างของข้อมูล แล้วตรวจทานผลก่อนสร้างสคริปต์")
                        .font(.system(size: 12)).foregroundStyle(DomtaTheme.placeholder(colorScheme))
                }
                Spacer(minLength: 0)
                Button(action: onCompare) {
                    HStack(spacing: 10) {
                        Text("Compare Selected")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(DomtaPrimaryButtonStyle())
                .disabled(viewModel.selectedTableKeys.isEmpty || viewModel.isBusy)
            }
        }
    }
}

private struct DomtaComparableTableRow: View {
    let table: ComparableTable
    @Binding var isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack(spacing: 16) {
                Text(table.displayName)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(table.primaryKeyDisplay)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DomtaTheme.placeholder(colorScheme))
                    .frame(width: 180, alignment: .leading)
                Text("\(table.columns.count)")
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(DomtaTheme.placeholder(colorScheme))
                    .frame(width: 64, alignment: .trailing)
            }
            .lineLimit(1).truncationMode(.middle)
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(isSelected ? DomtaTheme.selection(colorScheme).opacity(0.6) : (isHovered ? DomtaTheme.canvas(colorScheme) : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(DomtaTheme.rule(colorScheme).opacity(0.5)).frame(height: 0.5) }
        .onHover { isHovered = $0 }
        .help("\(table.displayName)\nPrimary key: \(table.primaryKeyDisplay)")
        .accessibilityLabel("\(table.displayName), primary key \(table.primaryKeyDisplay), \(table.columns.count) columns")
    }
}
