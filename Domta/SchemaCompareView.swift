//
//  SchemaCompareView.swift
//  Domta
//

import SwiftUI

/// Compare results share the logo palette and controls used by Connections.
struct SchemaCompareView: View {
    @ObservedObject var viewModel: SchemaCompareViewModel
    let source: SchemaCompareEndpoint
    let target: SchemaCompareEndpoint
    let onEditConnections: () -> Void
    let onShowScript: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingOptions = false
    @State private var isShowingAlerts = false
    @State private var isShowingErrorDetails = false
    @State private var showsMemberDetails = false
    @State private var splitRatio: CGFloat = 0.43
    @State private var dragStartTopHeight: CGFloat?

    private var accent: Color { DomtaTheme.accent(colorScheme) }
    private var muted: Color { DomtaTheme.placeholder(colorScheme) }

    var body: some View {
        VStack(spacing: 16) {
            toolbar
            if viewModel.isBusy { busyBanner }
            if let error = viewModel.errorMessage { errorBanner(error) }
            if viewModel.report == nil {
                emptyState
            } else {
                resultsToolbar
                if viewModel.rows.isEmpty { differenceGrid } else { splitContent }
            }
        }
        .padding(24)
        .frame(minWidth: 1180, minHeight: 860)
        .background(DomtaTheme.canvas(colorScheme))
        .tint(accent)
        .navigationTitle("Schema Compare")
        .toolbarBackground(DomtaTheme.canvas(colorScheme), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onChange(of: viewModel.selectedRowID) { showsMemberDetails = false }
        .onChange(of: viewModel.filteredRows.map(\.id)) { _, visibleIDs in
            if let id = viewModel.selectedRowID, !visibleIDs.contains(id) {
                viewModel.selectedRowID = nil
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image("DomtaLogo")
                    .resizable().interpolation(.none).scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schema Compare").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    Text("ตรวจความต่าง แล้วเลือกสิ่งที่จะปรับบน Target ให้ตรงกับ Source")
                        .font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer()
                Button { isShowingOptions.toggle() } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(viewModel.isBusy)
                .popover(isPresented: $isShowingOptions, arrowEdge: .bottom) { optionsPopover }
                Button {
                    viewModel.compareSchema(source: source, target: target)
                } label: {
                    Label(viewModel.report == nil ? "Compare" : "Compare Again", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(DomtaPrimaryButtonStyle())
                .disabled(viewModel.isBusy || !viewModel.isSqlPackageAvailable)
            }
            HStack(spacing: 18) {
                connectionField(title: "Source", endpoint: source, value: sourceLabel, tint: DomtaTheme.source(colorScheme))
                Image(systemName: "arrow.right").foregroundStyle(muted).accessibilityHidden(true)
                connectionField(title: "Target", endpoint: target, value: targetLabel, tint: DomtaTheme.target(colorScheme))
                Button { onEditConnections() } label: {
                    Label("Edit Connections", systemImage: "pencil")
                }
                .buttonStyle(.bordered).disabled(viewModel.isBusy)
            }
            .padding(14)
            .background(DomtaTheme.sidebar(colorScheme), in: RoundedRectangle(cornerRadius: 6))
            if !viewModel.isSqlPackageAvailable {
                Label("ไม่พบ sqlpackage — ติดตั้งด้วย dotnet tool install --global microsoft.sqlpackage", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(DomtaTheme.target(colorScheme)).textSelection(.enabled)
            } else if !viewModel.isDotnetAvailable {
                Label("ไม่พบ .NET SDK 10+ — การสร้าง script เฉพาะที่เลือกจะตรวจ dependency ได้จำกัด", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(DomtaTheme.target(colorScheme))
            }
        }
    }

    private func connectionField(title: String, endpoint: SchemaCompareEndpoint, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: endpoint.kind.systemImage)
                .font(.system(size: 18)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold).foregroundStyle(tint)
                    Text("· " + (title == "Source" ? "ข้อมูลอ้างอิง" : "ปลายทางที่จะปรับ"))
                        .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
                }.font(.system(size: 11))
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(DomtaTheme.sidebarInk(colorScheme))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Self.endpointHelp(for: endpoint, label: value))
    }

    private var resultsToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Differences").font(.system(size: 17, weight: .semibold))
                Text("\(viewModel.rows.count) objects").font(.system(size: 12)).foregroundStyle(muted)
                if let report = viewModel.report, !report.alerts.isEmpty {
                    Button { isShowingAlerts.toggle() } label: {
                        Label("Alerts (\(report.alerts.count))", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DomtaTheme.target(colorScheme))
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $isShowingAlerts) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(report.alerts) { alert in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(alert.title).font(.headline)
                                        ForEach(Array(alert.issues.enumerated()), id: \.offset) { _, issue in
                                            Text(issue).font(.callout).textSelection(.enabled)
                                        }
                                    }
                                }
                            }.padding(20)
                        }.frame(width: 440, height: 320)
                    }
                }
                Spacer()
                Text("\(viewModel.includedRowIDs.count) selected for script")
                    .font(.system(size: 12)).foregroundStyle(muted)
                Button(action: onShowScript) {
                    Label("Review Script", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(DomtaPrimaryButtonStyle())
                .disabled(!viewModel.hasScript || !viewModel.hasIncludedRows || viewModel.isBusy)
            }
            HStack(spacing: 12) {
                DomtaSearchField(prompt: "ค้นหาชื่อ object หรือประเภท", text: $viewModel.searchText)
                    .frame(width: 280)
                Picker("Type", selection: $viewModel.categoryFilter) {
                    Text("All types").tag(SchemaObjectCategory?.none)
                    ForEach(viewModel.populatedCategories) { category in
                        Text("\(category.title) (\(viewModel.count(for: category)))").tag(Optional(category))
                    }
                }.frame(width: 220)
                Picker("Action", selection: $viewModel.kindFilter) {
                    Text("All actions").tag(SchemaChangeKind?.none)
                    ForEach(SchemaChangeKind.allCases.filter { viewModel.count(for: $0) > 0 }) { kind in
                        Text("\(kind.actionTitle) (\(viewModel.count(for: kind)))").tag(Optional(kind))
                    }
                }.frame(width: 215)
                if hasFilters {
                    Button("Clear Filters", action: clearFilters).buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                Text("\(viewModel.filteredRows.count) shown").font(.system(size: 11)).foregroundStyle(muted)
            }
            .controlSize(.regular)
        }
    }

    private var hasFilters: Bool {
        !viewModel.searchText.isEmpty || viewModel.categoryFilter != nil || viewModel.kindFilter != nil
    }

    private func clearFilters() {
        viewModel.searchText = ""
        viewModel.categoryFilter = nil
        viewModel.kindFilter = nil
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

            Text("เลือกประเภทที่จะนำมาเปรียบเทียบ ประเภทที่ไม่เลือกจะไม่รวมในผลและ script ใช้กับการ Compare ครั้งถัดไป")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Compare Behavior")
                .font(.subheadline.weight(.semibold))

            Toggle("รวม object ที่มีเฉพาะ Target (เสนอให้ลบ)", isOn: $viewModel.options.reportObjectsOnlyInTarget)
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

    private var sourceLabel: String { Self.endpointLabel(for: source, fallback: "Source") }
    private var targetLabel: String { Self.endpointLabel(for: target, fallback: "Target") }

    /// ฝั่งใดเป็นไฟล์ dacpac → definition มาจาก DacFx ซึ่งรอบแรกช้ากว่า sqlcmd
    private var usesDacpacDefinitions: Bool {
        source.connectionInput == nil || target.connectionInput == nil
    }

    private static func endpointLabel(for endpoint: SchemaCompareEndpoint, fallback: String) -> String {
        switch endpoint {
        case .database(let input): return databaseLabel(for: input, fallback: fallback)
        case .dacpac(let url): return url.lastPathComponent
        }
    }

    /// tooltip ของช่อง source / target — ไฟล์ dacpac แสดง path เต็ม
    private static func endpointHelp(for endpoint: SchemaCompareEndpoint, label: String) -> String {
        if case .dacpac(let url) = endpoint { return url.path }
        return label
    }

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
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.10))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message).lineLimit(2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Details") { isShowingErrorDetails = true }
                .buttonStyle(.bordered)
                .popover(isPresented: $isShowingErrorDetails) {
                    ScrollView {
                        Text(message).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }.frame(width: 560, height: 300)
                }
        }
        .font(.system(size: 12))
        .foregroundStyle(DomtaTheme.target(colorScheme))
        .padding(12)
        .background(DomtaTheme.target(colorScheme).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.isBusy ? "square.stack.3d.up" : "doc.text.magnifyingglass")
                .font(.system(size: 38, weight: .light)).foregroundStyle(accent)
            Text(viewModel.isBusy ? "กำลังตรวจความต่างของ schema" : (viewModel.errorMessage == nil ? "พร้อมตรวจความต่างของ schema" : "ยังเปรียบเทียบไม่สำเร็จ"))
                .font(.system(size: 21, weight: .semibold))
            Text(viewModel.isBusy
                 ? "ผลจะแสดงเป็นรายการ object พร้อมสิ่งที่จะเปลี่ยนบน Target"
                 : "กด Compare เพื่อดู object ที่เพิ่ม เปลี่ยน หรือลบ\nจากนั้นเลือกแต่ละรายการเพื่ออ่าน definition เทียบกัน")
                .font(.system(size: 13)).foregroundStyle(muted)
                .multilineTextAlignment(.center).lineSpacing(5)
            Label("ขั้นตอนนี้ยังไม่แก้ไขฐานข้อมูล", systemImage: "checkmark.shield")
                .font(.system(size: 12)).foregroundStyle(muted).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Split layout

    private var splitContent: some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = 12
            let minTopHeight: CGFloat = 210
            let minBottomHeight: CGFloat = 280
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
            .help("ลากเพื่อปรับพื้นที่รายการและรายละเอียด")
            .accessibilityElement()
            .accessibilityLabel("Resize comparison panels")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: splitRatio = min(0.8, splitRatio + 0.05)
                case .decrement: splitRatio = max(0.2, splitRatio - 0.05)
                @unknown default: break
                }
            }
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

    // MARK: - Difference list

    private var rowSelection: Binding<SchemaCompareRow.ID?> {
        Binding<SchemaCompareRow.ID?>(
            get: { viewModel.selectedRowID },
            set: { id in
                guard let id else { viewModel.selectedRowID = nil; return }
                guard let row = viewModel.rows.first(where: { $0.id == id }) else { return }
                viewModel.select(row: row, source: source, target: target)
            }
        )
    }

    private var differenceGrid: some View {
        VStack(spacing: 0) {
            if !viewModel.rows.isEmpty {
                HStack(spacing: 10) {
                    Toggle("Select visible", isOn: Binding(
                        get: { viewModel.areAllVisibleRowsIncluded },
                        set: { viewModel.setInclusionForVisibleRows($0) }
                    ))
                    .toggleStyle(.checkbox).disabled(viewModel.filteredRows.isEmpty)
                    Text("เลือกแถวเพื่อดูรายละเอียด · ติ๊กเพื่อรวมใน script")
                        .foregroundStyle(muted)
                    Spacer()
                }
                .font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 10)
                .background(DomtaTheme.rule(colorScheme).opacity(0.2))
            }
            if viewModel.filteredRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: viewModel.rows.isEmpty ? "checkmark.circle" : "magnifyingglass")
                        .font(.system(size: 24)).foregroundStyle(accent)
                    Text(viewModel.rows.isEmpty ? "ไม่พบความต่างในขอบเขตที่เลือก" : "ไม่พบ object ที่ตรงกับตัวกรอง")
                        .font(.system(size: 13, weight: .medium))
                    if viewModel.rows.isEmpty {
                        Text("Source และ Target ตรงกันสำหรับประเภทและตัวเลือกที่ใช้เปรียบเทียบ")
                            .font(.system(size: 12)).foregroundStyle(muted)
                    }
                    if hasFilters { Button("Clear Filters", action: clearFilters).buttonStyle(.borderless) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(viewModel.filteredRows, selection: rowSelection) {
                    SwiftUI.TableColumn("Script") { row in
                        Toggle("Include \(row.plainName) in script", isOn: Binding(
                            get: { viewModel.includedRowIDs.contains(row.id) },
                            set: { included in
                                if included != viewModel.includedRowIDs.contains(row.id) { viewModel.toggleInclusion(row) }
                            }
                        )).toggleStyle(.checkbox).labelsHidden()
                    }.width(48)
                    SwiftUI.TableColumn("Object") { row in
                        Label(row.plainName, systemImage: row.category.systemImage)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).help(row.plainName)
                            .padding(.vertical, 5)
                    }.width(min: 240, ideal: 400)
                    SwiftUI.TableColumn("Type") { row in
                        Text(row.typeDisplay).font(.system(size: 12))
                    }.width(min: 90, ideal: 120, max: 160)
                    SwiftUI.TableColumn("Action on Target") { row in
                        SchemaActionBadge(kind: row.kind)
                    }.width(150)
                    SwiftUI.TableColumn("Difference") { row in
                        Text(row.kind.title).font(.system(size: 12))
                            .help(row.memberSummaryLines.joined(separator: "\n"))
                    }.width(min: 130, ideal: 190, max: 230)
                }
                .tableStyle(.inset)
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .accessibilityLabel("Schema differences")
            }
        }
        .background(DomtaTheme.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DomtaTheme.rule(colorScheme), lineWidth: 1).allowsHitTesting(false) }
    }

    // MARK: - Comparison details

    private var detailsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Comparison Details").font(.system(size: 15, weight: .semibold))
                    if let row = viewModel.selectedRow {
                        Text(row.plainName).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(muted).lineLimit(1).truncationMode(.middle).help(row.plainName)
                    }
                }
                if let row = viewModel.selectedRow { SchemaActionBadge(kind: row.kind) }
                Spacer()
                Picker("Definition layout", selection: $viewModel.diffViewMode) {
                    ForEach(SchemaDiffViewMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                .disabled(viewModel.selectedRow == nil)
            }
            if let row = viewModel.selectedRow, !row.memberSummaryLines.isEmpty {
                DisclosureGroup("Related changes (\(row.members.count))", isExpanded: $showsMemberDetails) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(row.memberSummaryLines, id: \.self) { line in
                                Text(line).font(.system(size: 12)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 6)
                    }.frame(maxHeight: 84)
                }.font(.system(size: 12)).foregroundStyle(muted)
            }
            definitionContent
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DomtaTheme.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DomtaTheme.rule(colorScheme), lineWidth: 1).allowsHitTesting(false) }
    }

    @ViewBuilder
    private var definitionContent: some View {
        if viewModel.selectedRow == nil {
            centeredHint("เลือกแถวด้านบนเพื่อดู definition ของทั้งสองฝั่ง")
        } else {
            switch viewModel.definitionState {
            case .idle:
                centeredHint("เลือกแถวด้านบนเพื่อดู definition ของทั้งสองฝั่ง")

            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(usesDacpacDefinitions
                         ? "กำลังให้ DacFx อ่าน definition จาก dacpac ทั้งสองฝั่ง (ครั้งแรกใช้เวลาสักครู่)..."
                         : "กำลังอ่าน definition จากทั้งสองฝั่ง...")
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
                        .foregroundStyle(DomtaTheme.target(colorScheme))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .loaded(let definition):
                definitionDiff(definition)
            }
        }
    }

    private func centeredHint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func definitionDiff(_ definition: SchemaObjectDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Label("+ Source · เพิ่มเข้า Target", systemImage: "plus.square.fill")
                    .foregroundStyle(DomtaTheme.source(colorScheme))
                Label("− Target · นำออกจาก Target", systemImage: "minus.square.fill")
                    .foregroundStyle(DomtaTheme.target(colorScheme))
                Spacer()
                Text("\(definition.changedLineCount) changed lines").foregroundStyle(muted)
            }.font(.system(size: 11, weight: .medium))
            if definition.isTruncated {
                Text("Definition ยาวมาก จึงแสดงบรรทัดเต็มโดยไม่จับคู่ส่วนที่ต่างกัน")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            GeometryReader { geometry in
                let columnWidth = max((geometry.size.width - 2) / 2, definitionColumnWidth(definition))
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            switch viewModel.diffViewMode {
                            case .sideBySide:
                                ForEach(definition.sideBySideRows) { row in
                                    SchemaSideBySideRowView(row: row, columnWidth: columnWidth)
                                        .equatable()
                                }
                            case .unified:
                                ForEach(definition.lines) { line in
                                    SchemaDiffLineView(line: line, width: max(geometry.size.width, columnWidth + 52))
                                        .equatable()
                                }
                            }
                        } header: {
                            if viewModel.diffViewMode == .sideBySide {
                                HStack(spacing: 1) {
                                    definitionHeader("Source", label: definition.sourceText == nil ? "ไม่มี object นี้" : sourceLabel, color: DomtaTheme.source(colorScheme), width: columnWidth)
                                    definitionHeader("Target", label: definition.targetText == nil ? "ไม่มี object นี้" : targetLabel, color: DomtaTheme.target(colorScheme), width: columnWidth)
                                }
                            } else {
                                HStack(spacing: 0) {
                                    Text("Src").frame(width: 44)
                                    Text("Tgt").frame(width: 44)
                                    Text("Definition · + เพิ่ม / − นำออกจาก Target").padding(.leading, 22)
                                    Spacer()
                                }
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                                .frame(width: max(geometry.size.width, columnWidth + 52), height: 32)
                                .background(DomtaTheme.canvas(colorScheme))
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
                .background(DomtaTheme.canvas(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .id("\(viewModel.selectedRowID ?? "")-\(viewModel.diffViewMode.rawValue)")
            }
        }
    }

    /// Keep both halves equally wide and prevent SQL wrapping from misaligning paired rows.
    private func definitionColumnWidth(_ definition: SchemaObjectDefinition) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let widest = definition.lines.map { ($0.text as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(380, ceil(widest) + 76)
    }

    private func definitionHeader(_ title: String, label: String, color: Color, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(color)
            Text(label).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(width: width, height: 32)
        .background(DomtaTheme.canvas(colorScheme))
    }
}

private struct SchemaActionBadge: View {
    let kind: SchemaChangeKind
    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        switch kind {
        case .create: DomtaTheme.source(colorScheme)
        case .drop, .recreate: DomtaTheme.target(colorScheme)
        default: DomtaTheme.accent(colorScheme)
        }
    }

    var body: some View {
        Label(kind.actionTitle, systemImage: kind.systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(DomtaTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.35), lineWidth: 1) }
    }
}

