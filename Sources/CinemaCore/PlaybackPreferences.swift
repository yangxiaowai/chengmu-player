import Foundation

/// Validated values shared by the player and its persisted preferences.
public struct PlaybackPreferences: Codable, Equatable, Sendable {
    public private(set) var volume: Double
    public private(set) var rate: Double
    public private(set) var enhancement: String
    public private(set) var lastAudibleVolume: Double
    public private(set) var automaticAdSkipping: Bool
    /// Output preference only. It never changes the selected track, the source or the play intent.
    public private(set) var keepsOriginalAudioLayout: Bool
    /// Whether the realtime pipeline may replace the picture at all. `original` keeps the system's
    /// own output for every source; it never changes what the source is.
    public private(set) var pipeline: String

    public static let pipelineEnhanced = "enhanced"
    public static let pipelineOriginal = "original"

    public init(volume: Double = 0.8, rate: Double = 1, enhancement: String = "clarity", lastAudibleVolume: Double = 0.8, automaticAdSkipping: Bool = true, keepsOriginalAudioLayout: Bool = false, pipeline: String = PlaybackPreferences.pipelineOriginal) {
        self.volume = Self.validVolume(volume)
        self.rate = Self.validRate(rate)
        self.enhancement = Self.validEnhancement(enhancement)
        self.lastAudibleVolume = self.volume > 0 ? self.volume : (lastAudibleVolume.isFinite && lastAudibleVolume > 0 ? min(1, lastAudibleVolume) : 0.8)
        self.automaticAdSkipping = automaticAdSkipping
        self.keepsOriginalAudioLayout = keepsOriginalAudioLayout
        self.pipeline = Self.validPipeline(pipeline)
    }

    public mutating func setVolume(_ value: Double) {
        volume = Self.validVolume(value)
        if volume > 0 { lastAudibleVolume = volume }
    }
    public mutating func toggleMute() { setVolume(volume > 0 ? 0 : lastAudibleVolume) }
    public mutating func setRate(_ value: Double) { rate = Self.validRate(value) }
    public mutating func setEnhancement(_ value: String) { enhancement = Self.validEnhancement(value) }
    public mutating func setAutomaticAdSkipping(_ value: Bool) { automaticAdSkipping = value }
    public mutating func setKeepsOriginalAudioLayout(_ value: Bool) { keepsOriginalAudioLayout = value }
    public mutating func setPipeline(_ value: String) { pipeline = Self.validPipeline(value) }
    /// True when the realtime pipeline may replace the picture. It only ever affects SDR sources:
    /// Dolby Vision and HDR always keep the system's native presentation.
    public var pipelineProcessesFrames: Bool { pipeline != Self.pipelineOriginal }

    private static func validVolume(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.8 }
    private static func validRate(_ value: Double) -> Double { value.isFinite ? min(2, max(0.5, value)) : 1 }
    private static func validEnhancement(_ value: String) -> String {
        ["original", "clarity", "upscale4K", "appleAI"].contains(value) ? value : "upscale4K"
    }
    private static func validPipeline(_ value: String) -> String {
        value == pipelineOriginal ? pipelineOriginal : pipelineEnhanced
    }
    private enum CodingKeys: String, CodingKey { case volume, rate, enhancement, lastAudibleVolume, automaticAdSkipping, keepsOriginalAudioLayout, pipeline }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8,
                  rate: try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1,
                  enhancement: try container.decodeIfPresent(String.self, forKey: .enhancement) ?? "upscale4K",
                  lastAudibleVolume: try container.decodeIfPresent(Double.self, forKey: .lastAudibleVolume) ?? 0.8,
                  automaticAdSkipping: try container.decodeIfPresent(Bool.self, forKey: .automaticAdSkipping) ?? true,
                  keepsOriginalAudioLayout: try container.decodeIfPresent(Bool.self, forKey: .keepsOriginalAudioLayout) ?? false,
                  pipeline: try container.decodeIfPresent(String.self, forKey: .pipeline) ?? PlaybackPreferences.pipelineEnhanced)
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
