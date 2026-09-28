import Foundation
import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import CinemaCore

/// Layered description of what a source actually offers, what is selected right now, what this Mac
/// can do and what the player decided. Each layer is reported separately: a manifest declaration, a
/// selected track and a hardware capability are different kinds of evidence.
struct MediaExperienceStatus: Equatable {
    var title = ""
    /// Declarations from the outermost HLS master playlist.
    var declaredVariants = 0
    var declaredDolbyVision = false
    var declaredHDR = false
    var declaredAtmos = false
    var declarationNote: String?
    /// The selected video track as read from the item's own format descriptions.
    var videoDetail = "正在读取当前视频轨道…"
    var videoIsDolbyVision = false
    var videoIsHDR = false
    /// The selected audio track.
    var audioDetail = "正在读取当前音轨…"
    var audioIsAtmos = false
    var audioChannelCount = 0
    var audioSpatialization = "未请求"
    /// This Mac and this screen.
    var deviceDetail = "正在读取系统能力…"
    var nativePlayback = false
    /// Real variant switch events observed during this item.
    var variantEvents: [String] = []
    var limitations: [String] = []

    static func == (lhs: MediaExperienceStatus, rhs: MediaExperienceStatus) -> Bool {
        lhs.title == rhs.title && lhs.declaredVariants == rhs.declaredVariants && lhs.declaredDolbyVision == rhs.declaredDolbyVision
            && lhs.declaredHDR == rhs.declaredHDR && lhs.declaredAtmos == rhs.declaredAtmos && lhs.declarationNote == rhs.declarationNote
            && lhs.videoDetail == rhs.videoDetail && lhs.videoIsDolbyVision == rhs.videoIsDolbyVision && lhs.videoIsHDR == rhs.videoIsHDR
            && lhs.audioDetail == rhs.audioDetail && lhs.audioIsAtmos == rhs.audioIsAtmos && lhs.audioChannelCount == rhs.audioChannelCount
            && lhs.audioSpatialization == rhs.audioSpatialization && lhs.deviceDetail == rhs.deviceDetail && lhs.nativePlayback == rhs.nativePlayback
            && lhs.variantEvents == rhs.variantEvents && lhs.limitations == rhs.limitations
    }
}

@MainActor
final class MediaExperienceInspector: ObservableObject {
    @Published private(set) var status = MediaExperienceStatus()
    /// What the enhancement path is allowed to do for the current item.
    @Published private(set) var videoPermission = VideoProcessingPermission.inspectSDRFrames
    private(set) var formatEvents: [String] = []
    private var task: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var token = UUID()
    private var keepsOriginalLayout = false

    init() {
        status.deviceDetail = Self.deviceDescription()
    }

    /// `declarations` comes from the HLS probe (manifest evidence); everything else is read from the
    /// item that is actually playing.
    func begin(item: AVPlayerItem, declarations: HLSMediaDeclarations?, keepsOriginalAudioLayout: Bool, spatializationEnabled: Bool) {
        task?.cancel(); metricsTask?.cancel()
        let run = UUID(); token = run
        keepsOriginalLayout = keepsOriginalAudioLayout
        formatEvents = []
        var fresh = MediaExperienceStatus()
        fresh.title = item.asset.description.isEmpty ? "" : ""
        fresh.deviceDetail = Self.deviceDescription()
        if let declarations {
            fresh.declaredVariants = declarations.variants.count
            fresh.declaredDolbyVision = declarations.hasDolbyVision
            fresh.declaredHDR = declarations.hasHDRVideo
            fresh.declaredAtmos = declarations.hasAtmosDeclaration
            fresh.declarationNote = declarations.isEmpty ? "这不是主播放清单，读不到版本声明" : nil
        } else {
            fresh.declarationNote = "尚未读到主清单声明"
        }
        fresh.limitations = Self.limitations
        status = fresh
        videoPermission = .inspectSDRFrames
        applyAudioPolicy(item: item, spatializationEnabled: spatializationEnabled)
        observeMetrics(item: item, token: run)
        task = Task { [weak self, weak item] in
            guard let self, let item else { return }
            await self.inspect(item: item, token: run)
        }
    }

    /// Called when the HLS probe finishes, which usually happens after playback starts.
    func updateDeclarations(_ declarations: HLSMediaDeclarations?) {
        guard let declarations else { return }
        var value = status
        value.declaredVariants = declarations.variants.count
        value.declaredDolbyVision = declarations.hasDolbyVision
        value.declaredHDR = declarations.hasHDRVideo
        value.declaredAtmos = declarations.hasAtmosDeclaration
        value.declarationNote = declarations.isEmpty ? "这不是主播放清单，读不到版本声明" : nil
        status = value
    }

