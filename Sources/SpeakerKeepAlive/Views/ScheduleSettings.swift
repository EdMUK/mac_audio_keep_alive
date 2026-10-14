import KeepAliveCore
import SwiftUI

struct ScheduleSettings: View {
    @Bindable var coordinator: Coordinator

    var body: some View {
        Form {
            Section {
                Picker("Keep speakers awake", selection: $coordinator.settings.schedule.mode) {
                    Text("Always").tag(ScheduleMode.always)
                    Text("On a schedule").tag(ScheduleMode.scheduled)
                    Text("Off").tag(ScheduleMode.off)
                }
                .pickerStyle(.segmented)
                Text("While active, macOS won't idle-sleep the Mac if the profile keeps the stream open. A schedule lets both the speakers and the Mac sleep overnight.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if coordinator.settings.schedule.mode == .scheduled {
                Section("Active hours") {
                    ForEach($coordinator.settings.schedule.rules) { $rule in
                        RuleRow(rule: $rule) {
                            coordinator.settings.schedule.rules.removeAll { $0.id == rule.id }
                        }
                    }
                    Button("Add Time Window", systemImage: "plus") {
                        coordinator.settings.schedule.rules.append(
                            ScheduleRule(weekdays: ScheduleRule.weekdaysOnly, startMinute: 9 * 60, endMinute: 17 * 60)
                        )
                    }
                }
                if coordinator.settings.schedule.rules.isEmpty {
                    Text("Add a time window, or the speakers won't be kept awake at all.")
                        .foregroundStyle(.secondary)
                } else if let next = coordinator.settings.schedule.nextTransition(after: .now) {
                    let verb = coordinator.settings.schedule.isActive(at: .now) ? "Stops" : "Starts"
                    Text("\(verb) \(next.relativeDayAndTime). A window that ends earlier than it starts runs past midnight; equal times mean all day.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RuleRow: View {
    @Binding var rule: ScheduleRule
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Self.orderedWeekdays, id: \.self) { weekday in
                    Toggle(Self.symbol(for: weekday), isOn: Binding(
                        get: { rule.weekdays.contains(weekday) },
                        set: { on in
                            if on { rule.weekdays.insert(weekday) } else { rule.weekdays.remove(weekday) }
                        }
                    ))
                    .toggleStyle(.button)
                    .help(Calendar.current.weekdaySymbols[weekday - 1])
                }
            }
            Spacer()
            DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                .labelsHidden()
            Text("to")
            DatePicker("To", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                .labelsHidden()
            Button("Remove", systemImage: "minus.circle", action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<ScheduleRule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minute = rule[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                rule[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    /// Weekday numbers in the user's locale order (e.g. Monday first in the UK).
    private static var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private static func symbol(for weekday: Int) -> String {
        Calendar.current.veryShortWeekdaySymbols[weekday - 1]
    }
}
