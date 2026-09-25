import AppKit
import SwiftUI

struct SchemaScriptView: View {
    @ObservedObject var viewModel: SchemaCompareViewModel
    let source: SchemaCompareEndpoint
    let target: SchemaCompareEndpoint
    let onEditConnections: () -> Void
    let onCompareResult: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDetails = false
    @State private var exportMessage: String?

    private var muted: Color { DomtaTheme.placeholder(colorScheme) }
    private var isGenerating: Bool { !viewModel.showsFullScript && viewModel.selectedScriptState.isGenerating }

    var body: some View {
        let script = viewModel.displayedScript
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar.frame(width: geometry.size.width < 1200 ? 238 : 268)
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Review your deployment.")
                            .font(.system(size: 36, weight: .semibold)).tracking(-1.1)
                        Text("ตรวจสคริปต์สำหรับปรับ schema ของ Target ให้ตรงกับ Source ก่อนนำไปใช้งาน")
                            .font(.system(size: 13)).foregroundStyle(muted)
                    }
                    scriptOptions
                    scriptPane(script)
                    exportActions
                }
                .padding(32)
                .frame(maxWidth: 1240)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 1180, minHeight: 780)
        .background(DomtaTheme.canvas(colorScheme))
        .tint(DomtaTheme.accent(colorScheme))
        .navigationTitle("Deployment Script")
        .toolbarBackground(DomtaTheme.canvas(colorScheme), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onChange(of: viewModel.showsFullScript) { exportMessage = nil }
        .onChange(of: viewModel.scriptFormat) { exportMessage = nil }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image("DomtaLogo").resizable().interpolation(.none).scaledToFit()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("domta").font(.system(size: 25, weight: .bold, design: .monospaced)).tracking(-0.8)
                    Text("Database compare").font(.system(size: 11))
                        .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
                }
            }.padding(.bottom, 36)
            sidebarButton("Connections", symbol: "externaldrive.connected.to.line.below", action: onEditConnections)
            sidebarButton("Schema Compare", symbol: "list.bullet.rectangle", action: onCompareResult)
            Label("Deployment Script", systemImage: "doc.text")
                .foregroundStyle(DomtaTheme.accent(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading).padding(13)
                .background(DomtaTheme.selection(colorScheme), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityAddTraits(.isSelected)
            VStack(alignment: .leading, spacing: 22) {
                Text("Current comparison").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
                endpoint(source, isSource: true)
                endpoint(target, isSource: false)
            }.padding(.top, 32)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 12) {
                Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1)
                Label("Schema Compare", systemImage: "square.stack.3d.up").font(.system(size: 11, weight: .medium))
                Text("Compare. Review. Script.").font(.system(size: 11))
            }.foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
        }
        .font(.system(size: 13, weight: .semibold)).padding(22)
        .foregroundStyle(DomtaTheme.sidebarInk(colorScheme))
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(DomtaTheme.sidebar(colorScheme))
    }

    private func sidebarButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading).padding(13).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(viewModel.isBusy)
    }

    private func endpoint(_ endpoint: SchemaCompareEndpoint, isSource: Bool) -> some View {
        let name: String
        let detail: String
        switch endpoint {
        case .database(let input):
            let config = try? ConnectionStringParser.parse(input.connectionString)
            name = config?.database ?? "Database"
            detail = config?.server ?? "Connection unavailable"
        case .dacpac(let url):
            name = url.lastPathComponent
            detail = url.deletingLastPathComponent().path
        }
        return VStack(alignment: .leading, spacing: 7) {
            Label(isSource ? "Source" : "Target", systemImage: endpoint.kind.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSource ? DomtaTheme.source(colorScheme) : DomtaTheme.target(colorScheme))
            Text(name).font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.middle).help(name)
            Text(detail).font(.system(size: 11)).foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
                .lineLimit(2).truncationMode(.middle).help(detail)
        }.textSelection(.enabled)
    }

    private var scriptOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scope").font(.system(size: 12, weight: .medium))
                    Picker("Scope", selection: $viewModel.showsFullScript) {
                        Text("Selected objects (\(viewModel.includedRowIDs.count))").tag(false)
                        Text("Full script (\(viewModel.rows.count))").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                }.frame(width: 420, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Format").font(.system(size: 12, weight: .medium))
                    Picker("Format", selection: $viewModel.scriptFormat) {
                        ForEach(SchemaScriptFormat.allCases) { format in Text(format.title).tag(format) }
                    }.pickerStyle(.segmented).labelsHidden()
                }.frame(width: 240, alignment: .leading)
                Spacer(minLength: 0)
            }
            Text(viewModel.scriptFormat.help).font(.system(size: 12)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scriptPane(_ script: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Deployment Script").font(.system(size: 19, weight: .semibold))
                Spacer()
                if !script.isEmpty {
                    Text("\(script.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(muted)
                }
            }
            generationStatus
            ZStack {
                if isGenerating {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        Text("กำลังสร้างสคริปต์สำหรับ object ที่เลือก").font(.system(size: 13, weight: .medium))
                        Text("รวม dependency ที่จำเป็นสำหรับการปรับ Target").font(.system(size: 12)).foregroundStyle(muted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text").font(.system(size: 28)).foregroundStyle(muted)
                        Text("ยังไม่มีสคริปต์ในขอบเขตนี้").font(.system(size: 15, weight: .medium))
                        Button("Back to Schema Compare", action: onCompareResult).buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DeploymentScriptTextView(script: script, colorScheme: colorScheme)
                }
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            .background(DomtaTheme.surface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DomtaTheme.rule(colorScheme), lineWidth: 1).allowsHitTesting(false) }
        }.frame(maxHeight: .infinity)
    }

    @ViewBuilder private var generationStatus: some View {
        if viewModel.showsFullScript {
            Label("ครอบคลุมทุก object ในกลุ่มที่เปิดไว้ใน Options", systemImage: "doc.text")
                .font(.system(size: 12)).foregroundStyle(muted)
        } else if case .generating(let message) = viewModel.selectedScriptState {
            Text(message).font(.system(size: 12)).foregroundStyle(muted).lineLimit(2).help(message)
        } else if let result = viewModel.selectedScriptState.result {
            HStack(alignment: .top, spacing: 12) {
                Label(result.usedFallback ? "สร้างด้วยการกรองข้อความ — dependency อาจไม่ครบ" : "สร้างด้วย DacFx พร้อม dependency ที่จำเป็น",
                      systemImage: result.usedFallback ? "exclamationmark.triangle" : "checkmark.shield")
                    .foregroundStyle(result.usedFallback ? DomtaTheme.target(colorScheme) : muted)
                Spacer(minLength: 0)
                Button { showsDetails.toggle() } label: {
                    Label(result.warnings.isEmpty && result.forcedIncluded.isEmpty ? "Details" : "Details (\(result.warnings.count + result.forcedIncluded.count))", systemImage: "info.circle")
                }.buttonStyle(.borderless)
                    .popover(isPresented: $showsDetails) {
                        ScrollView { selectedSummary(result).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(width: 520, height: 320)
                    }
            }.font(.system(size: 12))
        }
    }

    private var exportActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1)
            Label("ตรวจ DROP และ ALTER TABLE ก่อนรันจริง เพราะอาจทำให้ข้อมูลสูญหาย", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(DomtaTheme.target(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Group {
                    if let exportMessage {
                        Text(exportMessage).textSelection(.enabled).help(exportMessage)
                    } else {
                        Text("\(viewModel.showsFullScript ? "Full script" : "Selected objects") · \(viewModel.scriptFormat.title)")
                    }
                }.font(.system(size: 12)).foregroundStyle(muted).lineLimit(2)
                Spacer(minLength: 12)
                Button {
                    viewModel.copyScriptToPasteboard()
                    exportMessage = viewModel.statusMessage
                } label: { Label("Copy Script", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered).controlSize(.large).disabled(!viewModel.canExportScript)
                Button {
                    viewModel.errorMessage = nil
                    viewModel.statusMessage = nil
                    viewModel.saveScriptToFile()
                    exportMessage = viewModel.errorMessage ?? viewModel.statusMessage
                } label: { Label("Save as .sql", systemImage: "square.and.arrow.down") }
                    .buttonStyle(DomtaPrimaryButtonStyle()).disabled(!viewModel.canExportScript)
            }
        }
    }
    @ViewBuilder
    private func selectedSummary(_ result: SelectedScriptResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.usedFallback {
                Label(
                    "DacFx helper ใช้ไม่ได้ จึงตัด script เต็มแบบข้อความแทน — script นี้อาจรันไม่ผ่านถ้า object ที่เลือกพึ่ง object ที่ตัดออก",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(DomtaTheme.target(colorScheme))

                if let reason = result.fallbackReason {
                    Text(reason)
                        .foregroundStyle(muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let filter = result.filter {
                    Label(
                        filter.didFilterAnything
                            ? "ตัด \(filter.removedSectionCount) ส่วนที่เป็นของ object ที่ไม่ได้ติ๊กออก เหลือ \(filter.keptSectionCount) ส่วน"
                            : "ทุก object ถูกติ๊กไว้ script จึงเท่ากับ script เต็ม",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .foregroundStyle(muted)
                }
            } else {
                Label(
                    "DacFx เก็บ \(result.included.count) object จาก \(result.differenceCount) ความต่าง (ตัดออก \(result.excludedCount)) — dependency ที่ object เหล่านี้ต้องใช้ เช่น FK ของตารางอื่น ถูกใส่ไว้ให้แล้ว",
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(muted)

                if !result.forcedIncluded.isEmpty {
                    Label(
                        "เก็บเพิ่ม \(result.forcedIncluded.count) object ที่ไม่ได้ติ๊ก เพราะ object ที่ติ๊กต้องพึ่ง: "
                            + result.forcedIncluded.map { "\($0.key) (\($0.action))" }.joined(separator: ", "),
                        systemImage: "link"
                    )
                    .foregroundStyle(DomtaTheme.target(colorScheme))
                    .textSelection(.enabled)
                }

                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .foregroundStyle(muted)
                }
            }
        }
        .font(.caption)
    }
}

/// Native, selectable SQL output with Find support; the generated script is read-only.
private struct DeploymentScriptTextView: NSViewRepresentable {
    let script: String
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Deployment SQL script")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != script {
            textView.string = script
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
        }
        textView.backgroundColor = NSColor(DomtaTheme.surface(colorScheme))
        textView.textColor = NSColor(DomtaTheme.sidebarInk(colorScheme))
    }
}
