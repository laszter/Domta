import SwiftUI

/// Shared navigation and connection context for the data comparison workflow.
struct DomtaDataSidebar: View {
    enum Step { case tables, results }
    @ObservedObject var viewModel: CompareViewModel
    let step: Step
    let onEditConnections: () -> Void
    var onChooseTables: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DomtaTheme.accent(colorScheme) }

    var body: some View {
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

            Button(action: onEditConnections) {
                Label("Connections", systemImage: "externaldrive.connected.to.line.below")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .help("Edit source and target connections")

            if step == .tables {
                activeStep("Comparable Tables", symbol: "tablecells")
            } else {
                Button(action: onChooseTables) {
                    Label("Comparable Tables", systemImage: "tablecells")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isBusy)
                activeStep("Compare Result", symbol: "list.bullet.rectangle")
            }

            VStack(alignment: .leading, spacing: 22) {
                Text("Current comparison")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
                endpoint(isSource: true)
                endpoint(isSource: false)
            }
            .padding(.top, 32)

            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 12) {
                Rectangle().fill(DomtaTheme.rule(colorScheme)).frame(height: 1)
                Label("Data Compare", systemImage: "tablecells")
                    .font(.system(size: 11, weight: .medium))
                Text("Compare. Review. Script.").font(.system(size: 11))
            }
            .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(22)
        .foregroundStyle(DomtaTheme.sidebarInk(colorScheme))
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(DomtaTheme.sidebar(colorScheme))
    }

    private func endpoint(isSource: Bool) -> some View {
        let connection = isSource ? viewModel.sourceConnectionString : viewModel.targetConnectionString
        let configuration = try? ConnectionStringParser.parse(connection)
        let title = isSource ? "Source" : "Target"
        return VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: isSource ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSource ? DomtaTheme.source(colorScheme) : DomtaTheme.target(colorScheme))
            Text(configuration?.database ?? "Database")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2).truncationMode(.middle)
            Text(configuration?.server ?? "Connection unavailable")
                .font(.system(size: 11))
                .foregroundStyle(DomtaTheme.sidebarMuted(colorScheme))
                .lineLimit(2).truncationMode(.middle)
        }
        .textSelection(.enabled)
    }

    private func activeStep(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(DomtaTheme.selection(colorScheme), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityAddTraits(.isSelected)
    }
}
