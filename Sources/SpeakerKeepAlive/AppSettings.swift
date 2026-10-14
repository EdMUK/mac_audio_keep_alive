import Foundation
import KeepAliveCore

/// Per-Mac settings. Speaker-specific values live in profiles instead.
struct AppSettings: Codable, Equatable {
    /// CoreAudio UID of the output to keep alive; nil follows the system default output.
    var deviceUID: String?
    /// Last known name of `deviceUID`, shown while it's disconnected.
    var deviceName: String?
    var profileID: String = ProfileStore.defaultProfileID
    var schedule: Schedule = .default
    /// Set once the first-launch device pick has run, so choosing "System
    /// default" later isn't overridden.
    var hasChosenDevice = false

    private static let key = "settings.v1"

    init() {}

    /// Missing keys fall back to defaults, so settings saved by older versions still load.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? ProfileStore.defaultProfileID
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? .default
        hasChosenDevice = try c.decodeIfPresent(Bool.self, forKey: .hasChosenDevice) ?? false
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
