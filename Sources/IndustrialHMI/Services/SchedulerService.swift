// MARK: - SchedulerService.swift
//
// Persistent time-based job engine that fires automated HMI actions on schedule.
//
// ── Evaluation Loop ───────────────────────────────────────────────────────────
//   A long-running Task wakes every 30 seconds and calls evaluateJobs().
//   Each call compares the current time against every enabled job's trigger:
//     .daily    — fires if current HH:MM matches dailyHour:dailyMinute
//     .interval — fires if now ≥ lastRunAt + intervalMinutes (or never run)
//     .once     — fires if now ≥ onceDate; auto-disables job after firing
//   To prevent double-firing within the same 30 s window, each trigger type
//   checks lastRunAt: if lastRunAt is within the last 60 seconds, skip.
//
// ── Actions ───────────────────────────────────────────────────────────────────
//   .activateRecipe — calls recipeStore.activateRecipe() for recipeId
//   .writeTag       — calls opcuaService.writeValue(nodeId:value:) or
//                     tagEngine.resolveWrite() (same routing logic as RecipeStore)
//
// ── Execution Audit ───────────────────────────────────────────────────────────
//   After each fire:
//     1. ScheduleExecution entry created (id, jobId, jobName, executedAt, result)
//     2. Prepended to recentExecutions (capped at 50, newest first)
//     3. job.lastRunAt and job.lastResult updated and persisted to DB
//   SchedulerView's "Recent Runs" list is driven by recentExecutions.
//
// ── Persistence ───────────────────────────────────────────────────────────────
//   Jobs stored in Historian SQLite `scheduled_jobs` table.
//   loadFromDB() loads jobs sorted by createdAt + last 50 executions on startup.
//   CRUD operations fire-and-forget Tasks to persist immediately.
//
// ── Integration ───────────────────────────────────────────────────────────────
//   DataService creates SchedulerService, injects historian and recipeStore.
//   DataService.startDataCollection() calls schedulerService.start().
//   DataService.stopDataCollection() calls schedulerService.stop().

import Foundation

// MARK: - SchedulerService

/// Persistent cron-style job engine.
/// Evaluates enabled jobs every 30 seconds and fires actions when their trigger
/// time is reached. Jobs and execution history are stored in the Historian SQLite DB.
@MainActor
class SchedulerService: ObservableObject {

    // MARK: - Published

    @Published var jobs:             [ScheduledJob]      = []
    @Published var recentExecutions: [ScheduleExecution] = []   // newest first, capped at 50

    // MARK: - Dependencies (injected by DataService)

    var historian:   Historian?
    weak var recipeStore: RecipeStore?

    private let tagEngine:    TagEngine
    private let opcuaService: OPCUAClientService

    // MARK: - Private

    private var evaluationTask: Task<Void, Never>?

    // MARK: - Init

    init(tagEngine: TagEngine, opcuaService: OPCUAClientService) {
        self.tagEngine    = tagEngine
        self.opcuaService = opcuaService
    }

    // MARK: - Lifecycle

    func start() {
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            // Brief initial delay so the app fully loads before the first eval.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await self?.evaluateJobs()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        Logger.shared.info("SchedulerService: started (30 s evaluation interval)")
    }

    func stop() {
        evaluationTask?.cancel()
        evaluationTask = nil
        Logger.shared.info("SchedulerService: stopped")
    }

    // MARK: - Load from DB

    func loadFromDB() async {
        guard let h = historian else { return }
        do {
            jobs             = (try await h.loadScheduledJobs()).sorted { $0.createdAt < $1.createdAt }
            recentExecutions = try await h.loadScheduleExecutions(limit: 50)
            Logger.shared.info("SchedulerService: loaded \(jobs.count) jobs, " +
                               "\(recentExecutions.count) recent executions")
        } catch {
            Logger.shared.error("SchedulerService: loadFromDB failed — \(error)")
        }
    }

    // MARK: - CRUD

    func addJob(_ job: ScheduledJob) {
        jobs.append(job)
        persist(job)
        Logger.shared.info("SchedulerService: added job '\(job.name)'")
    }

    func updateJob(_ job: ScheduledJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[idx] = job
        persist(job)
    }

    func deleteJob(id: UUID) {
        jobs.removeAll { $0.id == id }
        guard let h = historian else { return }
        Task { try? await h.deleteScheduledJob(id: id) }
    }

    private func persist(_ job: ScheduledJob) {
        guard let h = historian else { return }
        Task { try? await h.saveScheduledJob(job) }
    }

    // MARK: - Manual trigger

