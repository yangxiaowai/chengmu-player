import AVFoundation
import Foundation

/// Track/prepared-item metadata, or a single decoded frame when HLS does not
/// expose dimensions earlier. Neither establishes perceptual quality or full playback.
public struct MediaQualitySample: Codable, Hashable, Sendable {
    public enum Evidence: String, Codable, Hashable, Sendable { case track, firstFrame }
    public let width: Int
    public let height: Int
    public let frameRate: Double?
    public let codec: String?
    public let estimatedBitrate: Double?
    public let evidence: Evidence

    public init(width: Int, height: Int, frameRate: Double? = nil,
                codec: String? = nil, estimatedBitrate: Double? = nil, evidence: Evidence = .track) {
        let validDimensions = (1...16_384).contains(width) && (1...16_384).contains(height)
        self.width = validDimensions ? width : 0
        self.height = validDimensions ? height : 0
        self.frameRate = frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let cleanCodec = codec?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.codec = cleanCodec.flatMap { $0.isEmpty ? nil : $0 }
        self.estimatedBitrate = estimatedBitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.evidence = evidence
    }

    public var dimensionsLabel: String { pixelCount > 0 ? "\(width)×\(height)" : "尺寸未知" }
    public var pixelCount: Int64 { Int64(width) * Int64(height) }

    /// Only exact standard raster pairs receive a familiar label. In particular,
    /// a 3840×1600 cinema frame must not be called 2160p because of its width.
    public var resolutionLabel: String {
        let standard: [Int: Int] = [640: 360, 854: 480, 1280: 720, 1920: 1080,
                                    2560: 1440, 3840: 2160, 7680: 4320]
        guard pixelCount > 0, standard[width] == height else { return dimensionsLabel }
        return "\(height)p · \(dimensionsLabel)"
    }

    public var summary: String {
        var parts = [resolutionLabel, evidence == .firstFrame ? "首帧读取" : "轨道读取"]
        if let frameRate { parts.append("\(Self.decimal(frameRate, digits: 3)) fps") }
        else { parts.append("帧率未读到") }
        if let codec { parts.append(codec) }
        if let estimatedBitrate {
            parts.append("估算 \(Self.decimal(estimatedBitrate / 1_000_000, digits: 2)) Mbps")
        }
        return parts.joined(separator: " · ")
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        let text = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
        return text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private enum CodingKeys: String, CodingKey { case width, height, frameRate, codec, estimatedBitrate, evidence }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try values.decode(Int.self, forKey: .width),
                  height: try values.decode(Int.self, forKey: .height),
                  frameRate: try values.decodeIfPresent(Double.self, forKey: .frameRate),
                  codec: try values.decodeIfPresent(String.self, forKey: .codec),
                  estimatedBitrate: try values.decodeIfPresent(Double.self, forKey: .estimatedBitrate),
                  evidence: try values.decodeIfPresent(Evidence.self, forKey: .evidence) ?? .track)
    }
}

