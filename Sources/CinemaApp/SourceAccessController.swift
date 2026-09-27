import SwiftUI
import CFNetwork
import Darwin
import CinemaCore

/// Results are session-only: a past successful request is not a live guarantee.
@MainActor
final class SourceAccessController: ObservableObject {
    @Published private(set) var reports: [String: SourceAccessReport] = [:]
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var running: Set<String> = []
    @Published private(set) var networkNotice = "检测排除 HTTP 代理，但仍受系统 VPN 与 DNS 影响；大陆直连需另行确认。"
    private var queue: [SourceProvider] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]
    // Injectable for deterministic queue/cancellation checks without real traffic.
    var probe: (SourceProvider) async throws -> SourceAccessReport = { provider in
        try await SourceAccessProbe().check(provider: provider)
    }

    func check(_ providers: [SourceProvider]) {
        refreshNetworkNotice()
        for provider in providers where !pending.contains(provider.id) {
            pending.insert(provider.id)
            reports.removeValue(forKey: provider.id)
            queue.append(provider)
        }
        startQueued()
    }
    func cancelAll() {
        tokens.removeAll(); queue.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        pending.removeAll(); running.removeAll()
    }
    func remove(_ id: String) {
        tokens.removeValue(forKey: id)
        queue.removeAll { $0.id == id }
        tasks.removeValue(forKey: id)?.cancel()
        pending.remove(id); running.remove(id); reports.removeValue(forKey: id)
        startQueued()
    }
    private func startQueued() {
        while tasks.count < 3, !queue.isEmpty {
            let provider = queue.removeFirst(), token = UUID(), check = probe
            tokens[provider.id] = token; running.insert(provider.id)
            tasks[provider.id] = Task { [weak self] in
                let result = try? await check(provider)
                guard let self, self.tokens[provider.id] == token else { return }
                if !Task.isCancelled, let result { self.reports[provider.id] = result }
                self.tokens.removeValue(forKey: provider.id)
                self.tasks.removeValue(forKey: provider.id)
                self.pending.remove(provider.id); self.running.remove(provider.id)
                self.startQueued()
            }
        }
    }
    func refreshNetworkNotice() {
        let proxy = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        let hasProxy = [kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable,
                        kCFNetworkProxiesSOCKSEnable, kCFNetworkProxiesProxyAutoConfigEnable,
                        kCFNetworkProxiesProxyAutoDiscoveryEnable].contains { (proxy[$0 as String] as? NSNumber)?.boolValue == true }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        var hasTunnel = false
        if getifaddrs(&interfaces) == 0 {
            defer { freeifaddrs(interfaces) }
            var cursor = interfaces
            while let item = cursor {
                let name = String(cString: item.pointee.ifa_name)
                if item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                   ["utun", "tun", "tap", "ppp", "ipsec"].contains(where: name.hasPrefix) { hasTunnel = true }
                cursor = item.pointee.ifa_next
            }
        }
        networkNotice = hasProxy || hasTunnel
            ? "检测到系统代理或隧道迹象。媒体检测会排除 HTTP 代理，但仍可能经过 VPN；结果不等于大陆直连。"
            : "未发现常见系统代理或隧道迹象。请在大陆网络关闭 VPN 后检测；成功结果仅代表这次样本可读取。"
    }
}
