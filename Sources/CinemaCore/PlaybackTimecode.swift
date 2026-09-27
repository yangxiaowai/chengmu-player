import Foundation

public enum PlaybackTimecode {
    public enum Failure: Error, Equatable, LocalizedError {
        case invalidFormat, outOfRange, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalidFormat: return "请输入秒数、分:秒或时:分:秒，例如 90、24:04、1:02:03。"
            case .outOfRange: return "目标时间超出影片时长。"
            case .unavailable: return "影片时长尚未就绪，暂时无法定位。"
            }
        }
    }

    public static func seconds(from input: String, duration: Double) throws -> Double {
        guard duration.isFinite, duration > 0 else { throw Failure.unavailable }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 32 else { throw Failure.invalidFormat }
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { throw Failure.invalidFormat }
        var total = 0.0
        for (index, field) in fields.enumerated() {
            let decimal = index == fields.count - 1
            let parts = field.split(separator: ".", omittingEmptySubsequences: false)
            guard (decimal ? (1...2).contains(parts.count) : parts.count == 1),
                  parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let value = Double(field), value.isFinite,
                  (index == 0 || value < 60) else { throw Failure.invalidFormat }
            total = total * 60 + value
        }
        guard total.isFinite else { throw Failure.invalidFormat }
        guard total <= duration else { throw Failure.outOfRange }
        return total
    }
}
