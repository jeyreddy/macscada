import SwiftUI

struct AddressSpaceNodeRow: View {
    let node: OPCUANode
    let onToggleExpansion: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            // Indentation
            ForEach(0..<node.level, id: \.self) { _ in
                Spacer()
                    .frame(width: 20)
            }
            
            // Expansion toggle
            if node.hasChildren {
                Button {
                    print("DEBUG: Chevron clicked for \(node.displayName)")
                    onToggleExpansion()
                } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.blue) // Make it blue so it's visible
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless) // Changed from .plain
                .help("Click to expand/collapse")
            } else {
                Spacer()
                    .frame(width: 16)
            }
            
            // Icon
            Image(systemName: node.nodeClass.icon)
                .foregroundColor(nodeClassColor(node.nodeClass))
                .frame(width: 16)
            
            // Display name
            Text(node.displayName)
                .lineLimit(1)
            
            Spacer()
            
            // Node class badge
            Text(node.nodeClass.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(nodeClassColor(node.nodeClass).opacity(0.2))
                .foregroundColor(nodeClassColor(node.nodeClass))
                .cornerRadius(4)
            
            // Debug: Show hasChildren state
            if node.hasChildren {
                Text("📁")
            } else {
                Text("📄")
            }
        }
        .padding(.vertical, 2)
        .onAppear {
         //   print("DEBUG ROW: \(node.displayName) - hasChildren=\(node.hasChildren), level=\(node.level)")
        }
    }
    
    private func nodeClassColor(_ nodeClass: NodeClass) -> Color {
        switch nodeClass {
        case .object: return .blue
        case .variable: return .green
        case .method: return .purple
        case .objectType: return .cyan
        case .variableType: return .mint
        case .referenceType: return .orange
        case .dataType: return .yellow
        case .view: return .pink
        }
    }
}
