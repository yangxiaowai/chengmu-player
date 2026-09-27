import Foundation

public enum VideoSelectionGeometry {
    public static func fittedRect(video: CGSize, container: CGSize) -> CGRect {
        guard [video.width, video.height, container.width, container.height].allSatisfy({ $0.isFinite && $0 > 0 }) else { return .zero }
        let scale = min(container.width / video.width, container.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
    /// Uses SwiftUI points, with the origin at the displayed video's top left.
    public static func selection(from start: CGPoint, to end: CGPoint, videoRect rect: CGRect) -> NormalizedVideoRect? {
        guard !rect.isEmpty, !rect.isNull,
              [rect.minX, rect.minY, rect.width, rect.height, start.x, start.y, end.x, end.y].allSatisfy(\.isFinite),
              rect.contains(start) else { return nil }
        let finish = CGPoint(x: min(rect.maxX, max(rect.minX, end.x)), y: min(rect.maxY, max(rect.minY, end.y)))
        let selection = CGRect(x: min(start.x, finish.x), y: min(start.y, finish.y), width: abs(start.x - finish.x), height: abs(start.y - finish.y))
        guard selection.width >= 6, selection.height >= 6 else { return nil }
        return NormalizedVideoRect(x: (selection.minX - rect.minX) / rect.width, y: (selection.minY - rect.minY) / rect.height, width: selection.width / rect.width, height: selection.height / rect.height)
    }
}
