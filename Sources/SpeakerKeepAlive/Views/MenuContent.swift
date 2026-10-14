import KeepAliveCore
import SwiftUI

struct MenuContent: View {
    @Bindable var coordinator: Coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(coordinator.statusTitle)
        if let detail = coordinator.statusDetail {
            Text(detail)
        }

        Divider()

        Picker("Speaker Profile", selection: $coordinator.settings.profileID) {
            ForEach(coordinator.profiles.all) { profile in
                Text(profile.name).tag(profile.id)
            }
        }
        Picker("Schedule", selection: $coordinator.settings.schedule.mode) {
            Text("Always On").tag(ScheduleMode.always)
            Text("Scheduled").tag(ScheduleMode.scheduled)
            Text("Off").tag(ScheduleMode.off)
        }

        Divider()

        if coordinator.override != nil {
            Button("Resume Schedule") { coordinator.clearOverride() }
        }
        Button("Keep Speakers Awake for 1 Hour") { coordinator.keepAwake(for: 3600) }
        Button("Keep Speakers Awake Until Midnight") { coordinator.keepAwakeUntilMidnight() }
        Button("Pause for 1 Hour") { coordinator.pause(for: 3600) }

        Divider()

        Button("Play Test Tone") { coordinator.playTestBurst() }
            .disabled(coordinator.targetDevice == nil)
        Button("Settings…") {
            openWindow(id: SettingsView.windowID)
            NSApp.activate()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Speaker Keep-Alive") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension Coordinator {
    var statusTitle: String {
        switch status {
        case .active: "Keeping \(activeProfile.name) awake"
        case .outsideSchedule: "Outside scheduled hours"
        case .off: "Off"
        case .paused: "Paused"
        case .asleep: "Mac asleep, speakers can sleep too"
        case .deviceMissing(let name): "Waiting for \(name)"
        case .error(let message): "Problem: \(message)"
        }
    }

    var statusDetail: String? {
        var parts: [String] = []
        if case .active = status, let nextBurst {
            parts.append("Next tone at \(nextBurst.formatted(date: .omitted, time: .shortened))")
        }
        if let changesAt {
            let verb = shouldBeActive ? "Stops" : "Starts"
            parts.append("\(verb) \(changesAt.relativeDayAndTime)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Date {
    /// "at 18:00", "tomorrow at 08:00" or "Mon at 08:00".
    var relativeDayAndTime: String {
        let calendar = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(self) { return "at \(time)" }
        if calendar.isDateInTomorrow(self) { return "tomorrow at \(time)" }
        return "\(formatted(.dateTime.weekday(.abbreviated))) at \(time)"
    }
}
