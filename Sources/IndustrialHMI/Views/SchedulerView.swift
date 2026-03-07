// MARK: - SchedulerView.swift
//
// UI for configuring and monitoring the time-based job scheduler.
// Engineers use this view to set up automated HMI actions (recipe activation,
// tag writes) that fire on a schedule without operator intervention.
//
// ── Layout (HSplitView) ───────────────────────────────────────────────────────
//   Left  — jobListPane (260–400 pt): scrollable list of all ScheduledJobs.
//           Each row shows: job name, trigger summary (e.g. "Daily 08:00"),
//           action type, enabled/disabled toggle, last run time + result icon.
//           Context menu: Edit, Enable/Disable, Delete.
//   Right — executionLogPane: "Recent Runs" list (up to 50 entries) showing
//           each ScheduleExecution: jobName, executedAt, result (✓ / ✗ + reason).
//
// ── Add/Edit Job Sheet ────────────────────────────────────────────────────────
//   AddEditJobSheet(editingJob:) — nil = add mode, non-nil = edit mode.
//   Fields: job name, enabled toggle, trigger type picker + trigger parameters,
//           action type picker + action parameters (recipeId or tagName/nodeId/value).
//   Saved via schedulerService.addJob() or schedulerService.updateJob().
//
// ── Trigger Summaries ─────────────────────────────────────────────────────────
//   .daily:    "Daily at HH:MM"
//   .interval: "Every N min"
//   .once:     "Once at <date>"
//   Formatted in jobListPane row subtitle.
//
// ── Delete Confirmation ───────────────────────────────────────────────────────
//   jobToDelete + showDeleteAlert: .alert("Delete Job") with destructive confirm.
//   Calls schedulerService.deleteJob(id:) on confirm.
//
// ── Recent Executions ─────────────────────────────────────────────────────────
//   schedulerService.recentExecutions (newest first, capped at 50).
//   ✓ green circle = success, ✗ red circle = failure with reason string.
//   Selecting a job in the left pane filters executions to that job's UUID.

import SwiftUI

// MARK: - SchedulerView

struct SchedulerView: View {
    @EnvironmentObject var schedulerService: SchedulerService
    @EnvironmentObject var recipeStore:      RecipeStore

    @State private var selectedJobID:  UUID?
    @State private var showAddSheet:   Bool = false
    @State private var editingJob:     ScheduledJob?
    @State private var jobToDelete:    ScheduledJob?
    @State private var showDeleteAlert = false

    var body: some View {
        HSplitView {
            // ─── Left: Job List ───────────────────────────────────────
            jobListPane
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)

            // ─── Right: Execution Log ─────────────────────────────────
            executionLogPane
                .frame(minWidth: 300, maxWidth: .infinity)
        }
        .navigationTitle("Scheduler")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingJob = nil
                    showAddSheet = true
                } label: {
                    Label("Add Job", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddEditJobSheet(editingJob: nil)
                .environmentObject(schedulerService)
                .environmentObject(recipeStore)
        }
        .sheet(item: $editingJob) { job in
            AddEditJobSheet(editingJob: job)
                .environmentObject(schedulerService)
                .environmentObject(recipeStore)
        }
        .alert("Delete Job", isPresented: $showDeleteAlert, presenting: jobToDelete) { job in
            Button("Delete", role: .destructive) {
                schedulerService.deleteJob(id: job.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { job in
            Text("Delete \"\(job.name)\"? This cannot be undone.")
        }
    }

    // MARK: - Job List Pane

    private var jobListPane: some View {
        List(schedulerService.jobs, selection: $selectedJobID) { job in
            jobRow(job)
                .tag(job.id)
                .contextMenu {
                    Button("Edit") { editingJob = job }
                    Button("Run Now") { schedulerService.runJobNow(id: job.id) }
                    Divider()
                    Button(job.isEnabled ? "Disable" : "Enable") {
                        var updated = job
                        updated.isEnabled = !job.isEnabled
                        schedulerService.updateJob(updated)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        jobToDelete = job
                        showDeleteAlert = true
                    }
                }
        }
        .listStyle(.sidebar)
        .overlay {
            if schedulerService.jobs.isEmpty {
                ContentUnavailableView(
                    "No Jobs",
                    systemImage: "calendar.badge.clock",
                    description: Text("Tap + to create a scheduled job.")
                )
            }
        }
    }

    @ViewBuilder
    private func jobRow(_ job: ScheduledJob) -> some View {
        HStack(spacing: 8) {
            // Status dot
            Circle()
                .fill(job.isEnabled ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(triggerSummary(job))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if job.isEnabled, let next = schedulerService.nextTriggerDate(for: job) {
                    Text("Next: \(relativeFormatter.localizedString(for: next, relativeTo: Date()))")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                } else if !job.isEnabled {
                    Text("Disabled")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Last result badge
            if let result = job.lastResult {
                Image(systemName: result == "success" ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(result == "success" ? .green : .red)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Execution Log Pane

    private var executionLogPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Execution Log")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                Spacer()
                Text("\(schedulerService.recentExecutions.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.trailing)
                    .padding(.top, 12)
            }
            Divider()

            if schedulerService.recentExecutions.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No Executions",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Execution history will appear here once jobs have run.")
                )
                Spacer()
            } else {
                List(schedulerService.recentExecutions) { exec in
                    executionRow(exec)
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func executionRow(_ exec: ScheduleExecution) -> some View {
        HStack(spacing: 10) {
            Image(systemName: exec.result == "success" ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(exec.result == "success" ? .green : .red)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(exec.jobName)
                    .font(.body)
                    .lineLimit(1)
                if exec.result != "success" {
                    Text(exec.result)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(exec.executedAt, style: .relative)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func triggerSummary(_ job: ScheduledJob) -> String {
        switch job.triggerType {
        case .daily:
            return String(format: "Daily %02d:%02d", job.dailyHour, job.dailyMinute)
        case .interval:
            return "Every \(job.intervalMinutes) min"
        case .once:
            return "Once · \(shortDateFormatter.string(from: job.onceDate))"
        }
    }
}

// MARK: - Formatters

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

private let shortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    return f
}()
