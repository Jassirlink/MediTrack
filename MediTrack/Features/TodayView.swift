import SwiftUI
import UIKit

@MainActor
struct TodayView: View {
    @Bindable var model: MediTrackModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showsMedications = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let rows = model.doses(at: context.date)
                List {
                    overview(rows: rows, date: context.date)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))

                    Section("Scheduled doses") {
                        if rows.isEmpty {
                            ContentUnavailableView(
                                emptyTitle, systemImage: model.snapshot.medications.isEmpty ? "cross.case" : "calendar",
                                description: Text(emptyDescription)
                            )
                        }
                        ForEach(rows) { row in
                            NavigationLink {
                                MedicationDetailView(model: model, medication: row.medication, selected: row.occurrence)
                            } label: {
                                TodayDoseRow(row: row)
                            }
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if row.log == nil {
                                    Button("Taken", systemImage: "checkmark") {
                                        model.record(.taken, for: row.occurrence)
                                    }
                                    .tint(.teal)

                                    Button("Skipped", systemImage: "forward.end") {
                                        model.record(.skipped, for: row.occurrence)
                                    }
                                    .tint(.indigo)
                                }
                            }
                        }
                    }

                    if !model.reminderAuthorization.allowsReminders {
                        Section("Reminders") {
                            if model.reminderAuthorization == .denied {
                                Button("Open Notification Settings", systemImage: "bell.slash") {
                                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                                }
                            } else {
                                Button("Enable Reminders", systemImage: "bell") {
                                    Task { await model.enableReminders() }
                                }
                            }
                        }
                    }

                    if model.showsDemoControls {
                        Section("Demo controls") {
                            Toggle("Simulate Offline", isOn: Binding(
                                get: { model.demoOffline }, set: { model.setDemoOffline($0) }
                            ))
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Medications", systemImage: "cross.case") { showsMedications = true }
                        .labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $showsMedications) {
                MedicationListView(model: model)
            }
            .refreshable { await model.refresh() }
            .alert("MediTrack", isPresented: Binding(
                get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }
            )) {
                Button("OK", role: .cancel) { model.alert = nil }
            } message: {
                Text(model.alert ?? "")
            }
        }
        .tint(.teal)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.updateScene(active: phase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            model.significantTimeChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            model.significantTimeChanged()
        }
    }

    private var emptyTitle: String {
        if model.isRefreshing { return "Loading medications" }
        if model.snapshot.medications.isEmpty && !model.isOnline { return "No saved medications" }
        return "No doses scheduled"
    }

    private var emptyDescription: String {
        if model.isRefreshing { return "Checking the clinic’s medication list." }
        if !model.isOnline && model.snapshot.medications.isEmpty { return "Connect to the internet to load your medications." }
        return model.refreshError ?? "Scheduled doses for this date will appear here."
    }

    private func overview(rows: [DoseRow], date: Date) -> some View {
        let logged = rows.lazy.filter { $0.log != nil }.count
        return VStack(alignment: .leading, spacing: 13) {
            Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                Text("\(logged) of \(rows.count) doses logged")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if !rows.isEmpty {
                    ProgressView(value: Double(logged), total: Double(rows.count))
                        .accessibilityHidden(true)
                }
            }

            HStack(spacing: 7) {
                Image(systemName: model.isOnline ? "arrow.triangle.2.circlepath" : "wifi.slash")
                    .accessibilityHidden(true)
                Text(syncStatus)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let error = model.refreshError, !rows.isEmpty {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            if model.failedCount > 0 {
                Button("Retry failed logs", systemImage: "arrow.clockwise") { model.retryFailed() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    }

    private var syncStatus: String {
        var parts = [model.isOnline ? "Online" : "Offline"]
        if model.pendingCount > 0 { parts.append("\(model.pendingCount) waiting to sync") }
        if model.failedCount > 0 { parts.append("\(model.failedCount) failed") }
        if model.pendingCount == 0 && model.failedCount == 0 && model.isOnline && !model.snapshot.logs.isEmpty {
            parts.append("All logs synced")
        }
        return parts.joined(separator: " · ")
    }
}

private struct TodayDoseRow: View {
    let row: DoseRow
    @ScaledMetric(relativeTo: .subheadline) private var timeColumnWidth = 72.0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                doseTime
                    .frame(width: timeColumnWidth, alignment: .leading)
                doseLabel
                Spacer(minLength: 4)
                badges
            }
            VStack(alignment: .leading, spacing: 6) {
                doseTime
                doseLabel
                badges
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var doseTime: some View {
        Text(row.occurrence.scheduledAt, format: .dateTime.hour().minute())
            .font(.subheadline.weight(.semibold).monospacedDigit())
    }

    private var doseLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.medication.name).font(.body.weight(.semibold))
            Text(row.medication.dosage).font(.subheadline).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var badges: some View {
        VStack(alignment: .leading, spacing: 4) {
            DoseStatusBadge(status: row.status)
            if let log = row.log, log.syncState != .synced {
                SyncBadge(state: log.syncState)
            }
        }
        .fixedSize()
    }
}

struct DoseStatusBadge: View {
    let status: DoseStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(status.rawValue)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.18), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .upcoming: .blue
        case .due: .orange
        case .taken: .teal
        case .skipped: .indigo
        case .missed: .red
        }
    }

    private var icon: String {
        switch status {
        case .upcoming: "clock"
        case .due: "bell"
        case .taken: "checkmark"
        case .skipped: "forward.end"
        case .missed: "exclamationmark"
        }
    }
}

struct SyncBadge: View {
    let state: SyncState

    var body: some View {
        let label: String = switch state {
        case .pending: "Pending sync"
        case .synced: "Synced"
        case .failed: "Sync failed"
        }
        let icon: String = switch state {
        case .pending: "clock.arrow.circlepath"
        case .synced: "checkmark.icloud"
        case .failed: "exclamationmark.icloud"
        }
        HStack(spacing: 5) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
