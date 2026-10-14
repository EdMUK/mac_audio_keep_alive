import Foundation

/// How a speaker is connected to the Mac. Informational only: the app always
/// plays to whichever output device the user picks.
public enum SpeakerConnection: String, Codable, CaseIterable, Sendable {
    case optical, usb, hdmi, analog, bluetooth, other

    public var displayName: String {
        switch self {
        case .optical: "Optical (S/PDIF)"
        case .usb: "USB"
        case .hdmi: "HDMI"
        case .analog: "Analogue"
        case .bluetooth: "Bluetooth"
        case .other: "Other"
        }
    }
}

/// The keep-alive tone: a sine wave played in short bursts, often enough to
/// reset the speaker's auto-standby timer.
public struct ToneSettings: Codable, Hashable, Sendable {
    public var frequencyHz: Double
    public var levelDBFS: Double
    public var burstSeconds: Double
    public var intervalSeconds: Double
    public var fadeMilliseconds: Double

    public init(frequencyHz: Double, levelDBFS: Double, burstSeconds: Double, intervalSeconds: Double, fadeMilliseconds: Double = 50) {
        self.frequencyHz = frequencyHz
        self.levelDBFS = levelDBFS
        self.burstSeconds = burstSeconds
        self.intervalSeconds = intervalSeconds
        self.fadeMilliseconds = fadeMilliseconds
    }

    /// Linear peak amplitude (0...1) for `levelDBFS`.
    public var amplitude: Double { pow(10, levelDBFS / 20) }
}

/// Everything a particular speaker model needs to stay awake. Profiles are
/// shared as JSON, so field names are part of the public format.
public struct SpeakerProfile: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var manufacturer: String
    public var model: String
    public var connection: SpeakerConnection
    /// How long the speaker waits without a signal before going to standby.
    public var standbyTimeoutMinutes: Double
    public var tone: ToneSettings
    /// Keep the output stream running between bursts. This keeps digital links
    /// locked, so audio you play afterwards doesn't start clipped.
    public var keepStreamOpen: Bool
    public var notes: String
    public var sourceURL: String?
    /// Whether someone has confirmed this profile keeps the speaker awake.
    public var tested: Bool

    public init(
        schemaVersion: Int = SpeakerProfile.currentSchemaVersion,
        id: String,
        name: String,
        manufacturer: String = "",
        model: String = "",
        connection: SpeakerConnection = .other,
        standbyTimeoutMinutes: Double = 20,
        tone: ToneSettings,
        keepStreamOpen: Bool = true,
        notes: String = "",
        sourceURL: String? = nil,
        tested: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.connection = connection
        self.standbyTimeoutMinutes = standbyTimeoutMinutes
        self.tone = tone
        self.keepStreamOpen = keepStreamOpen
        self.notes = notes
        self.sourceURL = sourceURL
        self.tested = tested
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, manufacturer, model, connection, standbyTimeoutMinutes, tone, keepStreamOpen, notes, sourceURL, tested
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        connection = try c.decodeIfPresent(SpeakerConnection.self, forKey: .connection) ?? .other
        standbyTimeoutMinutes = try c.decodeIfPresent(Double.self, forKey: .standbyTimeoutMinutes) ?? 20
        tone = try c.decode(ToneSettings.self, forKey: .tone)
        keepStreamOpen = try c.decodeIfPresent(Bool.self, forKey: .keepStreamOpen) ?? true
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        tested = try c.decodeIfPresent(Bool.self, forKey: .tested) ?? false
    }

    /// Short label such as "Majority D70X", falling back to the profile name.
    public var speakerDescription: String {
        let parts = [manufacturer, model].filter { !$0.isEmpty }
        return parts.isEmpty ? name : parts.joined(separator: " ")
    }
}

// MARK: - Validation

public enum ProfileLimits {
    public static let frequencyHz: ClosedRange<Double> = 5...22_000
    public static let levelDBFS: ClosedRange<Double> = -90...(-20)
    public static let burstSeconds: ClosedRange<Double> = 0.5...60
    public static let intervalSeconds: ClosedRange<Double> = 10...7_200
    public static let fadeMilliseconds: ClosedRange<Double> = 5...1_000
    public static let standbyTimeoutMinutes: ClosedRange<Double> = 1...240
}

public enum ProfileError: Error, Equatable, LocalizedError {
    case invalid([String])
    case unsupportedSchema(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let problems):
            "This profile isn't valid:\n• " + problems.joined(separator: "\n• ")
        case .unsupportedSchema(let version):
            "This profile uses schema version \(version), which needs a newer version of Speaker Keep-Alive."
        case .malformed(let detail):
            "This isn't a valid speaker profile: \(detail)"
        }
    }
}

extension SpeakerProfile {
    /// Human-readable problems; empty when the profile is usable.
    public var validationProblems: [String] {
        var problems: [String] = []
        func check(_ value: Double, _ range: ClosedRange<Double>, _ label: String) {
            if !value.isFinite || !range.contains(value) {
                problems.append("\(label) must be between \(range.lowerBound.formatted()) and \(range.upperBound.formatted()).")
            }
        }

        if schemaVersion > Self.currentSchemaVersion {
            problems.append("Schema version \(schemaVersion) is newer than this app supports.")
        }
        if !ProfileIDs.isValid(id) {
            problems.append("ID may only contain lowercase letters, numbers, dots and hyphens.")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Name can't be empty.")
        }
        check(tone.frequencyHz, ProfileLimits.frequencyHz, "Frequency (Hz)")
        check(tone.levelDBFS, ProfileLimits.levelDBFS, "Level (dBFS)")
        check(tone.burstSeconds, ProfileLimits.burstSeconds, "Burst length (s)")
        check(tone.intervalSeconds, ProfileLimits.intervalSeconds, "Interval (s)")
        check(tone.fadeMilliseconds, ProfileLimits.fadeMilliseconds, "Fade (ms)")
        check(standbyTimeoutMinutes, ProfileLimits.standbyTimeoutMinutes, "Standby timeout (min)")

        if tone.fadeMilliseconds * 2 > tone.burstSeconds * 1000 {
            problems.append("Fade in plus fade out must fit inside the burst.")
        }
        if tone.burstSeconds >= tone.intervalSeconds {
            problems.append("Burst length must be shorter than the interval.")
        }
        if tone.intervalSeconds >= standbyTimeoutMinutes * 60 {
            problems.append("Interval must be shorter than the speaker's standby timeout, or it will fall asleep between bursts.")
        }
        if let sourceURL, !sourceURL.isEmpty, URL(string: sourceURL)?.scheme?.hasPrefix("http") != true {
            problems.append("Source URL must be an http(s) link.")
        }
        return problems
    }

    public func validate() throws(ProfileError) {
        if schemaVersion > Self.currentSchemaVersion {
            throw .unsupportedSchema(schemaVersion)
        }
        let problems = validationProblems
        if !problems.isEmpty {
            throw .invalid(problems)
        }
    }
}

// MARK: - IDs

public enum ProfileIDs {
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "."
        } && !id.hasPrefix(".")
    }

    /// Lowercase, hyphen-separated form of `text`, e.g. "Majority D70X" -> "majority-d70x".
    public static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty, !result.hasSuffix("-") {
                result.append("-")
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "profile" : String(result.prefix(60))
    }

    /// `base` if unused, otherwise `base-2`, `base-3`, …
    public static func unique(_ base: String, existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
