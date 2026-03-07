// MARK: - HMIScreenListPane.swift
//
// Sidebar panel that lists all HMI screens and provides screen management actions.
// Embedded in HMIDesignerView via HSplitView as the left panel (fixed ~200 pt).
//
// ── Screen List ───────────────────────────────────────────────────────────────
//   Displays hmiScreenStore.allScreenMeta (ScreenMeta: id + name, lightweight).
//   List selection binding reads hmiScreenStore.currentScreenId and calls
//   hmiScreenStore.switchToScreen(id:) on change — loads the full screen JSON.
//   Selected row highlighted with accentColor.opacity(0.15) background.
//
// ── Screen Actions (context menu per row) ─────────────────────────────────────
//   Rename:     editingId set → row shows TextField; submitted via .onSubmit.
//   Duplicate:  hmiScreenStore.duplicateScreen(id:) — creates a deep copy with a new UUID.
//   Delete:     deletingId set → confirmationDialog → hmiScreenStore.deleteScreen(id:).
//               If deleting the current screen, switches to the first remaining screen.
//
// ── Header Controls ───────────────────────────────────────────────────────────
//   "+" button: hmiScreenStore.createScreen() — creates "New Screen" and switches to it.
//   "⊞" button (composite): navigates to CompositeHMIView (full-site overview).
//
// ── Rename Flow ───────────────────────────────────────────────────────────────
//   When editingId == meta.id, the row shows a TextField bound to editingName.
//   .onSubmit calls hmiScreenStore.renameScreen(id: editingId, name: editingName)
//   then clears editingId. Pressing Escape also clears editingId without saving.
//
// ── Delete Confirmation ───────────────────────────────────────────────────────
//   .confirmationDialog presented when deletingId is non-nil.
//   "Delete" action calls hmiScreenStore.deleteScreen(id: deletingId).
//   Cancelling clears deletingId without deleting. Guard prevents deleting last screen.

import SwiftUI

// MARK: - HMIScreenListPane

/// Left-sidebar panel listing all HMI screens.
/// Embedded in HMIDesignerView via HSplitView.
struct HMIScreenListPane: View {
    @EnvironmentObject var hmiScreenStore: HMIScreenStore

    /// The screen ID currently being renamed (nil = none).
    @State private var editingId: UUID? = nil
    /// Draft name while renaming.
    @State private var editingName: String = ""
    /// The screen ID pending deletion confirmation.
    @State private var deletingId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────
            HStack {
                Text("Screens")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    hmiScreenStore.createScreen()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("New screen")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // ── Screen List ─────────────────────────────────────────────────
            List(hmiScreenStore.allScreenMeta, selection: Binding(
                get: { hmiScreenStore.currentScreenId },
                set: { id in
                    if let id { hmiScreenStore.switchToScreen(id: id) }
                }
            )) { meta in
                screenRow(meta)
                    .tag(meta.id)
                    .listRowBackground(
                        hmiScreenStore.currentScreenId == meta.id
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear
                    )
                    .contextMenu {
                        Button("Rename") {
                            editingId   = meta.id
                            editingName = meta.name
                        }
                        Button("Duplicate") {
                            hmiScreenStore.duplicateScreen(id: meta.id)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            deletingId = meta.id
                        }
                        .disabled(hmiScreenStore.allScreenMeta.count <= 1)
                    }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 180, maxWidth: 220)
        .confirmationDialog(
            "Delete Screen?",
            isPresented: Binding(
                get: { deletingId != nil },
                set: { if !$0 { deletingId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deletingId {
                    hmiScreenStore.deleteScreen(id: id)
                }
                deletingId = nil
            }
            Button("Cancel", role: .cancel) { deletingId = nil }
        } message: {
            let name = hmiScreenStore.allScreenMeta
                .first(where: { $0.id == deletingId })?.name ?? "this screen"
            Text("\"\(name)\" will be permanently deleted.")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func screenRow(_ meta: HMIScreenMeta) -> some View {
        if editingId == meta.id {
            // Inline rename text field
            TextField("Screen name", text: $editingName)
                .textFieldStyle(.plain)
                .font(.caption)
                .onSubmit { commitRename(id: meta.id) }
                .onKeyPress(.escape) {
                    editingId = nil
                    return .handled
                }
                .onAppear {
                    // Focus happens via SwiftUI focus engine automatically for TextField
                }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(meta.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if hmiScreenStore.currentScreenId == meta.id {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // Double-tap to rename
                editingId   = meta.id
                editingName = meta.name
            }
            .onTapGesture {
                hmiScreenStore.switchToScreen(id: meta.id)
            }
        }
    }

    // MARK: - Rename

    private func commitRename(id: UUID) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            hmiScreenStore.renameScreen(id: id, newName: trimmed)
        }
        editingId = nil
    }
}
