import ServiceManagement
import SwiftUI

struct SettingsView: View {
    static let windowID = "settings"

    @Bindable var coordinator: Coordinator

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(coordinator: coordinator)
            }
            Tab("Profiles", systemImage: "hifispeaker.2") {
                ProfilesSettings(coordinator: coordinator)
            }
            Tab("Schedule", systemImage: "clock") {
                ScheduleSettings(coordinator: coordinator)
            }
        }
        .frame(width: 720, height: 520)
    }
}

struct GeneralSettings: View {
    @Bindable var coordinator: Coordinator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Output device", selection: deviceSelection) {
                    Text("System default output").tag(String?.none)
                    ForEach(coordinator.devices.outputs) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    if let uid = coordinator.settings.deviceUID, coordinator.devices.device(uid: uid) == nil {
                        Text("\(coordinator.settings.deviceName ?? uid) (not connected)").tag(Optional(uid))
                    }
                }
                Text("The tone always goes to this device, even if you change the default output. Pick the output your speakers are connected to, such as a USB optical adapter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status", value: coordinator.statusTitle)
                if let detail = coordinator.statusDetail {
                    LabeledContent("", value: detail)
                }
                LabeledContent("Profile", value: coordinator.activeProfile.name)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemMessage {
                    Text(loginItemMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var deviceSelection: Binding<String?> {
        Binding(
            get: { coordinator.settings.deviceUID },
            set: { uid in
                if let uid, let device = coordinator.devices.device(uid: uid) {
                    coordinator.selectDevice(device)
                } else if uid == nil {
                    coordinator.selectDevice(nil)
                }
            }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Allow Speaker Keep-Alive in System Settings › General › Login Items."
                : nil
        } catch {
            loginItemMessage = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