    func updateAudioLayoutPreference(_ keepsOriginal: Bool, item: AVPlayerItem?) {
        keepsOriginalLayout = keepsOriginal
        guard let item else { return }
        item.allowedAudioSpatializationFormats = keepsOriginal ? [] : .multichannel
        var value = status
        value.audioSpatialization = keepsOriginal ? "保持原声布局（不请求空间化）" : "已请求多声道空间化"
        status = value
    }

    func end() {
        task?.cancel(); task = nil; metricsTask?.cancel(); metricsTask = nil
        token = UUID(); formatEvents = []
        status = MediaExperienceStatus()
        status.deviceDetail = Self.deviceDescription()
        status.limitations = Self.limitations
        videoPermission = .inspectSDRFrames
    }

    /// The system audio policy: keep the source's own tracks, inject no mix, never downmix.
    func applyAudioPolicy(item: AVPlayerItem, spatializationEnabled: Bool) {
        item.allowedAudioSpatializationFormats = (spatializationEnabled && !keepsOriginalLayout) ? .multichannel : []
        item.audioMix = nil
        var value = status
        value.audioSpatialization = item.allowedAudioSpatializationFormats.isEmpty ? "保持原声布局（不请求空间化）" : "已请求多声道空间化"
        status = value
    }

    /// Inspection is deliberately passive. It reads what the player item already exposes instead of
    /// asking the same HTTP URL for metadata again: several parallel asset loads against one source
    /// compete for the same limited connections and can break the playback transport itself.
    private func inspect(item: AVPlayerItem, token: UUID) async {
        // Playback preparation may still be running; one short wait avoids reporting "unknown"
        // for a source that exposes its tracks a moment later, without loading anything again.
        for attempt in 0..<8 {
            if Self.readableVideoFormat(of: item) != nil || Self.readableAudioFormat(of: item) != nil { break }
            if attempt == 0 { applyVideo(format: nil); applyAudio(format: nil, selectedName: nil) }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard self.token == token, !Task.isCancelled else { return }
        }
        applyVideo(format: Self.readableVideoFormat(of: item))
        guard self.token == token, !Task.isCancelled else { return }
        applyAudio(format: Self.readableAudioFormat(of: item), selectedName: nil)
    }

    static func readableVideoFormat(of item: AVPlayerItem) -> CMFormatDescription? {
        format(of: item, mediaType: .video)
    }

    static func readableAudioFormat(of item: AVPlayerItem) -> CMFormatDescription? {
        format(of: item, mediaType: .audio)
    }

    /// Reads only `AVPlayerItem.tracks`, which is already in memory. `AVAsset.tracks` is the
    /// deprecated synchronous accessor: on a network asset it performs a blocking load and can
    /// break the very playback it is describing. Tracks that are not loaded yet are reported as
    /// unknown and left to the per-frame colour gate.
    private static func format(of item: AVPlayerItem, mediaType: AVMediaType) -> CMFormatDescription? {
        for itemTrack in item.tracks where itemTrack.assetTrack?.mediaType == mediaType {
            for value in itemTrack.assetTrack?.formatDescriptions ?? [] {
                if CFGetTypeID(value as CFTypeRef) == CMFormatDescriptionGetTypeID() { return (value as! CMFormatDescription) }
            }
        }
        return nil
    }

