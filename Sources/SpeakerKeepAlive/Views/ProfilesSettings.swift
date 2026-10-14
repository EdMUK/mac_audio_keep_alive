import AppKit
import KeepAliveCore
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesSettings: View {
    @Bindable var coordinator: Coordinator
    @State private var selection: String?
    @State private var showingPaste = false
    @State private var alert: AlertMessage?

    private var store: ProfileStore { coordinator.profiles }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Built-in") {
                        ForEach(store.builtIn) { row($0) }
                    }
                    Section("Your Profiles") {
                        if store.custom.isEmpty {
                            Text("Duplicate a built-in profile to make your own.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(store.custom) { row($0) }
                    }
                }
                Divider()
                listToolbar
            }
            .frame(width: 240)

            Divider()

            if let id = selection, let profile = store.profile(id: id) {
                ProfileEditor(
                    coordinator: coordinator,
                    profile: profile,
                    isBuiltIn: store.isBuiltIn(id),
                    onError: { alert = AlertMessage($0) }
                )
                .id(id)
            } else {
                ContentUnavailableView("No Profile Selected", systemImage: "hifispeaker", description: Text("Choose a profile to see its settings."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? coordinator.activeProfile.id }
        .sheet(isPresented: $showingPaste) {
            PasteProfileSheet { data in
                importProfile(data)
            }
        }
        .alert(item: $alert) { message in
            Alert(title: Text(message.title), message: Text(message.detail))
        }
    }

    private func row(_ profile: SpeakerProfile) -> some View {
        HStack {
            Text(profile.name)
            Spacer()
            if profile.id == coordinator.settings.profileID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Active profile")
            }
        }
        .tag(profile.id)
    }

    private var listToolbar: some View {
        HStack(spacing: 4) {
            Menu {
                Button("New Profile") { perform { try store.makeNew() } }
                Button("Import File…") { importFile() }
                Button("Paste JSON…") { showingPaste = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a profile")

            Button("Duplicate", systemImage: "plus.square.on.square") {
                if let profile = selectedProfile {
                    perform { try store.duplicate(profile) }
                }
            }
            .disabled(selectedProfile == nil)

            Button("Delete", systemImage: "minus") {
                guard let id = selection else { return }
                do {
                    try store.delete(id: id)
                    selection = coordinator.activeProfile.id
                } catch {
                    alert = AlertMessage(error)
                }
            }
            .disabled(selection.map(store.isBuiltIn) ?? true)

            Spacer()

            Button("Show Folder", systemImage: "folder") {
                NSWorkspace.shared.open(store.userLibrary.directory)
            }
            .help("Open the folder where your profiles are saved")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var selectedProfile: SpeakerProfile? {
        selection.flatMap(store.profile(id:))
    }

    private func perform(_ action: () throws -> SpeakerProfile) {
        do {
            selection = try action().id
        } catch {
            alert = AlertMessage(error)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importProfile(try Data(contentsOf: url))
        } catch {
            alert = AlertMessage(error)
        }
    }

    private func importProfile(_ data: Data) {
        perform { try store.importProfile(from: data) }
    }
}

// MARK: - Editor

private struct ProfileEditor: View {
    @Bindable var coordinator: Coordinator
    let profile: SpeakerProfile
    let isBuiltIn: Bool
    var onError: (any Error) -> Void

    @State private var draft: SpeakerProfile
    @State private var copied = false

    init(coordinator: Coordinator, profile: SpeakerProfile, isBuiltIn: Bool, onError: @escaping (any Error) -> Void) {
        self.coordinator = coordinator
        self.profile = profile
        self.isBuiltIn = isBuiltIn
        self.onError = onError
        _draft = State(initialValue: profile)
    }

    private var isDirty: Bool { draft != profile }
    private var problems: [String] { draft.validationProblems }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isBuiltIn {
                    Section {
                        Label("Built-in profiles can't be edited. Duplicate this one to make a copy you can change.", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Speaker") {
                    TextField("Name", text: $draft.name)
                    TextField("Manufacturer", text: $draft.manufacturer)
                    TextField("Model", text: $draft.model)
                    Picker("Connection", selection: $draft.connection) {
                        ForEach(SpeakerConnection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    numberField("Standby timeout (min)", $draft.standbyTimeoutMinutes)
                }

                Section("Keep-alive tone") {
                    numberField("Frequency (Hz)", $draft.tone.frequencyHz)
                    numberField("Level (dBFS)", $draft.tone.levelDBFS)
                    numberField("Burst length (s)", $draft.tone.burstSeconds)
                    numberField("Every (s)", $draft.tone.intervalSeconds)
                    numberField("Fade (ms)", $draft.tone.fadeMilliseconds)
                    Toggle("Keep stream open between bursts", isOn: $draft.keepStreamOpen)
                        .help("Keeps digital links locked so audio doesn't start clipped, but stops the Mac idle-sleeping while active.")
                }

                Section("About") {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Source (manual URL)", text: Binding(
                        get: { draft.sourceURL ?? "" },
                        set: { draft.sourceURL = $0.isEmpty ? nil : $0 }
                    ))
                    Toggle("Tested: keeps the speaker awake", isOn: $draft.tested)
                    LabeledContent("ID", value: draft.id)
                }

                if !problems.isEmpty && !isBuiltIn {
                    Section {
                        ForEach(problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isBuiltIn)

            Divider()
            actionBar
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Use This Profile") { coordinator.settings.profileID = profile.id }
                .disabled(coordinator.settings.profileID == profile.id)

            Menu("Share") {
                Button("Export to File…") { exportFile() }
                Button(copied ? "Copied" : "Copy JSON") { copyJSON() }
                Divider()
                Button("Submit on GitHub…") { shareOnGitHub() }
            }
            .fixedSize()
            .disabled(isDirty)
            .help(isDirty ? "Save your changes before sharing" : "Export this profile or submit it to the project")

            Button("Test Tone") { coordinator.playTestBurst(tone: draft.tone) }
                .disabled(!problems.isEmpty || coordinator.targetDevice == nil)
                .help("Play one burst with these settings, including unsaved changes")

            Spacer()

            if !isBuiltIn {
                Button("Revert") { draft = profile }
                    .disabled(!isDirty)
                Button("Save") { save() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || !problems.isEmpty)
            }
        }
        .padding(10)
    }

    private func numberField(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number)
            .multilineTextAlignment(.trailing)
    }

    /// Shares the saved profile, not unsaved edits.
    private var shareable: SpeakerProfile { profile }

    private func save() {
        do {
            try coordinator.profiles.save(draft)
        } catch {
            onError(error)
        }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(shareable.id).json"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProfileCodec.encode(shareable).write(to: url, options: .atomic)
        } catch {
            onError(error)
        }
    }

    private func copyJSON() {
        do {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(try ProfileCodec.encodeString(shareable), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } catch {
            onError(error)
        }
    }

    private func shareOnGitHub() {
        do {
            let link = try ProfileSharing.issueLink(for: shareable)
            if !link.includesProfile {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(try ProfileCodec.encodeString(shareable), forType: .string)
                onError(ShareNotice())
            }
            NSWorkspace.shared.open(link.url)
        } catch {
            onError(error)
        }
    }
}

private struct ShareNotice: LocalizedError {
    var errorDescription: String? {
        "This profile is too long to include in the link, so its JSON has been copied. Paste it into the \"Profile JSON\" box on the GitHub form."
    }
}

// MARK: - Paste sheet

private struct PasteProfileSheet: View {
    var onImport: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Profile JSON").font(.headline)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(width: 460, height: 260)
                .border(.separator)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    onImport(Data(text.utf8))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var detail: String

    init(_ error: any Error) {
        if error is ShareNotice {
            title = "JSON Copied"
        } else {
            title = "Something Went Wrong"
        }
        detail = error.localizedDescription
    }
}
