import Foundation

/// Validated values shared by the player and its persisted preferences.
public struct PlaybackPreferences: Codable, Equatable, Sendable {
    public private(set) var volume: Double
    public private(set) var rate: Double
    public private(set) var enhancement: String
    public private(set) var lastAudibleVolume: Double

    public init(volume: Double = 0.8, rate: Double = 1, enhancement: String = "upscale4K", lastAudibleVolume: Double = 0.8) {
        self.volume = Self.validVolume(volume)
        self.rate = Self.validRate(rate)
        self.enhancement = Self.validEnhancement(enhancement)
        self.lastAudibleVolume = self.volume > 0 ? self.volume : (lastAudibleVolume.isFinite && lastAudibleVolume > 0 ? min(1, lastAudibleVolume) : 0.8)
    }

    public mutating func setVolume(_ value: Double) {
        volume = Self.validVolume(value)
        if volume > 0 { lastAudibleVolume = volume }
    }
    public mutating func toggleMute() { setVolume(volume > 0 ? 0 : lastAudibleVolume) }
    public mutating func setRate(_ value: Double) { rate = Self.validRate(value) }
    public mutating func setEnhancement(_ value: String) { enhancement = Self.validEnhancement(value) }

    private static func validVolume(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.8 }
    private static func validRate(_ value: Double) -> Double { value.isFinite ? min(2, max(0.5, value)) : 1 }
    private static func validEnhancement(_ value: String) -> String {
        ["original", "clarity", "upscale4K", "appleAI"].contains(value) ? value : "upscale4K"
    }
    private enum CodingKeys: String, CodingKey { case volume, rate, enhancement, lastAudibleVolume }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8,
                  rate: try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1,
                  enhancement: try container.decodeIfPresent(String.self, forKey: .enhancement) ?? "upscale4K",
                  lastAudibleVolume: try container.decodeIfPresent(Double.self, forKey: .lastAudibleVolume) ?? 0.8)
    }
}

public struct PlaybackPreferencesStore {
    private let defaults: UserDefaults
    private let enabled: Bool
    private let key = "playbackPreferences.v1"
    public init(defaults: UserDefaults = .standard, arguments: [String] = CommandLine.arguments) {
        self.defaults = defaults
        enabled = !arguments.contains("--validate") && !arguments.contains("--benchmark")
    }
    public func load() -> PlaybackPreferences {
        guard enabled, let data = defaults.data(forKey: key), let preferences = try? JSONDecoder().decode(PlaybackPreferences.self, from: data) else {
            return PlaybackPreferences()
        }
        return preferences
    }
    public func save(_ preferences: PlaybackPreferences) {
        guard enabled, let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Uses a deadline so buffering, pauses and delayed wakeups do not lengthen the timer.
public struct PlaybackSleepTimer: Sendable {
    public static let minuteOptions = [15, 30, 60, 90]
    public private(set) var deadline: Date?
    public init() {}
    @discardableResult public mutating func schedule(minutes: Int, now: Date = Date()) -> Bool {
        guard Self.minuteOptions.contains(minutes) else { return false }
        deadline = now.addingTimeInterval(Double(minutes * 60))
        return true
    }
    public mutating func cancel() { deadline = nil }
    public func remainingSeconds(at now: Date = Date()) -> Int? {
        guard let deadline else { return nil }
        return Int(max(0, ceil(deadline.timeIntervalSince(now))))
    }
    public mutating func consumeExpiration(at now: Date = Date()) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}
