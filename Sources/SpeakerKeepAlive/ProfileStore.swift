import Foundation
import KeepAliveCore
import Observation

/// Built-in profiles (read-only, bundled from `Profiles/`) plus the user's own
/// profiles in Application Support.
@MainActor
@Observable
final class ProfileStore {
    nonisolated static let defaultProfileID = "generic-erp-20min"

    private(set) var builtIn: [SpeakerProfile] = []
    private(set) var custom: [SpeakerProfile] = []
    /// Files that couldn't be loaded, shown in Settings.
    private(set) var loadErrors: [String] = []

    /// Called after profiles change on disk or through this store.
    @ObservationIgnored var onChange: (() -> Void)?

    let userLibrary: ProfileLibrary
    private let builtInLibrary: ProfileLibrary?
    @ObservationIgnored private var watcher: (any DispatchSourceFileSystemObject)?

    init(bundle: Bundle = .main) {
        builtInLibrary = bundle.url(forResource: "Profiles", withExtension: nil).map(ProfileLibrary.init)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        userLibrary = ProfileLibrary(directory: support.appending(path: "SpeakerKeepAlive/Profiles", directoryHint: .isDirectory))
        try? FileManager.default.createDirectory(at: userLibrary.directory, withIntermediateDirectories: true)
        reload()
        watchUserDirectory()
    }

    var all: [SpeakerProfile] { builtIn + custom }

    func profile(id: String) -> SpeakerProfile? {
        all.first { $0.id == id }
    }

    func isBuiltIn(_ id: String) -> Bool {
        builtIn.contains { $0.id == id }
    }

    /// Used when the selected profile has gone (e.g. deleted).
    var fallback: SpeakerProfile {
        profile(id: Self.defaultProfileID) ?? builtIn.first ?? Self.emergencyProfile
    }

    func reload() {
        let bundled = builtInLibrary?.loadAll() ?? .init(profiles: [], errors: ["The app's built-in profiles are missing."])
        let user = userLibrary.loadAll()
        let builtInIDs = Set(bundled.profiles.map(\.id))
        var errors = bundled.errors.map { "Built-in \($0)" } + user.errors
        let clashes = user.profiles.filter { builtInIDs.contains($0.id) }
        errors += clashes.map { "\($0.id).json: uses the same ID as a built-in profile, so it was skipped." }

        builtIn = bundled.profiles
        custom = user.profiles.filter { !builtInIDs.contains($0.id) }
        loadErrors = errors
        onChange?()
    }

    // MARK: - Editing

    func save(_ profile: SpeakerProfile) throws {
        precondition(!isBuiltIn(profile.id), "Built-in profiles are read-only")
        try userLibrary.write(profile)
        reload()
    }

    func delete(id: String) throws {
        guard !isBuiltIn(id) else { return }
        try userLibrary.delete(id: id)
        reload()
    }

    @discardableResult
    func duplicate(_ source: SpeakerProfile) throws -> SpeakerProfile {
        var copy = source
        copy.name = "\(source.name) (copy)"
        copy.id = ProfileIDs.unique(ProfileIDs.slug(copy.name), existing: Set(all.map(\.id)))
        copy.tested = false
        try save(copy)
        return copy
    }

    @discardableResult
    func makeNew() throws -> SpeakerProfile {
        var profile = fallback
        profile.name = "New Speaker"
        profile.manufacturer = ""
        profile.model = ""
        profile.notes = ""
        profile.sourceURL = nil
        profile.tested = false
        profile.id = ProfileIDs.unique(ProfileIDs.slug(profile.name), existing: Set(all.map(\.id)))
        try save(profile)
        return profile
    }

    /// Imports exported JSON. If the ID is already used (including by a
    /// built-in), the import gets a fresh ID rather than overwriting anything.
    @discardableResult
    func importProfile(from data: Data) throws -> SpeakerProfile {
        var profile = try ProfileCodec.decode(data)
        let existing = Set(all.map(\.id))
        if existing.contains(profile.id) {
            profile.id = ProfileIDs.unique(profile.id, existing: existing)
        }
        try save(profile)
        return profile
    }

    // MARK: - Watching

    /// Picks up profiles dropped into the folder by hand.
    private func watchUserDirectory() {
        let descriptor = open(userLibrary.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private static let emergencyProfile = SpeakerProfile(
        id: "fallback",
        name: "Fallback",
        standbyTimeoutMinutes: 20,
        tone: ToneSettings(frequencyHz: 40, levelDBFS: -45, burstSeconds: 3, intervalSeconds: 300)
    )
}
