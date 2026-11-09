import AppKit
import MacRestCore
import SwiftUI

struct ScheduleView: View {
    @Bindable var model: AppModel

    enum RetentionKind: String, CaseIterable, Identifiable {
        case buckets = "By age", lastN = "The latest backups", all = "Everything"
        var id: String { rawValue }
    }

    var body: some View {
        if let plan = Binding($model.plan) {
            Form {
                SwiftUI.Section {
                    ScheduleEditor(title: "Back up", schedule: plan.schedule)
                    Toggle("Skip the backup when nothing changed", isOn: plan.skipIfUnchanged)
                } header: {
                    Text("Backups")
                } footer: {
                    Text("An interval counts from the last run, so a Mac that was asleep backs up soon after it wakes.")
                }
                SwiftUI.Section {
                    Picker("Keep", selection: retentionKind(plan)) {
                        ForEach(RetentionKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if case let .buckets(b) = plan.wrappedValue.retention, !b.coverage.isEmpty {
                        CoverageBar(segments: b.coverage)
                    }
                    retentionFields(plan)
                } header: {
                    HStack {
                        Text("Backups to keep")
                        Spacer()
                        Button("Time Machine style") {
                            plan.wrappedValue.retention = .buckets(TimeBuckets(hourly: 24, daily: 30, weekly: 52, monthly: 24))
                        }
                        .controlSize(.small)
                        .help("Hourly for a day, daily for a month, weekly for a year, monthly for two years")
                    }
                } footer: {
                    Text(plan.wrappedValue.retention.summary + ". Older backups are removed after each backup; their space is recovered on the space recovery schedule (Storage).")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func retentionKind(_ plan: Binding<PlanSettings>) -> Binding<RetentionKind> {
        Binding {
            switch plan.wrappedValue.retention {
            case .buckets: .buckets
            case .lastN: .lastN
            case .keepAll: .all
            }
        } set: { kind in
            switch kind {
            case .buckets: plan.wrappedValue.retention = .buckets(TimeBuckets(daily: 7, weekly: 4, monthly: 3))
            case .lastN: plan.wrappedValue.retention = .lastN(30)
            case .all: plan.wrappedValue.retention = .keepAll
            }
        }
    }

    @ViewBuilder private func retentionFields(_ plan: Binding<PlanSettings>) -> some View {
        switch plan.wrappedValue.retention {
        case let .buckets(b):
            let set = { (b: TimeBuckets) in plan.wrappedValue.retention = .buckets(b) }
            CountStepper(label: "Hourly", unit: "hour", value: b.hourly) { var c = b; c.hourly = $0; set(c) }
            CountStepper(label: "Daily", unit: "day", value: b.daily) { var c = b; c.daily = $0; set(c) }
            CountStepper(label: "Weekly", unit: "week", value: b.weekly) { var c = b; c.weekly = $0; set(c) }
            CountStepper(label: "Monthly", unit: "month", value: b.monthly) { var c = b; c.monthly = $0; set(c) }
            CountStepper(label: "Yearly", unit: "year", value: b.yearly) { var c = b; c.yearly = $0; set(c) }
            CountStepper(label: "Always keep the latest", unit: "backup", value: b.keepLastN) { var c = b; c.keepLastN = $0; set(c) }
        case let .lastN(n):
            CountStepper(label: "Backups", unit: "backup", value: n, range: 1...10_000) {
                plan.wrappedValue.retention = .lastN($0)
            }
        case .keepAll:
            Text("Nothing is ever deleted. The storage only grows.").foregroundStyle(.secondary)
        }
    }
}

/// A labelled number with its stepper beside the value, the way System
/// Settings lays them out.
struct ValueStepper: View {
    let label: String
    let value: Int
    let text: String
    let range: ClosedRange<Int>
    var step = 1
    let set: (Int) -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(text).monospacedDigit()
                Stepper(label, value: Binding(get: { value }, set: { set($0) }), in: range, step: step)
                    .labelsHidden()
            }
        }
    }
}

struct CountStepper: View {
    let label: String
    let unit: String
    let value: Int
    var range: ClosedRange<Int> = 0...1000
    let set: (Int) -> Void

    var body: some View {
        ValueStepper(label: label, value: value, text: value == 0 ? "None" : Format.plural(value, unit), range: range, set: set)
    }
}
