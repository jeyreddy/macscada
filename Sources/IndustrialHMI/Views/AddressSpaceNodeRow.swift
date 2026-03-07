// MARK: - AddressSpaceNodeRow.swift
//
// Single row view for a node in the OPC-UA address space tree (OPCUABrowserView).
// Renders indentation, expand/collapse toggle, node class icon, display name, and nodeId.
//
// ── Indentation ───────────────────────────────────────────────────────────────
//   ForEach(0..<node.level) { _ in Spacer().frame(width: 20) }
//   node.level is set by OPCUABrowserViewModel during tree flattening:
//   root nodes = 0, their children = 1, grandchildren = 2, etc.
//
// ── Expand/Collapse Toggle ────────────────────────────────────────────────────
//   Shown only when node.hasChildren = true.
//   Shows chevron.right (collapsed) or chevron.down (expanded).
//   Tapping calls onToggleExpansion() → OPCUABrowserViewModel.toggleExpansion(node).
//   node.hasChildren is set during browse; hasChildren may be true even before
//   children are loaded (lazy browse on first expand).
//
// ── Node Class Icons ──────────────────────────────────────────────────────────
//   node.nodeClass.icon: SF Symbol from OPCUANode extension:
//     Object   → "cube"
//     Variable → "number"
//     Method   → "function"
//     ObjectType, VariableType → shape.fill variants
//   nodeClassColor(_ class:): semantic Color per class for quick visual scanning.
//
// ── Double-Click Tag Creation ─────────────────────────────────────────────────
//   OPCUABrowserView wraps rows in a gesture recognizer for double-click detection.
//   Double-clicking a Variable node calls OPCUABrowserViewModel.createTagFromNode(_:).
//   The footerHint in OPCUABrowserView shows "Double-click a Variable to create a tag".

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
