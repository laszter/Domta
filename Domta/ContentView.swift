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
    case schemaCompare
    case schemaScript
}

struct ContentView: View {
    @StateObject private var viewModel = CompareViewModel()
    @StateObject private var schemaViewModel = SchemaCompareViewModel()
    @State private var path: [AppRoute] = []

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
                    case .schemaCompare:
                        SchemaCompareView(
                            viewModel: schemaViewModel,
                            source: viewModel.sourceSchemaEndpoint,
                            target: viewModel.targetSchemaEndpoint,
                            onEditConnections: { path.removeAll() },
                            onShowScript: {
                                schemaViewModel.prepareScript()
                                path.append(.schemaScript)
                            }
                        )
                    case .schemaScript:
                        SchemaScriptView(
                            viewModel: schemaViewModel,
                            source: viewModel.sourceSchemaEndpoint,
                            target: viewModel.targetSchemaEndpoint,
                            onEditConnections: { path.removeAll() },
                            onCompareResult: { path = [.schemaCompare] }
                        )
                    }
                }
        }
    }

    private var connectionPage: some View {
        DomtaConnectionsView(viewModel: viewModel, schemaViewModel: schemaViewModel) {
            viewModel.resetTableSelectionState()
            path.append(.tables)
            viewModel.loadComparableTables()
        } onSchemaCompare: {
            viewModel.rememberCurrentConnectionPair()
            schemaViewModel.clearReport()
            path.append(.schemaCompare)
        }
    }

    private var tablesPage: some View {
        DomtaTablesView(viewModel: viewModel, onEditConnections: { path.removeAll() }) {
            viewModel.clearCompareResultState()
            path.append(.results)
            viewModel.compareSelectedTables()
        }
    }

    private var resultsPage: some View {
        DomtaResultsView(
            viewModel: viewModel,
            onEditConnections: { path.removeAll() },
            onChooseTables: { path = [.tables] },
            onShowScript: { path.append(.script) }
        )
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

}