    /// Fires a job immediately regardless of its schedule (for "Run Now" testing).
    func runJobNow(id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        Task { await fireJob(at: idx) }
    }

    // MARK: - Evaluation

    private func evaluateJobs() async {
        let now = Date()
        for idx in jobs.indices {
            let job = jobs[idx]
            guard job.isEnabled else { continue }
            if let next = nextTriggerDate(for: job), next <= now {
                await fireJob(at: idx)
            }
        }
    }

    // MARK: - Next Trigger Date

    func nextTriggerDate(for job: ScheduledJob) -> Date? {
        let now = Date()
        let cal = Calendar.current

        switch job.triggerType {
        case .daily:
            // Build today at HH:MM
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour   = job.dailyHour
            comps.minute = job.dailyMinute
            comps.second = 0
            guard let todayTarget = cal.date(from: comps) else { return nil }
            // If already fired today, return tomorrow
            if let last = job.lastRunAt, cal.isDate(last, inSameDayAs: now) {
                return cal.date(byAdding: .day, value: 1, to: todayTarget)
            }
            return todayTarget

        case .interval:
            guard job.intervalMinutes > 0 else { return nil }
            let base = job.lastRunAt ?? job.createdAt
            return base.addingTimeInterval(Double(job.intervalMinutes) * 60)

        case .once:
            // Already fired?
            if let last = job.lastRunAt, last >= job.onceDate { return nil }
            return job.onceDate
        }
    }

    // MARK: - Fire Job

    private func fireJob(at idx: Int) async {
        var job = jobs[idx]
        Logger.shared.info("SchedulerService: firing job '\(job.name)'")

        var result = "success"

        do {
            switch job.actionType {
            case .activateRecipe:
                try await fireRecipeAction(&job)
            case .writeTag:
                try await fireWriteTagAction(&job)
            }
        } catch {
            result = "failed: \(error.localizedDescription)"
            Logger.shared.error("SchedulerService: job '\(job.name)' failed — \(error.localizedDescription)")
        }

        // Update job metadata
        job.lastRunAt  = Date()
        job.lastResult = result
        if job.triggerType == .once {
            job.isEnabled = false   // one-shot: auto-disable after firing
        }
        jobs[idx] = job
        persist(job)

        // Append to execution log
        let exec = ScheduleExecution(id: UUID(), jobId: job.id, jobName: job.name,
                                     executedAt: job.lastRunAt!, result: result)
        recentExecutions.insert(exec, at: 0)
        if recentExecutions.count > 50 { recentExecutions = Array(recentExecutions.prefix(50)) }

        if let h = historian {
            Task { try? await h.logScheduleExecution(jobId: job.id, jobName: job.name, result: result) }
        }
    }

    // MARK: - Action Handlers

    private func fireRecipeAction(_ job: inout ScheduledJob) async throws {
        guard let recipeId = job.recipeId,
              let store    = recipeStore,
              let recipe   = store.recipes.first(where: { $0.id == recipeId })
        else {
            throw SchedulerError.recipeNotFound
        }
        let activationResult = await store.activateRecipe(recipe, by: "Scheduler")
        if activationResult.failureCount > 0 {
            throw SchedulerError.recipePartialFailure(
                failed: activationResult.failureCount,
                total: activationResult.successCount + activationResult.failureCount
            )
        }
        Logger.shared.info("SchedulerService: activated recipe '\(recipe.name)'")
    }

    private func fireWriteTagAction(_ job: inout ScheduledJob) async throws {
        guard !job.tagName.isEmpty else { throw SchedulerError.tagNameEmpty }

        // Programmatic write: update TagEngine in-memory directly (no confirmation dialog).
        tagEngine.updateTag(name: job.tagName, value: .analog(job.writeValue))

        // If a node ID is configured, also push to OPC-UA.
        if !job.nodeId.isEmpty {
            try await opcuaService.writeTag(nodeId: job.nodeId, value: .analog(job.writeValue))
        }
        Logger.shared.info("SchedulerService: wrote \(job.writeValue) to '\(job.tagName)'")
    }
}

// MARK: - SchedulerError

enum SchedulerError: LocalizedError {
    case recipeNotFound
    case recipePartialFailure(failed: Int, total: Int)
    case tagNameEmpty

    var errorDescription: String? {
        switch self {
        case .recipeNotFound:
            return "Recipe not found"
        case .recipePartialFailure(let f, let t):
            return "Recipe activation partially failed (\(f)/\(t) setpoints)"
        case .tagNameEmpty:
            return "Tag name is empty"
        }
    }
}