    private func applyVideo(format: CMFormatDescription?) {
        var value = status
        guard let format else {
            value.videoDetail = "当前片源未暴露视频格式（常见于 HLS），由逐帧色彩门禁判断"
            value.nativePlayback = false
            status = value
            videoPermission = .inspectSDRFrames
            return
        }
        let subtype = Self.fourCC(CMFormatDescriptionGetMediaSubType(format))
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        var atoms: [String: Any] = [:]
        if let nested = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] { atoms = nested }
        var profile: DolbyVisionConfiguration?
        for name in ["dvcC", "dvvC"] {
            if let payload = atoms[name] as? Data, let decoded = DolbyMetadata.dolbyVisionProfile(payload) { profile = decoded }
        }
        let transfer = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction).map { String(describing: $0) })?.uppercased()
        let primaries = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries).map { String(describing: $0) })?.uppercased()
        let isDolbyVision = subtype == "dvh1" || subtype == "dvhe" || profile != nil
        let isHDR = isDolbyVision || transfer?.contains("2084") == true || transfer?.contains("2100_HLG") == true || primaries?.contains("2020") == true
        value.videoDetail = "\(dimensions.width)×\(dimensions.height) · \(subtype)\(transfer.map { " · \($0)" } ?? " · 未标记传输函数")"
        value.videoIsDolbyVision = isDolbyVision
        value.videoIsHDR = isHDR
        value.nativePlayback = isHDR
        if let profile { value.videoDetail += " · Dolby Vision profile \(profile.profile) level \(profile.level)" }
        status = value
        videoPermission = isHDR ? .nativeOnly(isDolbyVision ? "当前视频轨道为 Dolby Vision，保留系统原生呈现" : "当前视频轨道为 HDR，保留系统原生呈现") : .inspectSDRFrames
    }

    /// Called by `PlaybackController` with the group it already loaded for its own track menu, so no
    /// second `loadMediaSelectionGroup` request is issued for the same item.
    /// Called by `PlaybackController` with the selection group it already loaded for its own track
    /// menu, so no second request is issued for the same item.
    func attach(item: AVPlayerItem, selected: AVMediaSelectionOption?) {
        applyAudio(format: Self.readableAudioFormat(of: item), selectedName: selected?.displayName)
    }

    private func applyAudio(format: CMFormatDescription?, selectedName: String?) {
        var value = status
        var channels = 0
        var layoutIsAtmos = false
        var detail = selectedName ?? "默认音轨"
        if let format {
            let subtype = Self.fourCC(CMFormatDescriptionGetMediaSubType(format))
            if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) { channels = Int(description.pointee.mChannelsPerFrame) }
            if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: nil), let pointer = layout.pointee.mChannelLayoutTag as AudioChannelLayoutTag? {
                layoutIsAtmos = Self.isAtmosLayout(pointer)
            }
            var joc = false
            let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
            if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] {
                for name in ["dec3", "dac3", "dec3Box"] {
                    if let payload = atoms[name] as? Data, DolbyMetadata.hasAtmosEC3Configuration(payload) { joc = true }
                }
            }
            value.audioIsAtmos = joc || layoutIsAtmos
            detail = "\(subtype)\(channels > 0 ? " · \(channels) 声道" : "")"
            if value.audioIsAtmos { detail += layoutIsAtmos ? " · CoreAudio 报告 Atmos 布局" : " · E-AC-3 JOC 扩展" }
            else if channels > 2 { detail += " · 多声道（不代表 Atmos）" }
        }
        value.audioChannelCount = channels
        value.audioDetail = detail
        status = value
        formatEvents.append("音轨 \(detail)")
    }

    private func observeMetrics(item: AVPlayerItem, token: UUID) {
        metricsTask = Task { [weak self, weak item] in
            guard let item else { return }
            do {
                for try await event in item.metrics(forType: AVMetricPlayerItemVariantSwitchEvent.self) {
                    guard let self, self.token == token, !Task.isCancelled else { return }
                    let video = event.toVariant.videoAttributes
                    let range = video.map { Self.videoRangeName($0.videoRange) } ?? "未声明"
                    let size = video.map { "\(Int($0.presentationSize.width))×\(Int($0.presentationSize.height))" } ?? "尺寸未声明"
                    let audio = event.toVariant.audioAttributes.map { " · \($0.formatIDs.map { Self.fourCC($0) }.joined(separator: ","))" } ?? ""
                    self.formatEvents.append("切换 \(event.didSucceed ? "成功" : "失败") · \(size) · \(range)\(audio)")
                    var value = self.status
                    value.variantEvents = Array(self.formatEvents.suffix(4))
                    self.status = value
                }
            } catch { /* Metric streams are unavailable on some items. */ }
        }
    }

    static func videoRangeName(_ range: AVVideoRange) -> String {
        switch range {
        case .sdr: return "SDR"
        case .pq: return "PQ（HDR10/Dolby Vision）"
        case .hlg: return "HLG"
        default: return "未知范围（\(range.rawValue)）"
        }
    }

    /// CoreAudio publishes the Atmos speaker layouts this Mac can render.
    static func isAtmosLayout(_ tag: AudioChannelLayoutTag) -> Bool {
        [kAudioChannelLayoutTag_Atmos_5_1_2, kAudioChannelLayoutTag_Atmos_5_1_4, kAudioChannelLayoutTag_Atmos_7_1_2,
         kAudioChannelLayoutTag_Atmos_7_1_4, kAudioChannelLayoutTag_Atmos_9_1_6].contains(tag)
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
    }

    static var limitations: [String] {
        ["硬件支持不等于正在输出杜比：这里显示的是片源与所选轨道，不是扬声器或屏幕的认证结果",
         "未能测量扬声器 DSP、房间校准与杜比认证状态",
         "SDR 增强与双声道空间化不会被标为杜比"]
    }

    static func deviceDescription() -> String {
        let screens = NSScreen.screens
        let hdr = AVPlayer.eligibleForHDRPlayback ? "系统允许 HDR 播放" : "系统未报告 HDR 播放能力"
        var edr = "屏幕 EDR 未知"
        if let screen = screens.first {
            let current = screen.maximumExtendedDynamicRangeColorComponentValue
            let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
            edr = "\(screen.localizedName) 当前 EDR \(String(format: "%.2f", current))（上限 \(String(format: "%.2f", potential))）"
        }
        return "\(hdr) · \(edr) · 输出设备 \(outputDeviceName())"
    }

    static func outputDeviceName() -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return "未知" }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return "未知" }
        // CoreAudio documents kAudioObjectPropertyName as caller-owned.
        return name.takeRetainedValue() as String
    }
}
