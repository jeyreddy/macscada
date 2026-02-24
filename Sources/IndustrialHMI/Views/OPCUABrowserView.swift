import SwiftUI

struct OPCUABrowserView: View {
    @StateObject private var viewModel: OPCUABrowserViewModel
    @EnvironmentObject var opcuaService: OPCUAClientService

    init(opcuaService: OPCUAClientService, tagEngine: TagEngine, alarmManager: AlarmManager) {
        _viewModel = StateObject(wrappedValue: OPCUABrowserViewModel(
            opcuaService: opcuaService,
            tagEngine: tagEngine,
            alarmManager: alarmManager
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            searchBar
            Divider()
            nodeListView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footerHint
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusLabel)
                .font(.caption.bold())
            Spacer()
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
            Text("\(viewModel.flattenedNodes.count) nodes")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusColor: Color {
        if Configuration.simulationMode { return .blue }
        return viewModel.isConnected ? .green : .gray
    }

    private var statusLabel: String {
        if Configuration.simulationMode { return "Simulation" }
        return viewModel.isConnected ? "Connected" : "Disconnected"
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary).font(.caption)
            TextField("Search nodes…", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: viewModel.searchText) { _, q in
                    viewModel.searchNodes(query: q)
                }
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    viewModel.searchNodes(query: "")
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Node Tree (full width)

    private var nodeListView: some View {
        Group {
            if viewModel.isLoading && viewModel.flattenedNodes.isEmpty {
                ProgressView("Loading address space…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.flattenedNodes.isEmpty {
                ContentUnavailableView(
                    "No Nodes",
                    systemImage: "folder",
                    description: Text(
                        viewModel.isConnected || Configuration.simulationMode
                            ? "No nodes found in address space"
                            : "Connect to server to browse nodes"
                    )
                )
            } else {
                List(viewModel.flattenedNodes) { node in
                    AddressSpaceNodeRow(
                        node: node,
                        onToggleExpansion: {
                            Task { await viewModel.toggleNodeExpansion(node) }
                        }
                    )
                    .onTapGesture(count: 2) {
                        guard node.nodeClass == .variable else { return }
                        Task { await viewModel.addTagFromNode(node) }
                    }
                    .contextMenu {
                        if node.nodeClass == .variable {
                            Button {
                                Task { await viewModel.addTagFromNode(node) }
                            } label: {
                                Label("Add to Tags", systemImage: "plus.circle")
                            }
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(node.nodeId, forType: .string)
                        } label: {
                            Label("Copy Node ID", systemImage: "doc.on.doc")
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Footer

    private var footerHint: some View {
        Text("Double-click a variable node to add it to the tag list")
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
    }
}
