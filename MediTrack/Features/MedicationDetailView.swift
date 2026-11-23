import SwiftUI

@MainActor
struct MedicationDetailView: View {
    let model: MediTrackModel
    let medication: Medication
    var selected: DoseOccurrence?

    var body: some View {
        let detail = model.detail(for: medication)
        let medication = detail.medication
        List {
            Section("Prescription") {
                LabeledContent("Dosage", value: medication.dosage)
                LabeledContent("Schedule", value: medication.schedule.sorted().joined(separator: " · "))
                LabeledContent("Starts", value: medication.startDate)
                LabeledContent("Ends", value: medication.endDate ?? "Ongoing")

                if !medication.instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instructions").font(.subheadline).foregroundStyle(.secondary)
                        Text(medication.instructions)
                    }
                }
            }

            if let selected {
                Section("Selected dose") {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        let log = model.snapshot.logs[selected.id]
                        let status = DoseStatus(scheduledAt: selected.scheduledAt, now: context.date, decision: log?.decision)
                        LabeledContent {
                            DoseStatusBadge(status: status)
                        } label: {
                            Text(selected.scheduledAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                    }
                    if model.snapshot.logs[selected.id] == nil {
                        Button("Mark Taken", systemImage: "checkmark.circle") {
                            model.record(.taken, for: selected)
                        }
                        Button("Mark Skipped", systemImage: "forward.end") {
                            model.record(.skipped, for: selected)
                        }
                    }
                }
            }

            Section("Dose history") {
                if detail.history.isEmpty {
                    Text("No doses logged yet.").foregroundStyle(.secondary)
                }
                ForEach(detail.history) { log in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(log.occurrence.scheduledAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                            .font(.body.weight(.semibold))
                        DoseStatusBadge(status: log.decision == .taken ? .taken : .skipped)
                        Text("Logged \(log.loggedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        SyncBadge(state: log.syncState)
                        if log.syncState == .failed, let reason = log.failure {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle(medication.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
struct MedicationListView: View {
    let model: MediTrackModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.snapshot.medications.isEmpty {
                    ContentUnavailableView("No saved medications", systemImage: "cross.case")
                }
                ForEach(model.snapshot.medications) { medication in
                    NavigationLink {
                        MedicationDetailView(model: model, medication: medication)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(medication.name).font(.body.weight(.semibold))
                            Text(medication.dosage).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Medications")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
