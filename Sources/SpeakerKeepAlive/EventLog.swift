import Foundation
import os

/// A plain-text record of what the app did and when (status changes, audio
/// devices coming and going, the stream restarting), so that "the speakers went
/// off at about 3pm" can be matched against what the Mac was doing then.
///
/// Lines are only written when something changes, a handful a day, on a
/// background queue. The file is capped at about 1 MB, keeping one older file.
final class EventLog: Sendable {
    static let shared = EventLog()

    let fileURL: URL
    private let previousURL: URL
    private let queue = DispatchQueue(label: "io.github.edmuk.SpeakerKeepAlive.eventlog", qos: .utility)
    private let logger = Logger(subsystem: "io.github.edmuk.SpeakerKeepAlive", category: "events")
    private static let maxBytes = 1_000_000

    private init() {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/SpeakerKeepAlive", directoryHint: .isDirectory)
        fileURL = directory.appending(path: "events.log")
        previousURL = directory.appending(path: "events.1.log")
    }

    func record(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        // Local time with its UTC offset, e.g. 2026-10-28T19:11:40+01:00.
        let line = "\(Date.now.ISO8601Format(.init(timeZone: .current)))  \(message)\n"
        queue.async { [fileURL, previousURL] in
            let manager = FileManager.default
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > Self.maxBytes {
                try? manager.removeItem(at: previousURL)
                try? manager.moveItem(at: fileURL, to: previousURL)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