public struct MediaQualityProbe: Sendable {
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 8) : 8
    }

    public func inspect(url: URL) async throws -> MediaQualitySample {
        try Task.checkCancellation()
        guard Self.accepts(url) else { throw ProbeFailure.invalidURL }
        // A separate asset per inspection prevents cancellation of one episode
        // from invalidating another caller's metadata read.
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            defer { asset.cancelLoading() }
            do {
                return try await withThrowingTaskGroup(of: MediaQualitySample.self) { group in
                    defer { group.cancelAll() }
                    group.addTask {
                        do { return try await Self.read(asset: asset) }
                        catch ProbeFailure.noVideo {
                            try Task.checkCancellation()
                            return try await Self.readPreparedItem(asset: asset)
                        }
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        // Cancelling just the Swift child is insufficient for a
                        // server that accepts a request and never returns bytes.
                        asset.cancelLoading()
                        throw ProbeFailure.timedOut
                    }
                    guard let value = try await group.next() else { throw ProbeFailure.noVideo }
                    try Task.checkCancellation()
                    return value
                }
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func accepts(_ url: URL) -> Bool {
        if url.isFileURL { return url.host == nil || url.host == "" || url.host == "localhost" }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !host.contains(where: { $0.isWhitespace }), url.fragment == nil else { return false }
        if let port = url.port, !(1...65_535).contains(port) { return false }
        return true
    }

    private static func read(asset: AVURLAsset) async throws -> MediaQualitySample {
        try Task.checkCancellation()
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProbeFailure.noVideo
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        guard [size.width, size.height, transform.a, transform.b, transform.c,
               transform.d, transform.tx, transform.ty].allSatisfy({ $0.isFinite }),
              size.width > 0, size.height > 0,
              size.width <= 16_384, size.height <= 16_384 else { throw ProbeFailure.invalidDimensions }
        let displayed = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        guard displayed.width.isFinite, displayed.height.isFinite,
              displayed.width >= 1, displayed.height >= 1,
              displayed.width <= 16_384, displayed.height <= 16_384 else { throw ProbeFailure.invalidDimensions }
        return try await metadata(track: track, size: displayed, evidence: .track)
    }

    private static func metadata(track: AVAssetTrack?, size: CGSize,
                                 evidence: MediaQualitySample.Evidence) async throws -> MediaQualitySample {
        let fps = try? await track?.load(.nominalFrameRate)
        let bitrate = try? await track?.load(.estimatedDataRate)
        let descriptions = try? await track?.load(.formatDescriptions)
        try Task.checkCancellation()
        return MediaQualitySample(width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                                  frameRate: fps.map(Double.init),
                                  codec: descriptions?.first.flatMap { fourCC(CMFormatDescriptionGetMediaSubType($0)) },
                                  estimatedBitrate: bitrate.map(Double.init), evidence: evidence)
    }

    /// HLS frequently exposes no AVAssetTrack until an item has been prepared.
    /// This private player never attaches to a view, stays muted, and is torn
    /// down before the task group can finish, including cancellation/timeout.
    @MainActor
    private static func readPreparedItem(asset: AVURLAsset) async throws -> MediaQualitySample {
        try Task.checkCancellation()
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0.15
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.suppressesPlayerRendering = true
        item.add(output)
        let player = AVPlayer()
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            item.remove(output)
            asset.cancelLoading()
        }
        player.replaceCurrentItem(with: item)
        let started = ContinuousClock.now
        var readingFirstFrame = false
        while true {
            try Task.checkCancellation()
            if item.status == .failed { throw item.error ?? ProbeFailure.noVideo }
            let videoTrack = item.tracks.compactMap(\.assetTrack).first { $0.mediaType == .video }
            let size = item.presentationSize
            if item.status == .readyToPlay, valid(size: size), !readingFirstFrame {
                return try await metadata(track: videoTrack, size: size, evidence: .track)
            }
            if !readingFirstFrame, started.duration(to: .now) >= .milliseconds(1500) {
                // Some HLS engines only populate presentationSize after a first
                // sample. Decode at most until one output buffer is obtained.
                readingFirstFrame = true
                player.playImmediately(atRate: 1)
            }
            if readingFirstFrame {
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    let pixels = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                    guard valid(size: pixels) else { throw ProbeFailure.invalidDimensions }
                    player.pause()
                    return try await metadata(track: videoTrack, size: pixels, evidence: .firstFrame)
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func valid(size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1 &&
            size.width <= 16_384 && size.height <= 16_384
    }

    private static func fourCC(_ value: FourCharCode) -> String? {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                     UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    private enum ProbeFailure: LocalizedError {
        case invalidURL, timedOut, noVideo, invalidDimensions
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "媒体地址无效"
            case .timedOut: return "画质元数据检测超时"
            case .noVideo: return "未读取到视频轨道元数据"
            case .invalidDimensions: return "视频尺寸元数据无效"
            }
        }
    }
}
