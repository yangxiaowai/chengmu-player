import SwiftUI
import CinemaCore

enum AdSelectionTool: String, CaseIterable, Identifiable {
    case advertisement = "框选广告", subtitle = "保护字幕"
    var id: String { rawValue }
}

struct AdCleanupCanvas: View {
    @Binding var draft: AdCleanupSettings
    let tool: AdSelectionTool
    let videoSize: CGSize
    @Binding var notice: String?
    @LegacyState private var candidate: NormalizedVideoRect?

    var body: some View {
        GeometryReader { geometry in
            let frame = VideoSelectionGeometry.fittedRect(video: videoSize, container: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                ForEach(Array(draft.protectedRegions.enumerated()), id: \.offset) { index, region in
                    outline(region, in: frame, color: .green, label: index == 0 ? "字幕保护 · 底部 28%" : "字幕保护 \(index)")
                }
                ForEach(Array(draft.regions.enumerated()), id: \.offset) { index, region in
                    let blocked = AdCleanupPolicy.rejectionReason(for: region, protectedRegions: draft.protectedRegions, width: Int(videoSize.width), height: Int(videoSize.height)) != nil
                    outline(region, in: frame, color: blocked ? .red : CinemaStyle.accent, label: "广告 \(index + 1)" + (blocked ? " · 与保护区冲突" : ""))
                }
                if let candidate { outline(candidate, in: frame, color: tool == .subtitle ? .green : CinemaStyle.accent, label: "松开完成框选") }
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in candidate = VideoSelectionGeometry.selection(from: value.startLocation, to: value.location, videoRect: frame) }
                .onEnded { value in
                    defer { candidate = nil }
                    guard let region = VideoSelectionGeometry.selection(from: value.startLocation, to: value.location, videoRect: frame) else {
                        notice = "请从影片画面内拖出一个矩形，黑边和单击不会添加选区。"; return
                    }
                    if tool == .advertisement {
                        guard draft.regions.count < AdCleanupPolicy.maxAdRegions else { notice = "最多添加 6 个广告框，可先移除已有框。"; return }
                        if let reason = AdCleanupPolicy.rejectionReason(for: region, protectedRegions: draft.protectedRegions, width: Int(videoSize.width), height: Int(videoSize.height)) { notice = reason; return }
                        draft.regions.append(region)
                        notice = "已添加广告框。请确认其中没有字幕，再应用柔化。"
                    } else {
                        guard draft.protectedRegions.count < AdCleanupPolicy.maxProtectedRegions else { notice = "最多另加 6 个字幕保护框。"; return }
                        draft.protectedRegions.append(region)
                        notice = "已保护此处字幕。若已有广告框变红，请先移除冲突广告框。"
                    }
                })
        }.accessibilityLabel("广告与字幕区域编辑画布")
            .accessibilityHint("拖动框选；绿色区域保护字幕，黄色区域局部柔化，红色表示冲突。可在下方移除各个框。")
    }
    private func outline(_ region: NormalizedVideoRect, in frame: CGRect, color: Color, label: String) -> some View {
        let rect = CGRect(x: frame.minX + region.x * frame.width, y: frame.minY + region.y * frame.height, width: region.width * frame.width, height: region.height * frame.height)
        return Rectangle().fill(color.opacity(0.13))
            .overlay(Rectangle().strokeBorder(color.opacity(0.95), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
            .overlay(alignment: .topLeading) { Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(4).background(color.opacity(0.7)).lineLimit(1) }
            .frame(width: max(0, rect.width), height: max(0, rect.height)).offset(x: rect.minX, y: rect.minY).allowsHitTesting(false)
    }
}

struct AdCleanupControls: View {
    @Binding var draft: AdCleanupSettings
    @Binding var tool: AdSelectionTool
    let videoSize: CGSize
    @Binding var notice: String?
    let onCancel: () -> Void
    let onApply: () -> Void

    private var blocked: Bool {
        draft.regions.contains { AdCleanupPolicy.rejectionReason(for: $0, protectedRegions: draft.protectedRegions, width: Int(videoSize.width), height: Int(videoSize.height)) != nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Picker("框选类型", selection: $tool) { ForEach(AdSelectionTool.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 230)
                Spacer(minLength: 4)
                Button("取消") { onCancel() }
                Button("应用柔化") { onApply() }.buttonStyle(.borderedProminent).disabled(draft.regions.isEmpty || blocked || videoSize.width <= 0 || videoSize.height <= 0)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(draft.regions.indices, id: \.self) { index in
                        Button { draft.regions.remove(at: index); notice = nil } label: { Label("广告 \(index + 1)", systemImage: "xmark.circle") }
                            .help("移除此广告框").foregroundStyle(CinemaStyle.accent)
                    }
                    ForEach(draft.protectedRegions.indices.filter { $0 > 0 }, id: \.self) { index in
                        Button { draft.protectedRegions.remove(at: index); notice = nil } label: { Label("字幕保护 \(index)", systemImage: "xmark.circle") }
                            .help("移除此附加保护框").foregroundStyle(.green)
                    }
                    Button("清空广告框") { draft.regions = []; notice = nil }.disabled(draft.regions.isEmpty)
                }.font(.system(size: 11)).buttonStyle(.borderless)
            }
            Text("底部 28% 默认保护。顶部、中部或双语字幕请另外框选保护；不确定的区域保留原画面。这里只柔化所选区域，不还原被遮住的背景。").font(.system(size: 11)).foregroundStyle(CinemaStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if blocked { Text("广告框与字幕保护区冲突，请移除红色广告框后应用。").font(.system(size: 11)).foregroundStyle(.red) }
            else if let notice { Text(notice).font(.system(size: 11)).foregroundStyle(CinemaStyle.accent).fixedSize(horizontal: false, vertical: true) }
        }.padding(18).background(CinemaStyle.panel)
    }
}
