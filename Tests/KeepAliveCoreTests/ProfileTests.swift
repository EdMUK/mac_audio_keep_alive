import Foundation
import Testing
@testable import KeepAliveCore

private let repoProfiles = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Profiles")

private func sample() -> SpeakerProfile {
    SpeakerProfile(
        id: "acme-test",
        name: "Acme Test",
        manufacturer: "Acme",
        model: "T1+",
        connection: .optical,
        standbyTimeoutMinutes: 19,
        tone: ToneSettings(frequencyHz: 18, levelDBFS: -50, burstSeconds: 3, intervalSeconds: 300),
        notes: "Notes with \"quotes\", & ampersands, + plus signs\nand a new line.",
        sourceURL: "https://example.com/manual.pdf"
    )
}

@Suite struct ProfileTests {
    @Test func builtInProfilesAreValid() throws {
        let result = ProfileLibrary(directory: repoProfiles).loadAll()
        #expect(result.errors.isEmpty, "\(result.errors)")
        #expect(result.profiles.map(\.id).sorted() == ["generic-erp-20min", "majority-d70x"])
    }

    @Test func builtInFilesAreCanonicallyFormatted() throws {
        // Files in the repo should match what the app exports, so exported
        // profiles from users diff cleanly against them.
        for profile in ProfileLibrary(directory: repoProfiles).loadAll().profiles {
            let onDisk = try String(contentsOf: ProfileLibrary(directory: repoProfiles).fileURL(for: profile.id), encoding: .utf8)
            #expect(onDisk == (try ProfileCodec.encodeString(profile)), "\(profile.id).json isn't canonically formatted")
        }
    }

    @Test func builtInFileNamesMatchIDs() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: repoProfiles.path).filter { $0.hasSuffix(".json") }
        for file in files {
            let profile = try ProfileCodec.decode(Data(contentsOf: repoProfiles.appending(path: file)))
            #expect(file == "\(profile.id).json")
        }
    }

    @Test func roundTrip() throws {
        let profile = sample()
        #expect(try ProfileCodec.decode(ProfileCodec.encode(profile)) == profile)
    }

    @Test func optionalFieldsDefault() throws {
        let json = #"{"id":"min","name":"Minimal","tone":{"frequencyHz":20,"levelDBFS":-50,"burstSeconds":2,"intervalSeconds":120,"fadeMilliseconds":50}}"#
        let profile = try ProfileCodec.decode(Data(json.utf8))
        #expect(profile.schemaVersion == 1)
        #expect(profile.connection == .other)
        #expect(profile.standbyTimeoutMinutes == 20)
        #expect(profile.keepStreamOpen)
        #expect(!profile.tested)
    }

    enum Field: Sendable {
        case frequency, level, burst, interval, fade, standbyTimeout

        func set(_ value: Double, on profile: inout SpeakerProfile) {
            switch self {
            case .frequency: profile.tone.frequencyHz = value
            case .level: profile.tone.levelDBFS = value
            case .burst: profile.tone.burstSeconds = value
            case .interval: profile.tone.intervalSeconds = value
            case .fade: profile.tone.fadeMilliseconds = value
            case .standbyTimeout: profile.standbyTimeoutMinutes = value
            }
        }
    }

    @Test(arguments: [
        (Field.frequency, 2.0),
        (.frequency, 30_000.0),
        (.level, -6.0),
        (.level, Double.nan),
        (.burst, 0.1),
        (.interval, 1_200.0), // longer than the 19 min timeout
        (.fade, 2_000.0),
        (.standbyTimeout, 0.0),
    ])
    func outOfRangeValuesAreRefused(field: Field, value: Double) {
        var profile = sample()
        field.set(value, on: &profile)
        #expect(!profile.validationProblems.isEmpty)
        #expect(throws: ProfileError.self) { try profile.validate() }
    }

    @Test func badIDsAndNamesAreRefused() {
        var profile = sample()
        profile.id = "Has Spaces"
        #expect(!profile.validationProblems.isEmpty)
        profile.id = "../escape"
        #expect(!profile.validationProblems.isEmpty)
        profile = sample()
        profile.name = "  "
        #expect(!profile.validationProblems.isEmpty)
        profile = sample()
        profile.sourceURL = "file:///etc/passwd"
        #expect(!profile.validationProblems.isEmpty)
    }

    @Test func newerSchemaIsRefused() throws {
        var profile = sample()
        profile.schemaVersion = 99
        let data = try JSONEncoder().encode(profile)
        #expect(throws: ProfileError.unsupportedSchema(99)) { try ProfileCodec.decode(data) }
    }

    @Test func malformedJSONGivesReadableError() {
        #expect(throws: ProfileError.self) { try ProfileCodec.decode(Data("{".utf8)) }
        #expect(throws: ProfileError.malformed("missing \"tone\".")) {
            try ProfileCodec.decode(Data(#"{"id":"x","name":"X"}"#.utf8))
        }
    }

    @Test func slugsAndUniqueIDs() {
        #expect(ProfileIDs.slug("Majority D70X") == "majority-d70x")
        #expect(ProfileIDs.slug("  Bowers & Wilkins — Zeppelin!! ") == "bowers-wilkins-zeppelin")
        #expect(ProfileIDs.slug("Café") == "cafe")
        #expect(ProfileIDs.slug("!!!") == "profile")
        #expect(ProfileIDs.unique("a", existing: []) == "a")
        #expect(ProfileIDs.unique("a", existing: ["a", "a-2"]) == "a-3")
    }

    @Test func libraryWritesLoadsAndDeletes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ProfileLibrary(directory: dir)
        try library.write(sample())
        try Data("not json".utf8).write(to: dir.appending(path: "broken.json"))

        let loaded = library.loadAll()
        #expect(loaded.profiles == [sample()])
        #expect(loaded.errors.count == 1)
        #expect(loaded.errors.first?.hasPrefix("broken.json") == true)

        try library.delete(id: "acme-test")
        #expect(library.loadAll().profiles.isEmpty)
    }

    @Test func libraryRefusesInvalidProfiles() {
        var profile = sample()
        profile.tone.levelDBFS = 0
        let library = ProfileLibrary(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(throws: ProfileError.self) { try library.write(profile) }
    }

    @Test func issueLinkPrefillsForm() throws {
        let link = try ProfileSharing.issueLink(for: sample())
        #expect(link.includesProfile)
        let components = try #require(URLComponents(url: link.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com")
        #expect(components.path == "/EdMUK/mac_audio_keep_alive/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["template"] == "speaker-profile.yml")
        #expect(items["title"] == "[Profile] Acme T1+")
        #expect(items["speaker"] == "Acme T1+")
        #expect(try ProfileCodec.decode(Data(items["profile"]!.utf8)) == sample())
        // "+" must be percent-encoded or GitHub turns it into a space.
        #expect(!link.url.absoluteString.contains("+"))
    }

    @Test func issueLinkDropsOversizedProfile() throws {
        var profile = sample()
        profile.notes = String(repeating: "long notes ", count: 1_000)
        let link = try ProfileSharing.issueLink(for: profile)
        #expect(!link.includesProfile)
        #expect(link.url.absoluteString.count <= ProfileSharing.maxURLLength)
    }
}