private struct SchemaSideBySideRowView: View, Equatable {
    let row: SchemaSideBySideRow
    let columnWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row && lhs.columnWidth == rhs.columnWidth }

    var body: some View {
        HStack(spacing: 1) {
            cell(row.sourceText, number: row.sourceNumber,
                 marker: row.kind == .changed || row.kind == .sourceOnly ? "+" : " ",
                 tint: DomtaTheme.source(colorScheme))
            cell(row.targetText, number: row.targetNumber,
                 marker: row.kind == .changed || row.kind == .targetOnly ? "−" : " ",
                 tint: DomtaTheme.target(colorScheme))
        }
        .background(DomtaTheme.rule(colorScheme))
    }

    private func cell(_ text: String?, number: Int?, marker: String, tint: Color) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(DomtaTheme.placeholder(colorScheme))
                .frame(width: 36, alignment: .trailing)
            Text(marker).foregroundStyle(tint).frame(width: 24)
            Text(SQLSyntaxHighlighter.highlight(text ?? "", colorScheme: colorScheme))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(width: columnWidth, height: 23, alignment: .leading)
        .background(marker == " " ? Color.clear : tint.opacity(colorScheme == .dark ? 0.12 : 0.07))
        .background(text == nil ? DomtaTheme.rule(colorScheme).opacity(0.18) : DomtaTheme.canvas(colorScheme))
    }
}

private struct SchemaDiffLineView: View, Equatable {
    let line: SchemaDiffLine
    let width: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.line == rhs.line && lhs.width == rhs.width }

    private var tint: Color {
        switch line.kind {
        case .sourceOnly: DomtaTheme.source(colorScheme)
        case .targetOnly: DomtaTheme.target(colorScheme)
        case .unchanged: DomtaTheme.placeholder(colorScheme)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(line.sourceNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing).foregroundStyle(DomtaTheme.placeholder(colorScheme))
            Text(line.targetNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing).foregroundStyle(DomtaTheme.placeholder(colorScheme))
            Text(line.kind.gutterSymbol).frame(width: 24).foregroundStyle(tint)
            Text(SQLSyntaxHighlighter.highlight(line.text, colorScheme: colorScheme))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(width: width, height: 23, alignment: .leading)
        .background(line.kind == .unchanged ? Color.clear : tint.opacity(colorScheme == .dark ? 0.12 : 0.07))
    }
}
