import Foundation

public enum SeekTimelineGeometry {
    /// NSSlider's thumb centers stop half a knob-width inside its bar bounds.
    public static func time(at x: Double, width: Double, knobWidth: Double, duration: Double) -> Double? {
        guard x.isFinite, width.isFinite, knobWidth.isFinite, duration.isFinite,
              knobWidth >= 0, width > knobWidth, duration > 0 else { return nil }
        return min(1, max(0, (x - knobWidth / 2) / (width - knobWidth))) * duration
    }

    public static func bubbleOrigin(at x: Double, width: Double, bubbleWidth: Double) -> Double {
        guard x.isFinite, width.isFinite, bubbleWidth.isFinite else { return 0 }
        return max(0, min(max(0, width - bubbleWidth), x - bubbleWidth / 2))
    }
}
