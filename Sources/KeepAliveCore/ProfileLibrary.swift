import Foundation

/// JSON encoding and decoding for profiles. Output is stable (sorted keys) so
/// exported files diff cleanly and match the files in the repo.
public enum ProfileCodec {
    public static func encode(_ profile: SpeakerProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(profile)
        data.append(0x0A)
        return data
    }

    public static func encodeString(_ profile: SpeakerProfile) throws -> String {
        String(decoding: try encode(profile), as: UTF8.self)
    }

    /// Decodes and validates a profile.
    public static func decode(_ data: Data) throws(ProfileError) -> SpeakerProfile {
        let profile: SpeakerProfile
        do {
            profile = try JSONDecoder().decode(SpeakerProfile.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw .malformed("missing \"\(key.stringValue)\".")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw .malformed("\"\(path)\" has the wrong type.")
        } catch let DecodingError.dataCorrupted(context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw .malformed(path.isEmpty ? "the JSON couldn't be read." : "\"\(path)\" has an unexpected value.")
        } catch {
            throw .malformed(error.localizedDescription)
        }
        try profile.validate()
        return profile
    }
}

/// A folder of `<id>.json` profile files.
public struct ProfileLibrary: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public struct LoadResult: Sendable {
        public var profiles: [SpeakerProfile]
        /// One message per file that couldn't be loaded.
        public var errors: [String]

        public init(profiles: [SpeakerProfile], errors: [String]) {
            self.profiles = profiles
            self.errors = errors
        }
    }

    public func loadAll() -> LoadResult {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var profiles: [SpeakerProfile] = []
        var errors: [String] = []
        var seen = Set<String>()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            do {
                let profile = try ProfileCodec.decode(try Data(contentsOf: file))
                if seen.insert(profile.id).inserted {
                    profiles.append(profile)
                } else {
                    errors.append("\(file.lastPathComponent): duplicate profile ID \"\(profile.id)\".")
                }
            } catch {
                errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return LoadResult(profiles: profiles, errors: errors)
    }

    public func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    public func write(_ profile: SpeakerProfile) throws {
        try profile.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ProfileCodec.encode(profile).write(to: fileURL(for: profile.id), options: .atomic)
    }

    public func delete(id: String) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Builds links for submitting a profile to the project as a GitHub issue.
public enum ProfileSharing {
    public static let repository = "EdMUK/mac_audio_keep_alive"
    public static let issueTemplate = "speaker-profile.yml"
    /// GitHub rejects very long URLs; stay well under its limit.
    public static let maxURLLength = 7_500

    public struct IssueLink: Sendable {
        public var url: URL
        /// False when the JSON was too long for the URL and must be pasted in by hand.
        public var includesProfile: Bool
    }

    public static func issueLink(for profile: SpeakerProfile) throws -> IssueLink {
        let json = try ProfileCodec.encodeString(profile)
        let base: [(String, String)] = [
            ("template", issueTemplate),
            ("title", "[Profile] \(profile.speakerDescription)"),
            ("speaker", profile.speakerDescription),
        ]
        let full = url(base + [("profile", json)])
        if full.absoluteString.count <= maxURLLength {
            return IssueLink(url: full, includesProfile: true)
        }
        return IssueLink(url: url(base), includesProfile: false)
    }

    private static func url(_ items: [(String, String)]) -> URL {
        // Encode strictly (including "+" and "&") rather than relying on
        // URLComponents, which leaves "+" alone and GitHub reads it as a space.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let query = items.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return URL(string: "https://github.com/\(repository)/issues/new?\(query)")!
    }
}
