import AppKit
import SwiftUI

struct ProcessRow: Identifiable {
    let id: Int
    let name: String
    let cpu: Double
    let rss: Int64
}

struct SkillRow: Identifiable {
    let name: String
    let source: String
    let description: String
    var id: String { "\(source):\(name)" }
}

struct MCPRow: Identifiable {
    let name: String
    let enabled: Bool
    let transport: String
    let endpoint: String
    var id: String { name }
}

struct ServerRow: Identifiable {
    let host: String
    let port: String
    let processes: String
    let connectionCount: Int
    var id: String { "\(host):\(port)" }
}

struct MonitorSnapshot {
    var collectedAt = ""
    var processCount = 0
    var connectionCount = 0
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var totalTokens: Int64 = 0
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cachedTokens: Int64 = 0
    var sessionCount = 0
    var primaryRemaining: Double?
    var secondaryRemaining: Double?
    var primaryEstimated = false
    var secondaryEstimated = false
    var balance = "不可用"
    var processes: [ProcessRow] = []
    var skills: [SkillRow] = []
    var mcpServers: [MCPRow] = []
    var externalServers: [ServerRow] = []
    var warningCount = 0
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var snapshot = MonitorSnapshot()
    @Published var error: String?
    @Published var lastLoaded = Date.distantPast
    private var timer: Timer?
    private var isCollecting = false
    private let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex-monitor/latest.json")

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isCollecting else { return }
        guard let scriptURL = Bundle.main.url(forResource: "codex_monitor", withExtension: "py") else {
            error = "应用内缺少采集器，请重新安装"
            return
        }
        isCollecting = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path, "collect-once"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isCollecting = false
                    if process.terminationStatus == 0 {
                        self.load()
                    } else {
                        self.error = "本地采集失败（退出码 \(process.terminationStatus)）"
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isCollecting = false
                    self?.error = "无法启动本地采集器：\(error.localizedDescription)"
                }
            }
        }
    }

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "CodexMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "快照格式无效"])
            }
            snapshot = parse(root)
            error = nil
            lastLoaded = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openDataFolder() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-monitor")
        NSWorkspace.shared.open(url)
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func parse(_ root: [String: Any]) -> MonitorSnapshot {
        var result = MonitorSnapshot()
        result.collectedAt = root["collected_at"] as? String ?? ""
        let processes = root["processes"] as? [[String: Any]] ?? []
        let connections = root["connections"] as? [[String: Any]] ?? []
        let traffic = root["traffic"] as? [String: Any] ?? [:]
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        let totals = tokens["totals"] as? [String: Any] ?? [:]
        let telemetry = tokens["latest_telemetry"] as? [String: Any] ?? [:]
        let limits = telemetry["rate_limits"] as? [String: Any] ?? [:]
        let primary = limits["primary"] as? [String: Any] ?? [:]
        let secondary = limits["secondary"] as? [String: Any] ?? [:]
        let credits = limits["credits"] as? [String: Any] ?? [:]
        result.processCount = processes.count
        result.connectionCount = connections.count
        result.bytesIn = Int64(number(traffic["bytes_in"]) ?? 0)
        result.bytesOut = Int64(number(traffic["bytes_out"]) ?? 0)
        result.totalTokens = Int64(number(totals["total_tokens"]) ?? 0)
        result.inputTokens = Int64(number(totals["input_tokens"]) ?? 0)
        result.outputTokens = Int64(number(totals["output_tokens"]) ?? 0)
        result.cachedTokens = Int64(number(totals["cached_input_tokens"]) ?? 0)
        result.sessionCount = Int(number(tokens["session_count"]) ?? 0)
        let primaryUsed = number(primary["effective_used_percent"] ?? primary["used_percent"])
        let secondaryUsed = number(secondary["effective_used_percent"] ?? secondary["used_percent"])
        result.primaryRemaining = number(primary["remaining_percent"]) ?? primaryUsed.map { max(0, 100 - $0) }
        result.secondaryRemaining = number(secondary["remaining_percent"]) ?? secondaryUsed.map { max(0, 100 - $0) }
        result.primaryEstimated = primary["estimated_after_reset"] as? Bool ?? false
        result.secondaryEstimated = secondary["estimated_after_reset"] as? Bool ?? false
        if let balance = credits["balance"], !(balance is NSNull) {
            result.balance = String(describing: balance)
        }
        result.warningCount = (root["warnings"] as? [Any])?.count ?? 0
        result.processes = processes.compactMap { item in
            guard let pid = number(item["pid"]) else { return nil }
            return ProcessRow(
                id: Int(pid),
                name: item["executable"] as? String ?? "process",
                cpu: number(item["cpu_percent"]) ?? 0,
                rss: Int64(number(item["rss_bytes"]) ?? 0)
            )
        }.sorted { $0.cpu > $1.cpu }
        let skills = root["skills"] as? [[String: Any]] ?? []
        result.skills = skills.map { item in
            SkillRow(
                name: item["name"] as? String ?? "unnamed",
                source: item["source"] as? String ?? "unknown",
                description: item["description"] as? String ?? ""
            )
        }
        let mcp = root["mcp_servers"] as? [[String: Any]] ?? []
        result.mcpServers = mcp.map { item in
            MCPRow(
                name: item["name"] as? String ?? "unnamed",
                enabled: item["enabled"] as? Bool ?? false,
                transport: item["transport"] as? String ?? "unknown",
                endpoint: item["endpoint"] as? String ?? "—"
            )
        }
        let servers = root["external_servers"] as? [[String: Any]] ?? []
        result.externalServers = servers.map { item in
            ServerRow(
                host: item["host"] as? String ?? "unknown",
                port: item["port"] as? String ?? "",
                processes: (item["processes"] as? [String] ?? []).joined(separator: ", "),
                connectionCount: Int(number(item["connection_count"]) ?? 0)
            )
        }
        return result
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LimitBar: View {
    let title: String
    let percent: Double?
    let estimated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(percent.map { String(format: "剩余 %.0f%%%@", $0, estimated ? " · 预计" : "") } ?? "—")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(percent ?? 0, 0), 100), total: 100)
                .tint((percent ?? 100) <= 20 ? .orange : .green)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: MonitorModel
    @State private var panel = 0
    private var s: MonitorSnapshot { model.snapshot }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Monitor").font(.headline)
                    Text(model.error == nil ? "每 10 秒自动刷新" : "数据读取异常")
                        .font(.caption).foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                }
                Spacer()
                Circle()
                    .fill(model.error == nil ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("立即刷新")
            }

            Picker("面板", selection: $panel) {
                Text("概览").tag(0)
                Text("Skills / MCP").tag(1)
                Text("外部服务器").tag(2)
            }
            .pickerStyle(.segmented)

            Group {
                if panel == 0 { overviewPanel }
                else if panel == 1 { integrationsPanel }
                else { serversPanel }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            Divider()
            HStack {
                Button("打开数据目录") { model.openDataFolder() }
                Spacer()
                if s.warningCount > 0 {
                    Label("\(s.warningCount) 个警告", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 420, height: 590)
    }

    private var overviewPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                MetricCard(title: "进程", value: "\(s.processCount)", icon: "cpu", tint: .cyan)
                MetricCard(title: "连接", value: "\(s.connectionCount)", icon: "network", tint: .mint)
                MetricCard(title: "余额", value: s.balance, icon: "creditcard", tint: .yellow)
            }
            HStack(spacing: 9) {
                MetricCard(title: "入站", value: byteString(s.bytesIn), icon: "arrow.down", tint: .blue)
                MetricCard(title: "出站", value: byteString(s.bytesOut), icon: "arrow.up", tint: .purple)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("本地观测 Token", systemImage: "number.circle").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(compact(s.totalTokens)).font(.title3.monospacedDigit().bold())
                }
                HStack {
                    Text("输入 \(compact(s.inputTokens))")
                    Text("缓存 \(compact(s.cachedTokens))")
                    Text("输出 \(compact(s.outputTokens))")
                    Spacer()
                    Text("\(s.sessionCount) 会话")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(11)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            VStack(spacing: 9) {
                LimitBar(title: "5 小时窗口", percent: s.primaryRemaining, estimated: s.primaryEstimated)
                LimitBar(title: "7 天窗口", percent: s.secondaryRemaining, estimated: s.secondaryEstimated)
            }
            if !s.processes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CPU 占用最高").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(s.processes.prefix(4)) { process in
                        HStack {
                            Text(process.name).lineLimit(1)
                            Text("PID \(process.id)").foregroundStyle(.tertiary)
                            Spacer()
                            Text(String(format: "%.1f%%", process.cpu)).monospacedDigit()
                            Text(byteString(process.rss)).foregroundStyle(.secondary).frame(width: 68, alignment: .trailing)
                        }.font(.caption)
                    }
                }
            }
        }
    }

    private var integrationsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("本地 Skills", systemImage: "hammer").font(.headline)
                    Spacer()
                    Text("\(s.skills.count)").font(.headline.monospacedDigit()).foregroundStyle(.cyan)
                }
                ForEach(s.skills) { skill in
                    HStack(alignment: .top) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.subheadline.weight(.medium))
                            Text(skill.source).font(.caption).foregroundStyle(.secondary)
                            if !skill.description.isEmpty {
                                Text(skill.description).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                    Divider()
                }
                HStack {
                    Label("MCP 服务", systemImage: "shippingbox").font(.headline)
                    Spacer()
                    Text("\(s.mcpServers.count)").font(.headline.monospacedDigit()).foregroundStyle(.mint)
                }
                ForEach(s.mcpServers) { mcp in
                    HStack(alignment: .top) {
                        Circle().fill(mcp.enabled ? Color.green : Color.gray).frame(width: 8, height: 8).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(mcp.name).font(.subheadline.weight(.medium))
                                Text(mcp.transport).font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(mcp.endpoint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                    }
                    Divider()
                }
            }
        }
    }

    private var serversPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("活动外部服务器", systemImage: "server.rack").font(.headline)
                    Spacer()
                    Text("\(s.externalServers.count)").font(.headline.monospacedDigit()).foregroundStyle(.orange)
                }
                Text("仅显示 Codex 进程当前建立的非本机连接，不捕获传输内容。")
                    .font(.caption).foregroundStyle(.secondary)
                if s.externalServers.isEmpty {
                    ContentUnavailableView("暂无外部连接", systemImage: "network.slash")
                }
                ForEach(s.externalServers) { server in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: "globe").foregroundStyle(.orange)
                            Text(server.host).font(.subheadline.monospaced().weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(server.port.isEmpty ? "—" : ":\(server.port)").font(.caption.monospaced())
                        }
                        HStack {
                            Text(server.processes.isEmpty ? "未知进程" : server.processes)
                            Spacer()
                            Text("\(server.connectionCount) 个连接")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func byteString(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func compact(_ value: Int64) -> String {
        let n = Double(value)
        if n >= 1_000_000_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
        return "\(value)"
    }
}

@main
struct CodexMonitorWidgetApp: App {
    @StateObject private var model = MonitorModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Label("Codex Monitor", systemImage: model.error == nil ? "waveform.path.ecg" : "exclamationmark.triangle")
        }
        .menuBarExtraStyle(.window)
    }
}
