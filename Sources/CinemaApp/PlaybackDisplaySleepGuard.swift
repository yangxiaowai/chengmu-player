import Foundation
import IOKit.pwr_mgt

/// Owns one native display-idle assertion on the controller's main-actor lifecycle.
/// This covers both AVPlayerLayer and custom Metal presentation without a helper process.
@MainActor final class PlaybackDisplaySleepGuard {
    private var assertion: IOPMAssertionID?
    private(set) var error: String?

    func update(shouldPreventSleep: Bool) {
        if shouldPreventSleep {
            guard assertion == nil else { return }
            var candidate = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                   IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                   "Chengmu video playback" as CFString, &candidate)
            if status == kIOReturnSuccess { assertion = candidate; error = nil }
            else { error = "系统暂未接受屏幕常亮请求（\(status)）" }
        } else {
            guard let assertion else { error = nil; return }
            let status = IOPMAssertionRelease(assertion)
            if status == kIOReturnSuccess { self.assertion = nil; error = nil }
            else { error = "系统暂未释放屏幕常亮请求（\(status)）" }
        }
    }

    deinit {
        if let assertion { IOPMAssertionRelease(assertion) }
    }
}
