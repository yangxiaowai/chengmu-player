import Foundation
import Testing
@testable import CinemaCore

struct HistoryCompletionTests {
    private func record(_ position: Double, _ duration: Double) -> WatchRecord {
        .init(id: "movie", title: "Movie", episode: "正片", url: URL(string: "https://example.com/movie.mp4")!, posterURL: nil, position: position, duration: duration)
    }
    @Test func completedIsAReversibleViewOfValidProgress() {
        #expect(!record(94.99, 100).isCompleted)
        #expect(record(95, 100).isCompleted)
        #expect(record(120, 100).isCompleted)
        #expect(!record(0, 100).isCompleted)
        #expect(!record(-1, 100).isCompleted)
        #expect(!record(100, 0).isCompleted)
        #expect(!record(100, -.infinity).isCompleted)
        #expect(!record(.nan, 100).isCompleted)
        #expect(!record(100, .infinity).isCompleted)
    }
    @Test func completedStatusDoesNotChangeStoredHistory() throws {
        let original = record(96, 100)
        let restored = try JSONDecoder().decode(WatchRecord.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.isCompleted)
    }
}
