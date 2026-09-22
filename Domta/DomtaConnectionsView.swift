import SwiftUI

/// Connection setup, saved pairs and the next action share one workspace.
struct DomtaConnectionsView: View {
    @ObservedObject var viewModel: CompareViewModel
    @ObservedObject var schemaViewModel: SchemaCompareViewModel
    let onDataCompare: () -> Void
    let onSchemaCompare: () -> Void
    @StateObject private var dacpacExport = DacpacExportViewModel()
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { DomtaTheme.accent(colorScheme) }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                sidebar.frame(width: geometry.size.width < 1200 ? 238 : 268).disabled(dacpacExport.isExporting)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        workspaceHeader
                        modePicker.disabled(dacpacExport.isExporting)
                        if let title = viewModel.activeOperationTitle { operationStatus(title) }
                        connectionWorkspace.disabled(dacpacExport.isExporting)
                        if dacpacExport.message != nil { exportStatus }
                        nextAction.disabled(dacpacExport.isExporting)
                        workflowFooter
                    }
                    .padding(32)
                    .frame(maxWidth: 1240)
                    .frame(maxWidth: .infinity)
                }
                .background(DomtaTheme.canvas(colorScheme))
            }
        }
        .frame(minWidth: 1180, minHeight: 780)
        .tint(accent)
        .navigationTitle("Connections")
        .toolbarBackground(DomtaTheme.canvas(colorScheme), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onChange(of: viewModel.sourceConnectionString) { _, _ in viewModel.sourceTestMessage = nil }
        .onChange(of: viewModel.targetConnectionString) { _, _ in viewModel.targetTestMessage = nil }
        .onChange(of: viewModel.sourcePassword) { _, _ in viewModel.sourceTestMessage = nil }
        .onChange(of: viewModel.targetPassword) { _, _ in viewModel.targetTestMessage = nil }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image("DomtaLogo")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("domta").font(.system(size: 25, weight: .bold, design: .monospaced)).tracking(-0.8)
                    Text("Database compare")
                        .font(.system(size: 11))
                        .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
                }
            }
            .padding(.bottom, 36)
            Label("Connections", systemImage: "externaldrive.connected.to.line.below")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DomtaTheme.accent(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(DomtaTheme.selection(colorScheme), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityAddTraits(.isSelected)
            HStack {
                Text("Recent connections").font(.system(size: 12, weight: .medium))
                Spacer()
                Menu {
                    Button("Open Preferences File", systemImage: "folder") { viewModel.revealPreferencesFile() }
                    Button("Clear Recent Connections", systemImage: "trash") { viewModel.clearRecentConnections() }
                        .disabled(viewModel.recentConnectionPairs.isEmpty || viewModel.isBusy)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Manage recent connections")
                .help("Manage recent connections")
            }
            .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
            .padding(.top, 32)
            .padding(.bottom, 14)
            if viewModel.recentConnectionPairs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22, weight: .light)).padding(.bottom, 4)
                    Text("Your next session\nstarts here.")
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(DomtaTheme.sidebarInk(colorScheme))
                    Text("คู่ connection ที่ใช้จะอยู่ตรงนี้\nเลือกกลับมาเริ่มงานต่อได้ทันที")
                        .font(.system(size: 12)).lineSpacing(4)
                }
                .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
                .padding(.vertical, 12)
                Spacer(minLength: 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.recentConnectionPairs) { pair in recentPair(pair) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1)
                Label("SQL Server / Azure SQL", systemImage: "externaldrive")
                    .font(.system(size: 11, weight: .medium))
                Text("Compare. Review. Script.").font(.system(size: 11))
            }
            .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
            .padding(.top, 20)
        }
        .padding(22)
        .foregroundStyle(DomtaTheme.sidebarInk(colorScheme))
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(DomtaTheme.sidebar(colorScheme))
        .tint(DomtaTheme.accent(colorScheme))
    }

    private func recentPair(_ pair: RecentConnectionPair) -> some View {
        Button { viewModel.applyRecentConnectionPair(pair) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "externaldrive").foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
                    Text(databaseLabel(pair.sourceConnectionString)).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 7) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(DomtaTheme.accent(colorScheme))
                    Text(databaseLabel(pair.targetConnectionString)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                Text(pair.detailText).font(.system(size: 10))
                    .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme)).padding(.leading, 21)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ConnectionRecentButtonStyle())
        .disabled(viewModel.isBusy)
        .help(pair.displayName)
        .accessibilityLabel("Use connection pair: \(pair.displayName)")
    }

    private func databaseLabel(_ connectionString: String) -> String {
        guard let config = try? ConnectionStringParser.parse(connectionString) else { return "Unknown database" }
        return config.database ?? config.server
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("A clear view of\nwhat changed.")
                    .font(.system(size: 36, weight: .semibold)).tracking(-1.1).lineSpacing(-1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 24)
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(DomtaTheme.source(colorScheme))
                    Text("VS")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(DomtaTheme.sidebarInk(colorScheme))
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(DomtaTheme.target(colorScheme))
                }
                .font(.system(size: 32, weight: .medium))
                .padding(16)
                .background(DomtaTheme.selection(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            }
            Text("เชื่อมต่อสองฐานข้อมูล ตรวจความต่าง แล้วสร้างสคริปต์ในพื้นที่เดียว")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modePicker: some View {
        HStack(alignment: .center, spacing: 20) {
            Picker("Compare mode", selection: $viewModel.compareMode) {
                ForEach(CompareMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 340)
            .controlSize(.large).disabled(viewModel.isBusy)
            Spacer(minLength: 0)
            Text(viewModel.compareMode == .data ? "Rows & values" : "Objects & definitions")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1)
        }
    }

    private var connectionWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Set up your comparison").font(.system(size: 19, weight: .semibold))
                Spacer()
                Text("Source → Target")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                endpointEditor(isSource: true)
                endpointEditor(isSource: false)
            }
            .disabled(viewModel.isBusy)
        }
    }

    private func endpointEditor(isSource: Bool) -> some View {
        let kind = isSource ? $viewModel.sourceSchemaEndpointKind : $viewModel.targetSchemaEndpointKind
        let usesDacpac = viewModel.compareMode == .schema && kind.wrappedValue == .dacpac
        let title = isSource ? "Source" : "Target"
        let isTesting = isSource ? viewModel.isTestingSourceConnection : viewModel.isTestingTargetConnection
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isSource ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSource ? DomtaTheme.source(colorScheme) : DomtaTheme.target(colorScheme))
                    .frame(width: 34, height: 34)
                    .background((isSource ? DomtaTheme.source(colorScheme) : DomtaTheme.target(colorScheme)).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(isSource ? "ต้นทาง · ข้อมูลอ้างอิง" : "ปลายทาง · ปรับให้ตรงกับต้นทาง")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if viewModel.compareMode == .schema {
                Picker("\(title) type", selection: kind) {
                    ForEach(SchemaEndpointKind.allCases) { endpointKind in
                        Label(endpointKind.title, systemImage: endpointKind.systemImage).tag(endpointKind)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if usesDacpac {
                dacpacField(isSource: isSource)
            } else {
                ConnectionStringInput(title: title, text: isSource ? $viewModel.sourceConnectionString : $viewModel.targetConnectionString, accent: accent)
                if isSource ? viewModel.sourceNeedsManualPassword : viewModel.targetNeedsManualPassword {
                    SecureField("\(title) password", text: isSource ? $viewModel.sourcePassword : $viewModel.targetPassword)
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                    Text("รหัสผ่านใช้เฉพาะระหว่างเปิดแอป ไม่บันทึกลงดิสก์")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        if isSource { viewModel.testSourceConnection() } else { viewModel.testTargetConnection() }
                    } label: {
                        Label(isTesting ? "Testing…" : "Test Connection", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(isTesting || viewModel.isBusy)
                    Spacer(minLength: 0)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("SQL Authentication").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        dacpacExport.chooseDestinationAndExport(
                            input: isSource ? viewModel.sourceInput : viewModel.targetInput, side: title)
                    } label: {
                        Label("Export DACPAC…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBusy || viewModel.isTestingSourceConnection || viewModel.isTestingTargetConnection || dacpacExport.isExporting)
                    .accessibilityLabel("Export \(title) DACPAC")
                    .help("บันทึก schema ของ \(title) เป็นไฟล์ .dacpac โดยไม่รวมข้อมูลในตาราง")
                    Text("Schema only · ไม่มี data")
                        .font(.system(size: 11)).foregroundStyle(DomtaTheme.placeholder(colorScheme))
                }
                if let message = isSource ? viewModel.sourceTestMessage : viewModel.targetTestMessage, !message.isEmpty {
                    Label(message, systemImage: message.lowercased().contains("connected to") ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(message.lowercased().contains("connected to") ? accent : .red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func dacpacField(isSource: Bool) -> some View {
        let path = isSource ? viewModel.sourceDacpacPath : viewModel.targetDacpacPath
        return VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "doc.zipper").font(.system(size: 26, weight: .light)).foregroundStyle(accent)
            Text(path.isEmpty ? "Choose a schema snapshot" : URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.middle)
            Text(path.isEmpty ? "ใช้ไฟล์ .dacpac แทนการเชื่อมต่อฐานข้อมูล" : path)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
            Button(path.isEmpty ? "Choose File…" : "Change File…") {
                if isSource { viewModel.chooseSourceDacpac() } else { viewModel.chooseTargetDacpac() }
            }
            .buttonStyle(.bordered).disabled(viewModel.isBusy)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
        .background(DomtaTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DomtaTheme.rule(colorScheme), lineWidth: 1) }
    }

    private var exportStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            if dacpacExport.isExporting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: dacpacExport.isError ? "exclamationmark.circle" : (dacpacExport.exportedURL == nil ? "info.circle" : "checkmark.circle"))
                    .foregroundStyle(dacpacExport.isError ? DomtaTheme.target(colorScheme) : accent)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(dacpacExport.isExporting ? "Exporting DACPAC · \(dacpacExport.exportingLabel)" : "Export DACPAC")
                    .font(.system(size: 13, weight: .semibold))
                Text(dacpacExport.message ?? "")
                    .font(.system(size: 12)).foregroundStyle(DomtaTheme.placeholder(colorScheme))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let url = dacpacExport.exportedURL {
                    Text(url.path).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DomtaTheme.placeholder(colorScheme)).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if dacpacExport.isExporting {
                Button("Cancel") { dacpacExport.cancel() }.buttonStyle(.bordered)
            } else if dacpacExport.exportedURL != nil {
                Button("Show in Finder") { dacpacExport.revealExport() }.buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background((dacpacExport.isError ? DomtaTheme.target(colorScheme) : accent).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var nextAction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1)
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(viewModel.compareMode == .data ? "Start with the tables." : "Start with the schema.")
                        .font(.system(size: 14, weight: .semibold))
                    Text(viewModel.compareMode == .data ? "ตรวจ connection แล้วเลือกตารางที่ต้องการเทียบ" : "เทียบ table, view และ stored procedure จากทั้งสองฝั่ง")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: viewModel.compareMode == .data ? onDataCompare : onSchemaCompare) {
                    HStack(spacing: 10) {
                        Text(viewModel.compareMode == .data ? "Load Comparable Tables" : "Open Schema Compare")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .buttonStyle(DomtaPrimaryButtonStyle()).controlSize(.large)
                .disabled(viewModel.isBusy || (viewModel.compareMode == .schema && (!schemaViewModel.isSqlPackageAvailable || !viewModel.hasRequiredDacpacFiles)))
            }
            if viewModel.compareMode == .schema {
                if !schemaViewModel.isSqlPackageAvailable {
                    Label("ไม่พบ sqlpackage — ติดตั้งด้วย dotnet tool install --global microsoft.sqlpackage", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(DomtaTheme.target(colorScheme)).textSelection(.enabled)
                } else if !viewModel.hasRequiredDacpacFiles {
                    Label("เลือกไฟล์ .dacpac ให้ครบก่อนเริ่มเปรียบเทียบ", systemImage: "doc.badge.plus")
                        .font(.system(size: 12)).foregroundStyle(DomtaTheme.target(colorScheme))
                }
            }
        }
    }

    private var workflowFooter: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Connect", systemImage: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(accent)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                Text("Compare")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                Text("Review script")
                Spacer()
                Text(viewModel.compareMode == .data ? "Requires sqlcmd" : "Requires sqlcmd + sqlpackage")
                    .font(.system(size: 10, design: .monospaced))
            }
            .font(.system(size: 11, weight: .medium))
            Label("สคริปต์ที่สร้างจะไม่ถูกรันอัตโนมัติ คุณตรวจสอบก่อนนำไปใช้ได้", systemImage: "checkmark.shield")
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary).padding(.top, 4)
    }

    private func operationStatus(_ title: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let progress = viewModel.progressState {
                    Text(progress.message).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let elapsed = viewModel.operationElapsedText {
                Text(elapsed).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(14).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ConnectionStringInput: View {
    let title: String
    @Binding var text: String
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connection string")
                Spacer()
                Image(systemName: "text.alignleft").accessibilityHidden(true)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(DomtaTheme.rule(colorScheme).opacity(0.35))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(5)
                    .scrollContentBackground(.hidden).focused($isFocused)
                    .accessibilityLabel("\(title) connection string").padding(10)
                if text.isEmpty {
                    Text("Server=your-server,1433;\nDatabase=your-database;\nUser ID=your-username;\nPassword=your-password;\nEncrypt=True;")
                        .font(.system(size: 12, design: .monospaced)).lineSpacing(5)
                        .foregroundStyle(DomtaTheme.placeholder(colorScheme))
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(height: 156)
        }
        .background(DomtaTheme.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? accent : DomtaTheme.rule(colorScheme), lineWidth: isFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
    }
}

private struct ConnectionRecentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        RecentButtonBody(configuration: configuration, isEnabled: isEnabled)
    }
    private struct RecentButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let isEnabled: Bool
        @State private var isHovered = false
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .foregroundStyle(DomtaTheme.sidebarInk(colorScheme).opacity(isEnabled ? 1 : 0.45))
                .background(DomtaTheme.accent(colorScheme).opacity(configuration.isPressed ? 0.18 : (isHovered && isEnabled ? 0.10 : 0)), in: RoundedRectangle(cornerRadius: 8))
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        }
    }
}

#Preview("Connections · Light") {
    DomtaConnectionsView(viewModel: CompareViewModel(), schemaViewModel: SchemaCompareViewModel(), onDataCompare: {}, onSchemaCompare: {})
        .preferredColorScheme(.light)
}

#Preview("Connections · Dark") {
    DomtaConnectionsView(viewModel: CompareViewModel(), schemaViewModel: SchemaCompareViewModel(), onDataCompare: {}, onSchemaCompare: {})
        .preferredColorScheme(.dark)
}
