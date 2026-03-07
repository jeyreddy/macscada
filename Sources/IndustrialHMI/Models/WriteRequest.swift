import Foundation

// MARK: - WriteRequest.swift
//
// Data model for the two-phase tag write pattern.
//
// ── Write flow ────────────────────────────────────────────────────────────────
//   1. Operator enters a new value in WriteValueSheet or the AI agent proposes a write.
//   2. A WriteRequest is created and stored in TagEngine.pendingWrites.
//   3. WriteValueSheet (or agent tool confirm_write) displays the request for confirmation.
//   4. On confirm: DataService.confirmWrite(_:) executes the OPC-UA write,
//      calls TagEngine.resolveWrite(_:success:), and logs to the Historian audit trail.
//   5. On cancel: TagEngine.cancelWrite(_:) removes the request without writing.
//
// ── Fields ────────────────────────────────────────────────────────────────────
//   tagName     — human-readable name for display and audit logging
//   nodeId      — OPC-UA node ID for the actual write call
//   currentValue — snapshot of the value at request creation (shown in confirm dialog)
//   newValue    — the value the operator wants to write
//   requestedBy — operator username (stamped from SessionManager.currentOperator)

/// Represents an operator-initiated request to write a new value to a tag.
/// Created when the operator submits a value; not executed until confirmation.
struct WriteRequest: Identifiable {
    let id: UUID
    let tagName: String
    let nodeId: String
    let currentValue: TagValue   // value at the time the request was created
    let newValue: TagValue
    let requestedBy: String
    let requestedAt: Date

    init(
        id: UUID = UUID(),
        tagName: String,
        nodeId: String,
        currentValue: TagValue,
        newValue: TagValue,
        requestedBy: String = "Operator",
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.tagName = tagName
        self.nodeId = nodeId
        self.currentValue = currentValue
        self.newValue = newValue
        self.requestedBy = requestedBy
        self.requestedAt = requestedAt
    }
}
