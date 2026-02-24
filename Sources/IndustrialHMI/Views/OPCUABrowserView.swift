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
        let _ = { diagLog("DIAG [OPCUABrowserView] body evaluated — connected=\(viewModel.isConnected), nodes=\(viewModel.flattenedNodes.count), loading=\(viewModel.isLoading), error=\(viewModel.errorMessage ?? "nil")") }()
        VStack(spacing: 0) {
            // Connection status bar
            HStack {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                
                Text(viewModel.isConnected ? "Connected" : "Disconnected")
                    .font(.headline)
                
                Spacer()
                
                // Connection managed by main app
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Main content
            HSplitView {
                // Left: Address space tree
                addressSpaceView
                    .frame(minWidth: 250, idealWidth: 350)
                
                // Right: Monitored items
                monitoredItemsView
	        .frame(minWidth: 350, idealWidth: 450, maxWidth: .infinity)            }
        }
        .navigationTitle("OPC-UA Browser")
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
    
    // MARK: - Address Space View
    
   private var addressSpaceView: some View {
        VStack(spacing: 0) {
            searchBarView
            
            Divider()
            
            nodeListView
        }
    }
    
    private var searchBarView: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search nodes...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .onChange(of: viewModel.searchText) { _, newValue in
                    viewModel.searchNodes(query: newValue)
                }
            
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
private var nodeListView: some View {
        Group {
            if viewModel.isLoading && viewModel.flattenedNodes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.flattenedNodes.isEmpty {
                ContentUnavailableView(
                    "No Nodes",
                    systemImage: "folder",
                    description: Text("Connect to server to browse nodes")
                )
            } else {
                List(viewModel.flattenedNodes) { node in
                    	AddressSpaceNodeRow(
                        node: node,
                        onToggleExpansion: {
                            Task {
                                await viewModel.toggleNodeExpansion(node)
                            }
                        }
                    )
                    .onTapGesture(count: 2) {
                        // Double-click to add variable
                        if node.nodeClass == .variable {
                            Task {
                                await viewModel.addToMonitoredItems(node)
                            }
                        }
                    }

                }
                .listStyle(.sidebar)
            }
        }
    }
    // MARK: - Monitored Items View
    
    private var monitoredItemsView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Monitored Items (\(viewModel.monitoredItems.count))")
                    .font(.headline)
                
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // List
            if viewModel.monitoredItems.isEmpty {
                ContentUnavailableView(
                    "No Monitored Items",
                    systemImage: "eye.slash",
                    description: Text("Right-click variables to add them")
                )
            } else {
                List(viewModel.monitoredItems) { item in
                    HStack {
                        Circle()
                            .fill(qualityColor(item.quality))
                            .frame(width: 8, height: 8)
                        Text(item.displayName)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 120, alignment: .leading)
                        Spacer()
                        Text(formatValue(item.currentValue))
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.semibold)
                            .frame(minWidth: 80, alignment: .trailing)
                        Text(qualityText(item.quality))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(qualityColor(item.quality).opacity(0.2))
                            .foregroundColor(qualityColor(item.quality))
                            .cornerRadius(4)
                        Button {
                            Task { await viewModel.removeMonitoredItem(item) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func nodeContextMenu(for node: OPCUANode) -> some View {
        Group {
            if node.nodeClass == .variable {
                Button {
                    Task {
                        await viewModel.addToMonitoredItems(node)
                    }
                } label: {
                    Label("Add to Monitored Items", systemImage: "plus.circle")
                }
            }
            
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.nodeId, forType: .string)
            } label: {
                Label("Copy NodeId", systemImage: "doc.on.doc")
            }
        }
    }
    
    private func qualityColor(_ quality: TagQuality) -> Color {
        switch quality {
        case .good: return .green
        case .uncertain: return .yellow
        case .bad: return .red
        }
    }
    
    private func formatValue(_ value: TagValue) -> String {
        switch value {
        case .analog(let val):
            return String(format: "%.2f", val)
        case .digital(let val):
            return val ? "TRUE" : "FALSE"
        case .string(let val):
            return val
        case .none:
            return "N/A"
        }
    }
    private func qualityText(_ quality: TagQuality) -> String {
        switch quality {
        case .good: return "Good"
        case .uncertain: return "Uncertain"
        case .bad: return "Bad"
        }
    }
}

