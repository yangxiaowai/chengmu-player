import Foundation
import AVFoundation
import AppKit
import CoreMedia
import CoreAudio

// Independent, muted AVPlayer. No windows, media library, user defaults, or application state.
@main struct OfficialDolbyProbe {
    @MainActor static func main() async {
        guard CommandLine.arguments.count >= 2 else { exit(2) }
        let report = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8")!
        let started = Date()
        let deadline = started.addingTimeInterval(20)
        let asset = AVURLAsset(url: source)
        let item = AVPlayerItem(asset: asset)
        item.allowedAudioSpatializationFormats = .multichannel
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        player.isMuted = true; player.volume = 0
        let layer = AVPlayerLayer(player: player)
        layer.frame = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        var result: [String: Any] = [
            "checkedAt": ISO8601DateFormatter().string(from: started),
            "source": source.absoluteString,
            "officialSourcePage": "https://developer.apple.com/streaming/examples/advanced-stream-dv-atmos.html",
            "eligibleForHDRPlayback": AVPlayer.eligibleForHDRPlayback,
            "screens": NSScreen.screens.map { ["name": $0.localizedName, "edrCurrent": $0.maximumExtendedDynamicRangeColorComponentValue, "edrPotential": $0.maximumPotentialExtendedDynamicRangeColorComponentValue] as [String: Any] },
            "outputDevice": outputDeviceName(),
            "muted": true, "spatializationPolicy": "multichannel",
            "windowCreated": false, "onScreenHDRVerified": false, "audibleAtmosVerified": false,
            "scope": "Real independent AVPlayer with official streaming sample; input selection and metadata evidence only. Muted and no window; does not prove screen rendering or speaker Atmos output. No media file is saved."
        ]
        var finished = false
        var metricEvents: [[String: Any]] = []
        var trackSnapshots: [[String: Any]] = []
        var states: [[String: Any]] = []
        var tasks: [Task<Void, Never>] = []
        tasks.append(Task { @MainActor in
            do {
                let variants = try await asset.load(.variants)
                guard !finished, !Task.isCancelled else { return }
                result["variants"] = variants.map(variantValue)
            } catch { if !finished { result["variantLoadError"] = String(describing: error) } }
        })
        tasks.append(Task { @MainActor in
            do {
                guard let group = try await asset.loadMediaSelectionGroup(for: .audible), !finished, !Task.isCancelled else { return }
                result["audioOptions"] = group.options.map(optionValue)
                if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
                    result["selectedAudioOptionAtLoad"] = optionValue(selected)
                }
            } catch { if !finished { result["audioGroupError"] = String(describing: error) } }
        })
        tasks.append(Task { @MainActor in
            do {
                for try await event in item.metrics(forType: AVMetricPlayerItemVariantSwitchEvent.self) {
                    guard !finished, !Task.isCancelled else { return }
                    var value: [String: Any] = ["elapsedSeconds": Date().timeIntervalSince(started), "didSucceed": event.didSucceed, "toVariant": variantValue(event.toVariant)]
                    if let from = event.fromVariant { value["fromVariant"] = variantValue(from) }
                    if #available(macOS 26.0, *) {
                        value["audioRenditionURL"] = event.audioRendition.url?.absoluteString ?? NSNull() as Any
                        value["videoRenditionURL"] = event.videoRendition.url?.absoluteString ?? NSNull() as Any
                    }
                    metricEvents.append(value)
                }
            } catch { if !finished { result["metricsError"] = String(describing: error) } }
        })
        player.play()
        var nextSnapshot = Date.distantPast
        while Date() < deadline {
            if Date() >= nextSnapshot {
                nextSnapshot = Date().addingTimeInterval(2)
                states.append(["elapsedSeconds": Date().timeIntervalSince(started), "itemStatus": status(item.status), "transport": transport(player.timeControlStatus), "position": finite(player.currentTime().seconds), "rate": player.rate])
                let snapshotTracks = item.tracks
                tasks.append(Task { @MainActor in
                    var values: [[String: Any]] = []
                    for itemTrack in snapshotTracks {
                        guard let track = itemTrack.assetTrack else { continue }
                        do {
                            let formats = try await track.load(.formatDescriptions)
                            let characteristics = try await track.load(.mediaCharacteristics)
                            guard !finished, !Task.isCancelled else { return }
                            values.append(["enabled": itemTrack.isEnabled, "trackID": track.trackID, "mediaType": track.mediaType.rawValue, "containsHDRVideo": characteristics.contains(.containsHDRVideo), "formats": formats.map(formatValue)])
                        } catch { if !finished { values.append(["error": String(describing: error)]) } }
                    }
                    guard !finished else { return }
                    if !values.isEmpty { trackSnapshots.append(["elapsedSeconds": Date().timeIntervalSince(started), "tracks": values]) }
                })
            }
            if item.status == .failed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        finished = true
        result["elapsedSeconds"] = Date().timeIntervalSince(started)
        result["finalItemStatus"] = status(item.status)
        result["finalTransport"] = transport(player.timeControlStatus)
        result["finalPosition"] = finite(player.currentTime().seconds)
        result["finalPresentationSize"] = ["width": item.presentationSize.width, "height": item.presentationSize.height]
        result["readyAndAdvanced"] = item.status == .readyToPlay && player.currentTime().seconds > 1
        result["itemError"] = item.error.map { String(describing: $0) } ?? NSNull() as Any
        result["metrics"] = metricEvents
        result["trackSnapshots"] = trackSnapshots
        result["states"] = states
        result["accessLog"] = (item.accessLog()?.events ?? []).map { ["uri": $0.uri ?? "", "indicatedBitrate": finite($0.indicatedBitrate), "observedBitrate": finite($0.observedBitrate), "numberOfDroppedVideoFrames": $0.numberOfDroppedVideoFrames] as [String: Any] }
        result["errorLog"] = (item.errorLog()?.events ?? []).map { ["errorStatusCode": $0.errorStatusCode, "errorDomain": $0.errorDomain, "errorComment": $0.errorComment ?? "", "uri": $0.uri ?? ""] as [String: Any] }
        tasks.forEach { $0.cancel() }
        asset.cancelLoading(); player.pause(); layer.player = nil; player.replaceCurrentItem(with: nil)
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: report, options: .atomic)
            print("Saved \(report.path); status=\(result["finalItemStatus"]!), position=\(result["finalPosition"]!), metricEvents=\(metricEvents.count), trackSnapshots=\(trackSnapshots.count)")
        } catch { fputs("Report failed: \(error)\n", stderr); exit(1) }
    }

    static func finite(_ value: Double) -> Any { value.isFinite ? value : NSNull() }
    static func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
    }
    static func status(_ value: AVPlayerItem.Status) -> String { switch value { case .readyToPlay: return "ready"; case .failed: return "failed"; default: return "unknown" } }
    static func transport(_ value: AVPlayer.TimeControlStatus) -> String { switch value { case .playing: return "playing"; case .waitingToPlayAtSpecifiedRate: return "waiting"; default: return "paused" } }
    static func optionValue(_ option: AVMediaSelectionOption) -> [String: Any] {
        ["displayName": option.displayName, "mediaSubTypes": option.mediaSubTypes.map { fourCC($0.uint32Value) }, "language": option.extendedLanguageTag ?? "", "playable": option.isPlayable]
    }
    static func variantValue(_ variant: AVAssetVariant) -> [String: Any] {
        var value: [String: Any] = ["peakBitRate": variant.peakBitRate.map { finite($0) } ?? NSNull() as Any, "averageBitRate": variant.averageBitRate.map { finite($0) } ?? NSNull() as Any]
        if let video = variant.videoAttributes { value["video"] = ["codecs": video.codecTypes.map { fourCC($0) }, "range": video.videoRange.rawValue, "width": video.presentationSize.width, "height": video.presentationSize.height, "fps": video.nominalFrameRate.map { finite($0) } ?? NSNull() as Any] }
        if let audio = variant.audioAttributes { value["audioFormatIDs"] = audio.formatIDs.map { fourCC($0) } }
        if #available(macOS 26.0, *) { value["url"] = variant.url.absoluteString }
        return value
    }
    static func formatValue(_ format: CMFormatDescription) -> [String: Any] {
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        var value: [String: Any] = ["codec": fourCC(CMFormatDescriptionGetMediaSubType(format)), "extensionKeys": extensions.keys.sorted()]
        for key in [kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_YCbCrMatrix] {
            if let content = CMFormatDescriptionGetExtension(format, extensionKey: key) { value[key as String] = String(describing: content) }
        }
        if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] {
            value["atomKeys"] = atoms.keys.sorted()
            for name in ["dec3", "dvcC", "dvvC"] {
                if let data = atoms[name] as? Data { value[name + "Bytes"] = data.count; value[name + "Hex"] = data.prefix(128).map { String(format: "%02x", $0) }.joined() }
            }
        }
        if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio, let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            value["audioChannelCount"] = audio.pointee.mChannelsPerFrame; value["audioSampleRate"] = audio.pointee.mSampleRate
            var count = 0
            if let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &count), count > 0 {
                value["magicCookieBytes"] = count
                value["magicCookieHexPrefix"] = Data(bytes: cookie, count: min(count, 128)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return value
    }
    static func outputDeviceName() -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return "unknown" }
        address.mSelector = kAudioObjectPropertyName
        var name: CFString = "unknown" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "unknown" }
        return name as String
    }
}
