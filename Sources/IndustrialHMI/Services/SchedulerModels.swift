import Foundation

// MARK: - SchedulerModels.swift
//
// Data models for the time-based job scheduler feature.
//
// ── What is the Scheduler? ────────────────────────────────────────────────────
//   The Scheduler allows operators/engineers to configure automated jobs that
//   run at specific times without operator intervention. Typical uses:
//     • Nightly recipe activation to configure a new production grade
//     • Hourly setpoint reset to maintain process within limits
//     • One-time startup sequence at a known datetime
//
// ── Trigger types ─────────────────────────────────────────────────────────────
//   .daily    — fires every day at dailyHour:dailyMinute (UTC-local)
//   .interval — fires every intervalMinutes starting from first fire
//   .once     — fires once at onceDate; auto-disables isEnabled after firing
//
// ── Action types ──────────────────────────────────────────────────────────────
//   .activateRecipe — runs the recipe with recipeId via RecipeStore.activate()
//   .writeTag       — writes writeValue to tagName/nodeId via OPCUAClientService
//
// ── Execution audit ───────────────────────────────────────────────────────────
//   ScheduleExecution is an in-memory log entry created by SchedulerService
//   after each job fires.  Shown in SchedulerView's "Recent Runs" list.
//   ScheduledJob.lastRunAt and lastResult are also updated on each fire
//   and persisted to the ConfigDatabase SQLite jobs table.

// MARK: - TriggerType

enum TriggerType: String, Codable, CaseIterable {
    case daily    = "daily"      // fires every day at a fixed HH:MM
    case interval = "interval"   // fires every N minutes
    case once     = "once"       // one-shot datetime; auto-disables after firing
}

// MARK: - ScheduledActionType

enum ScheduledActionType: String, Codable, CaseIterable {
    case activateRecipe = "activateRecipe"
    case writeTag       = "writeTag"
}

// MARK: - ScheduledJob

struct ScheduledJob: Identifiable, Codable, Equatable {
    var id:              UUID    = UUID()
    var name:            String  = "New Job"
    var isEnabled:       Bool    = true

    // ── Trigger ──────────────────────────────────────────────────────────────
    var triggerType:     TriggerType = .daily
    var dailyHour:       Int     = 8     // 0–23 (daily trigger)
    var dailyMinute:     Int     = 0     // 0–59 (daily trigger)
    var intervalMinutes: Int     = 60    // positive integer (interval trigger)
    var onceDate:        Date    = Date() // specific datetime (once trigger)

    // ── Action ───────────────────────────────────────────────────────────────
    var actionType:      ScheduledActionType = .activateRecipe
    var recipeId:        UUID?              // activateRecipe action
    var tagName:         String  = ""       // writeTag action
    var nodeId:          String  = ""       // writeTag action — OPC-UA node ID
    var writeValue:      Double  = 0.0      // writeTag action

    // ── Metadata (updated after each fire) ───────────────────────────────────
    var createdAt:       Date    = Date()
    var lastRunAt:       Date?   = nil
    var lastResult:      String? = nil   // "success" or "failed: <reason>"
}

// MARK: - ScheduleExecution

/// One entry in the execution audit log.
struct ScheduleExecution: Identifiable {
    var id:          UUID
    var jobId:       UUID
    var jobName:     String
    var executedAt:  Date
    var result:      String     // "success" or "failed: <reason>"

    var succeeded: Bool { result == "success" }
}
