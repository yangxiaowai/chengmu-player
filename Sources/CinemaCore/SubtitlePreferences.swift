import Foundation

/// Global presentation preferences. Track selection, files and timing belong to an individual film.
public struct SubtitlePreferences: Codable, Equatable, Sendable {
    public let visible: Bool
    public let fontSize: Double
    public let backgroundEnabled: Bool
    public let verticalOffset: Double

    public init(visible: Bool = true, fontSize: Double = 22, backgroundEnabled: Bool = true, verticalOffset: Double = 0) {
        self.visible = visible
        self.fontSize = fontSize.isFinite ? min(36, max(18, fontSize)) : 22
        self.backgroundEnabled = backgroundEnabled
        self.verticalOffset = verticalOffset.isFinite ? min(120, max(0, verticalOffset)) : 0
    }
    private enum CodingKeys: String, CodingKey { case visible, fontSize, backgroundEnabled, verticalOffset }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(visible: (try? values.decode(Bool.self, forKey: .visible)) ?? true,
                  fontSize: (try? values.decode(Double.self, forKey: .fontSize)) ?? 22,
                  backgroundEnabled: (try? values.decode(Bool.self, forKey: .backgroundEnabled)) ?? true,
                  verticalOffset: (try? values.decode(Double.self, forKey: .verticalOffset)) ?? 0)
    }
}

public struct SubtitlePreferencesStore {
    private let defaults: UserDefaults
    private let enabled: Bool
    private let key = "subtitlePreferences.v1"
    public init(defaults: UserDefaults = .standard, arguments: [String] = CommandLine.arguments) {
        self.defaults = defaults
        enabled = !arguments.contains("--validate") && !arguments.contains("--benchmark")
    }
    public func load() -> SubtitlePreferences {
        guard enabled, let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(SubtitlePreferences.self, from: data) else { return SubtitlePreferences() }
        return preferences
    }
    public func save(_ preferences: SubtitlePreferences) {
        guard enabled, let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
