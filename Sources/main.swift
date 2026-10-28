// ClawdFloat — Claude 真·桌宠「Clawd 悬浮窗」
// 单文件 AppKit 应用:透明无边框 NSPanel + Core Graphics 手绘像素螃蟹 + 额度气泡。
// 编译:swiftc -O -swift-version 5 Sources/main.swift -o build/ClawdFloat
// 运行:build/ClawdFloat            正常悬浮
//       build/ClawdFloat --selftest     真机自检(Key 发现 / 接口 / 窗口属性 / 截图)
//       build/ClawdFloat --snapshot <png> [--mood 60] [--unit 14] [--page 0]
// 作者:RichardDou0607 · 2026-10-26

import AppKit
import Foundation

// MARK: - 基础工具

let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ClawdFloat", isDirectory: true)
let configURL = appSupportDir.appendingPathComponent("config.json")
let logURL = appSupportDir.appendingPathComponent("app.log")

func ensureSupportDir() {
    try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
}

func log(_ message: String) {
    ensureSupportDir()
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path), let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 8) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

// MARK: - 配置

struct AppConfig: Codable {
    var unit: Double = 14
    /// 气泡字体缩放(独立于 unit;nil/1.0 = 默认大小);用 Optional 兼容旧 config
    var textScale: Double? = nil
    /// claudeWindow = 只在 Claude Code App 窗口内显示(默认);desktop = 桌面自由悬浮
    var anchorMode: String = "claudeWindow"
    /// 宠物窗口相对 Claude 窗口左上角的偏移(CG 坐标,点);nil = 默认右下角
    var anchorDX: Double? = nil
    var anchorDY: Double? = nil
    var levelMode: String = "normal" // normal=当前桌面 | floating=当前桌面+浮层 | allSpaces=所有桌面空间+全屏
    /// 明确的下次续费日 "yyyy-MM-dd"(优先于 renewalDay;过期后按 planCycle 往后滚)
    var renewalDate: String? = nil
    /// monthly | quarterly | yearly(季卡 = quarterly)
    var planCycle: String = "monthly"
    var renewalDay: Int = 26
    var refreshMinutes: Int = 1
    var page: Int = 0
    var posX: Double? = nil
    var posY: Double? = nil
    var apiToken: String? = nil
    var apiHost: String? = nil

    var levelModeLabel: String {
        switch levelMode {
        case "floating": return "当前桌面 + 浮于普通窗口之上"
        case "allSpaces": return "所有桌面空间 + 全屏"
        default: return "当前桌面(跟随 Claude)"
        }
    }

    var planCycleLabel: String { planCycleLabelFor(planCycle) }
}

enum ConfigStore {
    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return cfg
    }

    static func save(_ config: AppConfig) {
        ensureSupportDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL)
        }
    }
}

// MARK: - 额度数据

struct QuotaWindow: Codable {
    var used: Double
    var total: Double
    var percentage: Int
    var resetAt: Double? // epoch ms
}

struct QuotaSnapshot: Codable {
    var fetchedAt: Double // epoch ms
    var level: String
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var error: String?
    var source: String

    var fetchedDate: Date { Date(timeIntervalSince1970: fetchedAt / 1000) }
    var hasWindows: Bool { fiveHour != nil || weekly != nil }
    var worstPercentage: Int {
        max(fiveHour?.percentage ?? 0, weekly?.percentage ?? 0)
    }
}

struct AuthInfo {
    var token: String
    var host: String
    var source: String
}

enum QuotaError: LocalizedError {
    case auth(String)
    case http(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .auth(let m): return m
        case .http(let m): return m
        case .decode(let m): return m
        }
    }
}

final class QuotaClient {
    static func monitorHost(_ baseURL: String?) -> String? {
        guard let base = baseURL?.lowercased(), !base.isEmpty else { return nil }
        if base.contains("bigmodel.cn") { return "https://open.bigmodel.cn" }
        if base.contains("api.z.ai") || base.contains("z.ai") { return "https://api.z.ai" }
        return nil
    }

    /// Key 发现顺序:配置 apiToken → cc-switch 当前 Claude 供应商 → ~/.claude/settings.json env
    static func resolveAuth(_ config: AppConfig) throws -> AuthInfo {
        if let token = config.apiToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            let host = monitorHost(config.apiHost) ?? "https://open.bigmodel.cn"
            return AuthInfo(token: token, host: host, source: "config")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = home + "/.cc-switch/cc-switch.db"
        if FileManager.default.fileExists(atPath: dbPath),
           let output = runProcess("/usr/bin/sqlite3", ["-json", dbPath,
               "SELECT settings_config FROM providers WHERE app_type='claude' AND is_current=1"]),
           let rowsData = output.data(using: .utf8),
           let rows = try? JSONSerialization.jsonObject(with: rowsData) as? [[String: Any]],
           let settingsString = rows.first?["settings_config"] as? String,
           let settingsData = settingsString.data(using: .utf8),
           let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
           let env = settings["env"] as? [String: Any],
           let token = env["ANTHROPIC_AUTH_TOKEN"] as? String, !token.isEmpty,
           let host = monitorHost(env["ANTHROPIC_BASE_URL"] as? String) {
            return AuthInfo(token: token, host: host, source: "cc-switch")
        }

        let settingsPath = home + "/.claude/settings.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = settings["env"] as? [String: Any],
           let token = env["ANTHROPIC_AUTH_TOKEN"] as? String,
           !token.isEmpty, token != "PROXY_MANAGED" {
            let host = monitorHost(env["ANTHROPIC_BASE_URL"] as? String)
                ?? monitorHost(config.apiHost)
                ?? "https://open.bigmodel.cn"
            return AuthInfo(token: token, host: host, source: "settings")
        }

        throw QuotaError.auth("未找到 GLM API Key(检查 cc-switch 当前供应商或 ~/.claude/settings.json)")
    }

    static func fetch(_ config: AppConfig) -> Result<QuotaSnapshot, Error> {
        do {
            let auth = try resolveAuth(config)
            var request = URLRequest(url: URL(string: auth.host + "/api/monitor/usage/quota/limit")!)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue(auth.token, forHTTPHeaderField: "Authorization")
            request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?
            var statusCode = 0
            URLSession.shared.dataTask(with: request) { data, response, error in
                resultData = data
                resultError = error
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 25)

            if let error = resultError { throw QuotaError.http(error.localizedDescription) }
            guard let data = resultData else { throw QuotaError.http("空响应") }
            guard statusCode == 200 else { throw QuotaError.http("HTTP \(statusCode)") }
            return .success(try parse(data, source: auth.source))
        } catch {
            return .failure(error)
        }
    }

    static func parse(_ data: Data, source: String) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("响应不是 JSON")
        }
        if let code = (root["code"] as? NSNumber)?.intValue, code != 200 {
            let message = (root["msg"] as? String) ?? "code \(code)"
            throw QuotaError.http(message)
        }
        guard let payload = root["data"] as? [String: Any] else {
            throw QuotaError.decode("响应缺少 data")
        }
        let level = ((payload["planName"] as? String) ?? (payload["level"] as? String) ?? "").uppercased()
        let limits = payload["limits"] as? [[String: Any]] ?? []
        var windows: [QuotaWindow] = []
        for limit in limits {
            guard let type = limit["type"] as? String, type == "CREDIT_LIMIT" || type == "TOKENS_LIMIT" else { continue }
            let total = (limit["usage"] as? NSNumber)?.doubleValue ?? 0
            guard total > 0 else { continue }
            var used = (limit["currentValue"] as? NSNumber)?.doubleValue
            if used == nil, let remaining = (limit["remaining"] as? NSNumber)?.doubleValue {
                used = max(0, total - remaining)
            }
            let usedValue = max(0, min(total, used ?? 0))
            let percentage = Int((usedValue / total * 100).rounded())
            let resetAt = (limit["nextResetTime"] as? NSNumber)?.doubleValue
            windows.append(QuotaWindow(used: usedValue, total: total, percentage: percentage, resetAt: resetAt))
        }
        windows.sort { ($0.resetAt ?? 0) < ($1.resetAt ?? 0) }
        let five = windows.first
        let weekly = windows.count > 1 ? windows.last : nil
        return QuotaSnapshot(
            fetchedAt: Date().timeIntervalSince1970 * 1000,
            level: level,
            fiveHour: five,
            weekly: weekly,
            error: nil,
            source: source
        )
    }
}

// MARK: - 日期/格式化

func fmtClock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func fmtDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd"
    return formatter.string(from: date)
}

func planCycleLabelFor(_ cycle: String) -> String {
    switch cycle {
    case "quarterly": return "季卡"
    case "yearly": return "年卡"
    case "none": return "一次性"
    default: return "月卡"
    }
}

func fmtFullDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

func parseISODate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    return formatter.date(from: value)
}

func fmtDateClock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: date)
}

func fmtNumber(_ value: Double) -> String {
    if value >= 1000 {
        let k = value / 1000
        if k >= 100 { return String(Int(k.rounded())) + "k" }
        let rounded = (k * 10).rounded() / 10
        if rounded >= 10, abs(rounded - rounded.rounded()) < 0.001 {
            return String(Int(rounded.rounded())) + "k"
        }
        return (rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)) + "k"
    }
    return String(Int(value.rounded()))
}

func fmtDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "—" }
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "\(minutes) 分钟" }
    let hours = minutes / 60
    let mins = minutes % 60
    if hours < 48 { return mins == 0 ? "\(hours) 小时" : "\(hours) 小时 \(mins) 分" }
    return "\(Int((Double(hours) / 24).rounded())) 天"
}

/// 下一次续费日(当天 00:00 本地时间);day 超出当月天数时收敛到月末。
func nextRenewal(now: Date, day: Int) -> Date? {
    guard day >= 1 && day <= 31 else { return nil }
    let calendar = Calendar.current
    for offset in 0..<3 {
        guard let monthStart = calendar.date(byAdding: .month, value: offset,
                                             to: calendar.date(from: calendar.dateComponents([.year, .month], from: now))!) else { continue }
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 28
        var components = calendar.dateComponents([.year, .month], from: monthStart)
        components.day = min(day, daysInMonth)
        guard let candidate = calendar.date(from: components) else { continue }
        // 续费日当天显示“今天”(而不是直接跳到下个月)
        if calendar.isDate(candidate, inSameDayAs: now) { return candidate }
        if candidate > now { return candidate }
    }
    return nil
}

/// 续费日:优先用配置的明确日期(renewalDate),过期后按 planCycle 周期顺延;
/// 没有配置日期时退回 renewalDay(每月几号)。
func nextRenewalResolved(now: Date, renewalDate: String?, planCycle: String, fallbackDay: Int) -> Date? {
    if let raw = renewalDate?.trimmingCharacters(in: .whitespacesAndNewlines),
       !raw.isEmpty, let base = parseISODate(raw) {
        let calendar = Calendar.current
        let months: Int
        switch planCycle {
        case "quarterly": months = 3
        case "yearly": months = 12
        case "none": months = 0
        default: months = 1
        }
        if months == 0 { return base > now ? base : nil }
        var candidate = base
        var guardCount = 0
        while candidate < calendar.startOfDay(for: now) && guardCount < 48 {
            guard let next = calendar.date(byAdding: .month, value: months, to: candidate) else { break }
            candidate = next
            guardCount += 1
        }
        return candidate
    }
    return nextRenewal(now: now, day: fallbackDay)
}

/// 官方峰谷时段:高峰 = 周一至周五 14:00–18:00(UTC+8),其余时间(含周末全天)为非高峰。
struct PeakInfo {
    var isPeak: Bool
    var label: String        // 高峰 / 非高峰
    var shortLabel: String   // 峰 / 谷
    var discount: String     // 1x / 0.5x 积分
    var note: String         // 还 X
    var rule: String
}

func peakInfo(now: Date) -> PeakInfo {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current
    let comps = calendar.dateComponents([.weekday, .hour, .minute], from: now)
    let weekday = comps.weekday ?? 1 // 1=周日 ... 7=周六
    let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    let isWeekday = weekday >= 2 && weekday <= 6
    let isPeak = isWeekday && minutes >= 14 * 60 && minutes < 18 * 60

    // 下一次状态切换
    var next: Date?
    if isPeak {
        next = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
    } else if isWeekday && minutes < 14 * 60 {
        next = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now)
    } else {
        var day = calendar.startOfDay(for: now)
        for _ in 0..<8 {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
            let wd = calendar.component(.weekday, from: day)
            if wd >= 2 && wd <= 6 {
                next = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: day)
                break
            }
        }
    }
    let remain = next.map { max(0, $0.timeIntervalSince(now)) } ?? 0
    func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))分" }
        if seconds < 48 * 3600 { return "\(Int(seconds / 3600))时" }
        return "\(Int(seconds / (24 * 3600)))天"
    }
    let note = isPeak ? "距结束 " + shortDuration(remain) : "距高峰 " + shortDuration(remain)
    return PeakInfo(isPeak: isPeak,
                    label: isPeak ? "高峰" : "非高峰",
                    shortLabel: isPeak ? "峰" : "谷",
                    discount: isPeak ? "1x" : "0.5x",
                    note: note,
                    rule: "周一至五 14:00–18:00 为高峰")
}

func dayDiff(from: Date, to: Date) -> Int {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: from)
    let end = calendar.startOfDay(for: to)
    return calendar.dateComponents([.day], from: start, to: end).day ?? 0
}

// MARK: 套餐档位 / 更新时间(与插件同口径)

struct AppPlanInfo {
    var tier: String
    var label: String
    var fiveCap: Double?
    var weekCap: Double?
}

let officialPlanCaps: [(tier: String, five: Double, week: Double)] = [
    ("Lite", 2000, 10000),
    ("Pro", 12000, 60000),
    ("Max", 28000, 140000),
]

func appPlanInfo(level: String, five: QuotaWindow?, weekly: QuotaWindow?) -> AppPlanInfo {
    let fiveCap = five?.total
    let weekCap = weekly?.total
    var tier = ""
    if let fiveCap = fiveCap, let weekCap = weekCap,
       let matched = officialPlanCaps.first(where: {
           abs($0.five - fiveCap) < 1 && abs($0.week - weekCap) < 1
       }) {
        tier = matched.tier
    }
    if tier.isEmpty {
        switch level.lowercased() {
        case "max": tier = "Max"
        case "pro": tier = "Pro"
        case "lite": tier = "Lite"
        default: tier = level.isEmpty ? "" : level
        }
    }
    return AppPlanInfo(tier: tier,
                       label: tier.isEmpty ? "GLM Coding Plan" : "GLM Coding Plan · (tier)",
                       fiveCap: fiveCap, weekCap: weekCap)
}

/// 续费日 + 周额度锚点的时刻(官方:周积分自下单起 7 天周期 → 锚点时刻即下单时刻)
func appNextRenewalAt(now: Date, day: Int, anchor: Date?) -> Date? {
    guard day >= 1 && day <= 31 else { return nil }
    let calendar = Calendar.current
    let hour = anchor.map { calendar.component(.hour, from: $0) } ?? 0
    let minute = anchor.map { calendar.component(.minute, from: $0) } ?? 0
    for offset in 0..<3 {
        let base = calendar.date(byAdding: .month, value: offset,
                                 to: calendar.date(from: calendar.dateComponents([.year, .month], from: now))!)
        guard let base = base else { continue }
        let days = calendar.range(of: .day, in: .month, for: base)?.count ?? 28
        var components = calendar.dateComponents([.year, .month], from: base)
        components.day = min(day, days)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let candidate = calendar.date(from: components) else { continue }
        if candidate > now { return candidate }
    }
    return nil
}

// MARK: - 表情/页面

enum PetMood {
    case loading, ok, warn, hot, crit, error

    var accentColor: NSColor {
        switch self {
        case .ok: return NSColor(srgbRed: 0.290, green: 0.761, blue: 0.420, alpha: 1)
        case .warn: return NSColor(srgbRed: 0.886, green: 0.725, blue: 0.231, alpha: 1)
        case .hot, .crit, .error: return NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)
        case .loading: return NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
        }
    }

    var faceDescription: String {
        switch self {
        case .loading: return "正在读取额度"
        case .ok: return "额度充足"
        case .warn: return "额度过半"
        case .hot: return "额度吃紧"
        case .crit: return "额度见底"
        case .error: return "额度接口连不上"
        }
    }
}

func moodFor(percentage: Int) -> PetMood {
    if percentage >= 95 { return .crit }
    if percentage >= 80 { return .hot }
    if percentage >= 50 { return .warn }
    return .ok
}

/// Claude Code 的工作状态(由 hooks 写入 claude-activity.json,App 轮询)
enum PetActivity: String {
    case idle, thinking, tool, working, waitingApproval, waitingReply, done, error

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .thinking: return "思考中"
        case .tool: return "调用工具"
        case .working: return "工作中"
        case .waitingApproval: return "等待审批"
        case .waitingReply: return "等待回复"
        case .done: return "完成"
        case .error: return "出错"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .idle: return NSColor(srgbRed: 0.62, green: 0.64, blue: 0.66, alpha: 1)
        case .thinking: return NSColor(srgbRed: 0.36, green: 0.66, blue: 0.98, alpha: 1)
        case .tool: return NSColor(srgbRed: 0.76, green: 0.55, blue: 0.98, alpha: 1)
        case .working: return NSColor(srgbRed: 0.29, green: 0.78, blue: 0.52, alpha: 1)
        case .waitingApproval: return NSColor(srgbRed: 0.96, green: 0.64, blue: 0.20, alpha: 1)
        case .waitingReply: return NSColor(srgbRed: 0.35, green: 0.68, blue: 0.96, alpha: 1)
        case .done: return NSColor(srgbRed: 0.45, green: 0.87, blue: 0.52, alpha: 1)
        case .error: return NSColor(srgbRed: 0.93, green: 0.33, blue: 0.33, alpha: 1)
        }
    }
}

struct BubblePage {
    var title: String
    var big: String
    var detail: String
    var progress: Double?
    var note: String? = nil
}

// MARK: - 像素数据(官方 clawd.svg 11×4 字符格,像素单位 6×13)

enum ClawdSprite {
    static let shell = [
        ".#########.",
        "###########",
        ".#########.",
    ]
    static let legsStand = ".#.#...#.#."
    static let legsStep = "..#.#.#.#.."

    /// 生成 11×4 网格:第 2 行第 2/8 列是近黑眼睛(#141413);stepping 时换腿位
    static func grid(stepping: Bool, blink: Bool) -> [[Character]] {
        var rows = (shell + [stepping ? legsStep : legsStand]).map { Array($0) }
        rows[1][2] = blink ? "#" : "E"
        rows[1][8] = blink ? "#" : "E"
        return rows
    }

    static let bodyColor = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #D97757
    static let eyeColor = NSColor(srgbRed: 0.078, green: 0.078, blue: 0.075, alpha: 1) // #141413
    static let sweatColor = NSColor(srgbRed: 0.424, green: 0.769, blue: 1.0, alpha: 1) // #6CC4FF
}

protocol PetViewDelegate: AnyObject {
    func petViewRequestRefresh(_ view: PetView)
    func petViewCyclePage(_ view: PetView)
    func petViewRequestQuit(_ view: PetView)
    func petViewAdjustScale(_ view: PetView, delta: Double)
    func petViewAdjustTextScale(_ view: PetView, delta: Double)
    func petViewDidFinishDrag(_ view: PetView)
    func petViewRequestMenu(_ view: PetView, event: NSEvent)
}

// MARK: - 绘制视图

final class PetView: NSView {
    weak var delegate: PetViewDelegate?

    var snapshot: QuotaSnapshot?
    var busy = false
    var tick = 0
    var scurryTicks = 0
    private(set) var pageCount = 4
    private(set) var activity: PetActivity = .idle
    private(set) var activityTool: String?
    private(set) var activityStartTick = 0

    /// 由 controller/状态文件驱动;变化时重置动画相位
    func setActivity(_ next: PetActivity, tool: String? = nil) {
        let toolChanged = (tool ?? "") != (activityTool ?? "")
        guard next != activity || toolChanged else { return }
        activity = next
        activityTool = tool
        activityStartTick = tick
        needsDisplay = true
    }

    private func stateAgeTicks() -> Int { max(0, tick - activityStartTick) }
    var page = 0
    var renewalDay = 26
    var renewalDateString: String?
    var planCycle: String = "monthly"
    var refreshMinutes = 1
    var unit: CGFloat = 14
    /// 气泡字体/气泡尺寸缩放,独立于宠物 unit
    var textScale: CGFloat = 1.0

    private enum HitPart { case none, crab, bubble, close }
    private var hoverPart: HitPart = .none
    private var clickPart: HitPart = .none
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragMoved = false
    /// 拖拽时的目标窗口原点限制(跟随 Claude 窗口内时由 controller 注入)
    var clampOrigin: ((NSPoint) -> NSPoint)?
    private(set) var isDragging = false
    private var mouseDownPoint = NSPoint.zero
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: 布局

    /// 所有 UI 一律按 unit=14 的基准坐标绘制,再整体缩放到当前 unit;
    /// 这样气泡/状态牌/道具/文字会随大小等比适配,不会出现小尺寸裁切或大尺寸重叠。
    static let baseUnit: CGFloat = 14

    private var layoutScale: CGFloat { unit / PetView.baseUnit }

    /// unit 控制宠物/道具;textScale 只控制气泡尺寸和字体,二者独立。
    private struct PixelLayout {
        var window: NSSize
        var bubbleOrigin: NSPoint
        var bubbleSize: NSSize
        var crabOrigin: NSPoint
        var crabSize: NSSize
        var closeRect: NSRect
        var dotsRect: NSRect
        var badgeRect: NSRect
        var petScale: CGFloat
        var textScale: CGFloat
        var bubbleRect: NSRect { NSRect(origin: bubbleOrigin, size: bubbleSize) }
        var crabRect: NSRect { NSRect(origin: crabOrigin, size: crabSize) }
    }

    private func pixelLayout() -> PixelLayout {
        let petScale = unit / PetView.baseUnit
        let ts = max(0.55, min(2.2, textScale))
        let baseBubbleW: CGFloat = 248
        let baseBubbleH: CGFloat = 88
        let baseCrabW: CGFloat = 154
        let baseCrabH: CGFloat = 4 * (14.0 * 13.0 / 6.0)
        let margin: CGFloat = 10
        let gap: CGFloat = 14
        let leftSpace = 94 * petScale

        let bubbleW = baseBubbleW * ts
        let bubbleH = baseBubbleH * ts
        let crabW = baseCrabW * petScale
        let crabH = baseCrabH * petScale
        let totalW = max(bubbleW, crabW + leftSpace) + margin * 2
        let totalH = margin + bubbleH + gap + crabH + margin

        let bubbleOrigin = NSPoint(x: margin, y: margin)
        let crabOrigin = NSPoint(x: totalW - margin - crabW, y: margin + bubbleH + gap)
        let close = NSRect(x: bubbleOrigin.x + (baseBubbleW - 22) * ts,
                           y: bubbleOrigin.y + 6 * ts,
                           width: 16 * ts, height: 16 * ts)
        let dots = NSRect(x: bubbleOrigin.x + 14 * ts,
                          y: bubbleOrigin.y + 77 * ts,
                          width: 60 * ts, height: 5 * ts)
        let badge = NSRect(x: crabOrigin.x - 92 * petScale,
                           y: crabOrigin.y + 26 * petScale,
                           width: 88 * petScale, height: 30 * petScale)
        return PixelLayout(window: NSSize(width: totalW, height: totalH),
                           bubbleOrigin: bubbleOrigin,
                           bubbleSize: NSSize(width: bubbleW, height: bubbleH),
                           crabOrigin: crabOrigin,
                           crabSize: NSSize(width: crabW, height: crabH),
                           closeRect: close, dotsRect: dots, badgeRect: badge,
                           petScale: petScale, textScale: ts)
    }

    func desiredSize() -> NSSize { pixelLayout().window }

    /// 给 --selftest 用的几何/命中检查(不参与交互)
    func debugLayoutReport() -> [String: Any] {
        let l = pixelLayout()
        let crabAspect = l.crabSize.height > 0 ? l.crabSize.width / l.crabSize.height : 0
        return [
            "bubble": ["x": l.bubbleRect.minX, "y": l.bubbleRect.minY,
                       "w": l.bubbleRect.width, "h": l.bubbleRect.height],
            "crab": ["x": l.crabRect.minX, "y": l.crabRect.minY,
                     "w": l.crabRect.width, "h": l.crabRect.height],
            "close": ["x": l.closeRect.minX, "y": l.closeRect.minY,
                      "w": l.closeRect.width, "h": l.closeRect.height],
            "badge": ["x": l.badgeRect.minX, "y": l.badgeRect.minY,
                      "w": l.badgeRect.width, "h": l.badgeRect.height],
            "crabAspect": crabAspect,
            "targetAspect": 1.2692,
            "aspectOK": abs(crabAspect - 1.2692) < 0.03,
            "petScale": l.petScale,
            "textScale": l.textScale,
            "windowSize": ["w": l.window.width, "h": l.window.height],
        ]
    }

    func debugHitName(x: CGFloat, y: CGFloat) -> String {
        switch hitTestPart(NSPoint(x: x, y: y)) {
        case .crab: return "crab"
        case .bubble: return "bubble"
        case .close: return "close"
        case .none: return "none"
        }
    }

    // MARK: 数据 → 页面

    private func pages() -> [BubblePage] {
        guard let snapshot = snapshot else {
            return [BubblePage(title: "Clawd · GLM Coding Plan", big: "正在读取…",
                               detail: "点螃蟹立即刷新", progress: nil)]
        }
        if let error = snapshot.error, !snapshot.hasWindows {
            return [BubblePage(title: "连不上额度接口", big: "×_×;",
                               detail: String(error.prefix(26)), progress: nil),
                    BubblePage(title: "排查提示", big: "Key 自动发现",
                               detail: "cc-switch 当前供应商 / settings.json", progress: nil)]
        }

        var pages: [BubblePage] = []
        let now = Date()
        let plan = appPlanInfo(level: snapshot.level, five: snapshot.fiveHour, weekly: snapshot.weekly)
        if let five = snapshot.fiveHour {
            let detailText: String
            if let reset = five.resetAt {
                let date = Date(timeIntervalSince1970: reset / 1000)
                let remain = date.timeIntervalSince(now)
                detailText = remain > 0
                    ? "更新 \(fmtClock(date)) · 剩 \(fmtDuration(remain)) · 动态刷新"
                    : "更新 \(fmtClock(date)) · 即将刷新"
            } else {
                // 5h 额度是动态窗口:本周期还没被使用过时,接口不会返回 nextResetTime
                detailText = "本 5h 窗口空闲 · 使用后开始计时"
            }
            pages.append(BubblePage(
                title: "5 小时额度 · \(fmtNumber(five.used))/\(fmtNumber(five.total))",
                big: "\(five.percentage)%",
                detail: detailText,
                progress: Double(five.percentage) / 100))
        }
        if let weekly = snapshot.weekly {
            let detailText: String
            if let reset = weekly.resetAt {
                let date = Date(timeIntervalSince1970: reset / 1000)
                let remain = date.timeIntervalSince(now)
                detailText = remain > 0
                    ? "更新 \(fmtDateClock(date)) · 剩 \(fmtDuration(remain))"
                    : "更新 \(fmtDateClock(date)) · 即将刷新"
            } else {
                detailText = "本周暂无更新时间"
            }
            pages.append(BubblePage(
                title: "本周额度 · \(fmtNumber(weekly.used))/\(fmtNumber(weekly.total))",
                big: "\(weekly.percentage)%",
                detail: detailText,
                progress: Double(weekly.percentage) / 100))
        }
        if let renewal = nextRenewalResolved(now: now, renewalDate: renewalDateString,
                                             planCycle: planCycle, fallbackDay: renewalDay) {
            let days = dayDiff(from: now, to: renewal)
            pages.append(BubblePage(
                title: "下次续费",
                big: fmtFullDate(renewal),
                detail: "\(planCycleLabelFor(planCycle)) · 还 \(days) 天" + (days == 0 ? " · 今天" : ""),
                progress: nil,
                note: planCycleLabelFor(planCycle)))
        } else {
            pages.append(BubblePage(title: "下次续费", big: "未设置",
                                    detail: "config.json 里填 renewalDate 或 renewalDay", progress: nil))
        }
        var statusDetail = "\(planCycleLabelFor(planCycle)) · Key \(snapshot.source) · \(fmtClock(snapshot.fetchedDate)) 更新"
        if snapshot.error != nil {
            statusDetail = "刷新失败 · 显示旧数据 · Key \(snapshot.source)"
        }
        pages.append(BubblePage(title: "GLM Coding Plan",
                                big: plan.tier.isEmpty ? "GLM" : plan.tier,
                                detail: statusDetail, progress: nil,
                                note: moodFor(percentage: snapshot.worstPercentage).faceDescription))
        let peak = peakInfo(now: now)
        pages.append(BubblePage(title: "峰谷时段 · \(peak.discount)",
                                big: peak.label,
                                detail: peak.rule,
                                progress: nil,
                                note: peak.note))
        return pages
    }

    private func currentMood() -> PetMood {
        guard let snapshot = snapshot else { return .loading }
        if snapshot.error != nil, !snapshot.hasWindows { return .error }
        return moodFor(percentage: snapshot.worstPercentage)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.shouldAntialias = true
        let l = pixelLayout()
        let mood = currentMood()
        let pages = pages()
        pageCount = pages.count

        // 气泡:独立的 textScale(字体大小只由它控制)
        NSGraphicsContext.saveGraphicsState()
        let bubbleTransform = NSAffineTransform()
        bubbleTransform.translateX(by: l.bubbleOrigin.x, yBy: l.bubbleOrigin.y)
        bubbleTransform.scale(by: l.textScale)
        bubbleTransform.concat()
        let baseBubble = NSRect(x: 0, y: 0, width: 248, height: 88)
        let localClose = NSRect(x: 226, y: 6, width: 16, height: 16)
        let localDots = NSRect(x: 14, y: 77, width: 60, height: 5)
        drawBubble(in: baseBubble, mood: mood, pages: pages, close: localClose, dots: localDots)
        NSGraphicsContext.restoreGraphicsState()

        // 宠物 + 道具 + 状态牌:只跟 unit 的 petScale 走
        NSGraphicsContext.saveGraphicsState()
        let petTransform = NSAffineTransform()
        petTransform.translateX(by: l.crabOrigin.x, yBy: l.crabOrigin.y)
        petTransform.scale(by: l.petScale)
        petTransform.concat()
        let baseCrab = NSRect(x: 0, y: 0, width: 154, height: 4 * (14.0 * 13.0 / 6.0))
        let baseBadge = NSRect(x: -92, y: 26, width: 88, height: 30)
        drawCrab(in: baseCrab, mood: mood, activity: activity)
        drawActivityEffects(in: baseCrab, activity: activity, tool: activityTool)
        drawStateBadge(in: baseBadge, activity: activity, tool: activityTool)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBubble(in rect: NSRect, mood: PetMood, pages: [BubblePage], close: NSRect, dots: NSRect) {
        let pageIndex = pages.isEmpty ? 0 : page % pages.count
        let current = pages.isEmpty ? BubblePage(title: "", big: "", detail: "", progress: nil) : pages[pageIndex]

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        let bubblePath = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        NSColor(srgbRed: 0.075, green: 0.075, blue: 0.070, alpha: 0.92).setFill()
        bubblePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 气泡边框随额度档位变色:绿 / 黄 / 红
        NSGraphicsContext.saveGraphicsState()
        let borderPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 15.5, yRadius: 15.5)
        borderPath.lineWidth = 1.5
        mood.accentColor.setStroke()
        borderPath.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        bubblePath.setClip()

        let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let bigFont = NSFont.systemFont(ofSize: 21, weight: .bold)
        let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let dim = NSColor(srgbRed: 0.72, green: 0.71, blue: 0.68, alpha: 1)

        drawText(current.title, in: NSRect(x: rect.minX + 14, y: rect.minY + 9, width: rect.width - 60, height: 15),
                 font: titleFont, color: dim)
        if busy {
            // 手动/自动刷新中:把页码位置换成“更新中”,让点击宠物有可见反馈
            drawText("更新中",
                     in: NSRect(x: rect.maxX - 70, y: rect.minY + 9, width: 40, height: 15),
                     font: NSFont.systemFont(ofSize: 10, weight: .medium), color: mood.accentColor, alignment: .right)
        } else {
            drawText("\(pageIndex + 1)/\(max(1, pages.count))",
                     in: NSRect(x: rect.maxX - 66, y: rect.minY + 9, width: 22, height: 15),
                     font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), color: dim, alignment: .right)
        }

        drawText(current.big,
                 in: NSRect(x: rect.minX + 14, y: rect.minY + 24, width: 130, height: 27),
                 font: bigFont, color: mood.accentColor)

        if let progress = current.progress {
            drawProgressBar(progress: progress, mood: mood,
                            in: NSRect(x: rect.minX + 150, y: rect.minY + 34, width: rect.width - 168, height: 8))
        } else {
            drawText(current.note ?? mood.faceDescription,
                     in: NSRect(x: rect.minX + 150, y: rect.minY + 30, width: rect.width - 168, height: 16),
                     font: NSFont.systemFont(ofSize: 11, weight: .medium), color: mood.accentColor,
                     alignment: .right)
        }

        drawText(current.detail,
                 in: NSRect(x: rect.minX + 14, y: rect.minY + 57, width: rect.width - 28, height: 15),
                 font: detailFont, color: dim)

        // 退出按钮
        let closeHover = hoverPart == .close
        if closeHover {
            NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: close.insetBy(dx: -3, dy: -3), xRadius: 5, yRadius: 5).fill()
        }
        let closeColor = closeHover ? NSColor(srgbRed: 0.95, green: 0.35, blue: 0.35, alpha: 1) : dim
        drawText("✕", in: NSRect(x: close.minX, y: close.minY, width: close.width, height: close.height),
                 font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: closeColor, alignment: .center)

        // 页脚圆点
        let count = min(pages.count, 6)
        var dotX = dots.minX
        for index in 0..<count {
            let dotRect = NSRect(x: dotX, y: dots.minY, width: 5, height: 5)
            let color = index == pageIndex ? mood.accentColor : NSColor.white.withAlphaComponent(0.22)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            dotX += 9
        }
        // 常驻峰谷角标:谷=蓝,峰=橙
        let peak = peakInfo(now: Date())
        let peakColor = peak.isPeak
            ? NSColor(srgbRed: 0.96, green: 0.64, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.35, green: 0.68, blue: 0.96, alpha: 1)
        drawText(peak.shortLabel,
                 in: NSRect(x: dots.minX + CGFloat(count) * 9 + 4, y: dots.minY - 3, width: 18, height: 12),
                 font: NSFont.systemFont(ofSize: 9, weight: .bold), color: peakColor)

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawProgressBar(progress: Double, mood: PetMood, in rect: NSRect) {
        let cells = 10
        let clamped = max(0, min(1, progress))
        let gap: CGFloat = 2
        let cellWidth = (rect.width - gap * CGFloat(cells - 1)) / CGFloat(cells)
        for index in 0..<cells {
            let cellRect = NSRect(x: rect.minX + CGFloat(index) * (cellWidth + gap), y: rect.minY,
                                  width: cellWidth, height: rect.height)
            let filled = Double(index) < clamped * Double(cells) - 0.001
            let color = filled ? mood.accentColor : NSColor.white.withAlphaComponent(0.13)
            color.setFill()
            NSBezierPath(roundedRect: cellRect, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }

    private func drawCrab(in rect: NSRect, mood: PetMood, activity: PetActivity) {
        let pixelWidth = rect.width / 11
        let pixelHeight = rect.height / 4
        let age = stateAgeTicks()

        // 各状态的肢体/位移节奏
        var offset = NSPoint.zero
        var stepping = false
        switch activity {
        case .working:
            offset.y = sin(Double(tick) * 0.9) * 1.6
            stepping = tick % 2 == 0
        case .tool:
            offset.x = sin(Double(tick) * 0.55) * 1.2
            stepping = tick % 4 < 2
        case .thinking:
            offset.y = sin(Double(tick) * 0.28) * 0.9
            stepping = (tick % 52) >= 48 // 偶尔换一下脚
        case .waitingApproval, .waitingReply:
            offset.x = (tick % 12 < 6) ? 0 : 1
            stepping = (tick % 30) < 15 // 抖脚等用户/审批
        case .done:
            offset.y = -abs(sin(Double(age) * 0.35)) * 6 // 向上跳(flipped y 变小)
            stepping = tick % 2 == 0
        case .error:
            offset.x = sin(Double(tick) * 2.2) * 2
        case .idle:
            break
        }

        let busyOrShuffle = busy || scurryTicks > 0 || (tick % 48) >= 42
        if activity == .idle {
            stepping = busy ? (tick % 2 == 1) : (busyOrShuffle && tick % 2 == 0)
        }
        let blink = !busy && activity != .working && activity != .tool && (tick % 40) < 2

        let rows = ClawdSprite.grid(stepping: stepping, blink: blink)
        let context = NSGraphicsContext.current
        context?.shouldAntialias = false

        // 地面阴影(不随身体跳动)
        context?.shouldAntialias = true
        let shadowRect = NSRect(x: rect.minX + rect.width * 0.08, y: rect.maxY - 4,
                                width: rect.width * 0.84, height: 8)
        NSColor.black.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: shadowRect).fill()
        context?.shouldAntialias = false

        // 取整避免像素块之间出现缝隙(非整数偏移 + 关闭抗锯齿会露网格线)
        let bodyRect = rect.offsetBy(dx: offset.x.rounded(), dy: offset.y.rounded())
        // 把所有身体像素块合成一条路径再一次性填充,避免非整数缩放时块与块之间露出网格缝
        let bodyPath = NSBezierPath()
        var eyes: [NSRect] = []
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, character) in row.enumerated() where character != "." {
                let cell = NSRect(x: bodyRect.minX + CGFloat(columnIndex) * pixelWidth,
                                  y: bodyRect.minY + CGFloat(rowIndex) * pixelHeight,
                                  width: pixelWidth, height: pixelHeight)
                bodyPath.appendRect(cell)
                if character == "E", !blink {
                    eyes.append(NSRect(x: cell.minX, y: cell.minY,
                                       width: cell.width, height: cell.height * 6.0 / 13.0))
                }
            }
        }
        ClawdSprite.bodyColor.setFill()
        bodyPath.fill()
        ClawdSprite.eyeColor.setFill()
        for eye in eyes { NSBezierPath(rect: eye).fill() }
        context?.shouldAntialias = true

        drawMoodExtras(in: bodyRect, mood: mood, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private func drawMoodExtras(in rect: NSRect, mood: PetMood, pixelWidth: CGFloat, pixelHeight: CGFloat) {
        func droplet(center: NSPoint, size: CGFloat) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: center.x, y: center.y - size * 0.62))
            path.curve(to: NSPoint(x: center.x + size * 0.5, y: center.y + size * 0.1),
                       controlPoint1: NSPoint(x: center.x + size * 0.16, y: center.y - size * 0.3),
                       controlPoint2: NSPoint(x: center.x + size * 0.5, y: center.y - size * 0.16))
            path.curve(to: NSPoint(x: center.x, y: center.y + size * 0.6),
                       controlPoint1: NSPoint(x: center.x + size * 0.5, y: center.y + size * 0.42),
                       controlPoint2: NSPoint(x: center.x, y: center.y + size * 0.6))
            path.curve(to: NSPoint(x: center.x - size * 0.5, y: center.y + size * 0.1),
                       controlPoint1: NSPoint(x: center.x, y: center.y + size * 0.6),
                       controlPoint2: NSPoint(x: center.x - size * 0.5, y: center.y + size * 0.42))
            path.curve(to: NSPoint(x: center.x, y: center.y - size * 0.62),
                       controlPoint1: NSPoint(x: center.x - size * 0.5, y: center.y - size * 0.16),
                       controlPoint2: NSPoint(x: center.x - size * 0.16, y: center.y - size * 0.3))
            path.close()
            ClawdSprite.sweatColor.setFill()
            path.fill()
        }

        let dropSize = pixelWidth * 0.85
        switch mood {
        case .warn, .hot, .crit, .error:
            let rightTop = NSPoint(x: rect.maxX - pixelWidth * 0.4, y: rect.minY - pixelHeight * 0.15)
            droplet(center: rightTop, size: dropSize)
            if mood == .hot || mood == .crit || mood == .error {
                droplet(center: NSPoint(x: rect.maxX - pixelWidth * 1.5, y: rect.minY - pixelHeight * 0.45),
                        size: dropSize * 0.86)
            }
        case .ok, .loading:
            break
        }

        if mood == .crit {
            // 眼下两行泪:从眼睛正下方(第 2 行)往下滴,按 tick 循环
            let fall = CGFloat(tick % 9) * pixelHeight * 0.10
            for column in [2.0, 8.0] {
                let tearRect = NSRect(x: rect.minX + pixelWidth * (column + 0.28),
                                      y: rect.minY + pixelHeight * 1.52 + fall,
                                      width: pixelWidth * 0.44, height: pixelHeight * 0.52)
                ClawdSprite.sweatColor.setFill()
                NSBezierPath(roundedRect: tearRect,
                             xRadius: pixelWidth * 0.2, yRadius: pixelWidth * 0.2).fill()
            }
        }
    }


    // MARK: 状态牌与状态动画

    // MARK: 工具颗粒度

    private enum ToolKind { case edit, read, search, list, run, browser, task, plan, skill, notify, generic }

    private func toolKind(_ tool: String?) -> ToolKind {
        let name = (tool ?? "").lowercased()
        if name.contains("senduserfile") || name.contains("notify") { return .notify }
        if name.contains("todo") || name.contains("plan") { return .plan }
        if name.contains("edit") || name.contains("write") || name.contains("patch") { return .edit }
        if name.contains("read") || name.contains("notebook") { return .read }
        if name == "ls" || name.contains("list") || name.contains("dir") { return .list }
        if name.contains("glob") || name.contains("grep") || name.contains("search") { return .search }
        if name.contains("bash") || name.contains("shell") || name.contains("terminal") || name.contains("command") { return .run }
        if name.contains("websearch") || name.contains("webfetch") || name.contains("fetch") || name.contains("browser") { return .browser }
        if name.contains("task") || name.contains("agent") || name.contains("subagent") { return .task }
        if name.contains("skill") { return .skill }
        return .generic
    }

    private func toolLabel(_ tool: String?) -> String {
        switch toolKind(tool) {
        case .edit: return "编辑中"
        case .read: return "读取中"
        case .search: return "搜索中"
        case .list: return "列出中"
        case .run: return "运行中"
        case .browser: return "查找中"
        case .task: return "分派中"
        case .plan: return "更新计划"
        case .skill: return "执行技能"
        case .notify: return "发送中"
        case .generic:
            if let tool = tool, !tool.isEmpty { return "工具 " + String(tool.prefix(6)) }
            return "调用工具"
        }
    }

    private func drawStateBadge(in rect: NSRect, activity: PetActivity, tool: String?) {
        guard activity != .idle else { return }
        let color = activity.accentColor
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor(srgbRed: 0.07, green: 0.075, blue: 0.08, alpha: 0.86).setFill()
        path.fill()
        let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(Double(tick) * 0.35))
        color.withAlphaComponent(0.55 + 0.35 * pulse).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        let iconRect = NSRect(x: rect.minX + 9, y: rect.midY - 8, width: 16, height: 16)
        drawActivityIcon(activity, in: iconRect, color: color, tool: tool)

        let text = activity == .tool ? toolLabel(tool) : activity.label
        drawText(text,
                 in: NSRect(x: rect.minX + 29, y: rect.midY - 8, width: rect.width - 35, height: 16),
                 font: NSFont.systemFont(ofSize: 10.5, weight: .medium), color: color)
    }

    private func drawActivityIcon(_ activity: PetActivity, in rect: NSRect, color: NSColor, tool: String?) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = true
        color.setFill()
        switch activity {
        case .thinking:
            for i in 0..<3 {
                let phase = (tick / 3 + i) % 3
                let alpha = phase == 0 ? 1.0 : (phase == 1 ? 0.55 : 0.25)
                let dot = NSRect(x: rect.minX + CGFloat(i) * 5.2,
                                 y: rect.midY - 1.5 - (i == 1 ? 2 : 0),
                                 width: i == 1 ? 4 : 3, height: i == 1 ? 4 : 3)
                color.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        case .tool:
            NSGraphicsContext.current?.shouldAntialias = false
            color.setFill()
            switch toolKind(tool) {
            case .edit:
                NSBezierPath(rect: NSRect(x: rect.minX + 1, y: rect.minY + 2, width: 10, height: 12)).fill()
                NSBezierPath(rect: NSRect(x: rect.minX + 8, y: rect.minY + 7, width: 3, height: 8)).fill()
            case .read:
                NSBezierPath(rect: NSRect(x: rect.minX + 1, y: rect.minY + 3, width: 6, height: 10)).fill()
                NSBezierPath(rect: NSRect(x: rect.minX + 9, y: rect.minY + 3, width: 6, height: 10)).fill()
            case .search:
                let ring = NSBezierPath(ovalIn: NSRect(x: rect.minX + 2, y: rect.minY + 1, width: 10, height: 10))
                ring.lineWidth = 2
                ring.stroke()
                NSBezierPath(rect: NSRect(x: rect.minX + 9, y: rect.minY + 9, width: 2, height: 6)).fill()
            case .run:
                NSBezierPath(rect: NSRect(x: rect.minX + 1, y: rect.minY + 2, width: 14, height: 12)).fill()
                NSColor.black.withAlphaComponent(0.7).setFill()
                NSBezierPath(rect: NSRect(x: rect.minX + 3, y: rect.minY + 4, width: 10, height: 8)).fill()
                color.setFill()
                NSBezierPath(rect: NSRect(x: rect.minX + 5, y: rect.minY + 6, width: 3, height: 2)).fill()
                NSBezierPath(rect: NSRect(x: rect.minX + 5, y: rect.minY + 9, width: 2, height: 2)).fill()
            case .browser:
                let globe = NSBezierPath(ovalIn: NSRect(x: rect.minX + 1, y: rect.minY + 1, width: 14, height: 14))
                globe.lineWidth = 2
                globe.stroke()
            case .list:
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 1, y: rect.minY + 3, width: 9, height: 11),
                             xRadius: 1, yRadius: 1).fill()
                NSColor.black.withAlphaComponent(0.7).setFill()
                for i in 0..<3 {
                    NSBezierPath(rect: NSRect(x: rect.minX + 3, y: rect.minY + 5 + CGFloat(i) * 3,
                                              width: 5, height: 1.2)).fill()
                }
            case .task:
                for i in 0..<3 {
                    NSBezierPath(ovalIn: NSRect(x: rect.minX + 1 + CGFloat(i) * 5, y: rect.midY - 2,
                                                width: 4, height: 4)).fill()
                }
                NSBezierPath(rect: NSRect(x: rect.minX + 2, y: rect.minY + 2, width: 11, height: 2)).fill()
            case .plan:
                for i in 0..<3 {
                    NSBezierPath(rect: NSRect(x: rect.minX + 1, y: rect.minY + 2 + CGFloat(i) * 4.5,
                                              width: 3, height: 3)).fill()
                    NSBezierPath(rect: NSRect(x: rect.minX + 6, y: rect.minY + 3 + CGFloat(i) * 4.5,
                                              width: 9, height: 1.5)).fill()
                }
            case .skill:
                NSBezierPath(rect: NSRect(x: rect.midX - 1, y: rect.minY + 2, width: 2, height: 12)).fill()
                NSBezierPath(rect: NSRect(x: rect.minX + 2, y: rect.midY - 1, width: 12, height: 2)).fill()
            case .notify:
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 1, y: rect.minY + 3, width: 14, height: 10),
                             xRadius: 2, yRadius: 2).fill()
                NSColor.black.withAlphaComponent(0.7).setFill()
                NSBezierPath(rect: NSRect(x: rect.minX + 3, y: rect.minY + 5, width: 10, height: 1.5)).fill()
            case .generic:
                NSBezierPath(rect: NSRect(x: rect.minX + 2, y: rect.midY - 5, width: 3, height: 11)).fill()
                NSBezierPath(rect: NSRect(x: rect.minX + 1, y: rect.midY - 8, width: 10, height: 4)).fill()
                NSBezierPath(rect: NSRect(x: rect.minX + 4, y: rect.midY + 3, width: 6, height: 3)).fill()
            }
        case .working:
            NSGraphicsContext.current?.shouldAntialias = false
            for i in 0..<3 {
                let w = CGFloat(6 + (i % 2) * 4)
                NSBezierPath(rect: NSRect(x: rect.minX + CGFloat(i % 2) * 2, y: rect.midY - 6 + CGFloat(i) * 5,
                                          width: w, height: 3)).fill()
            }
        case .waitingApproval:
            // 小审批板:板 + 一个“?”
            NSGraphicsContext.current?.shouldAntialias = false
            NSBezierPath(rect: NSRect(x: rect.minX + 2, y: rect.minY + 1, width: 11, height: 14)).fill()
            NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: rect.minX + 4, y: rect.minY + 3, width: 7, height: 10)).fill()
            color.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX + 6, y: rect.minY + 5, width: 3, height: 2)).fill()
            NSBezierPath(rect: NSRect(x: rect.minX + 6, y: rect.minY + 9, width: 3, height: 2)).fill()
            NSBezierPath(rect: NSRect(x: rect.minX + 7, y: rect.minY + 12, width: 3, height: 2)).fill()
        case .waitingReply:
            // 小对话气泡 + 三个点
            NSGraphicsContext.current?.shouldAntialias = false
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 1, y: rect.minY + 3, width: 13, height: 9),
                         xRadius: 4, yRadius: 4).fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 12))
            tail.line(to: NSPoint(x: rect.minX + 2, y: rect.minY + 16))
            tail.line(to: NSPoint(x: rect.minX + 7, y: rect.minY + 12))
            tail.fill()
            NSColor.white.withAlphaComponent(0.9).setFill()
            for i in 0..<3 {
                let dot = NSRect(x: rect.minX + 4 + CGFloat(i) * 3.5, y: rect.minY + 6.5, width: 2, height: 2)
                NSBezierPath(rect: dot).fill()
            }
        case .done:
            NSGraphicsContext.current?.shouldAntialias = false
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 2, y: rect.midY + 2))
            check.line(to: NSPoint(x: rect.minX + 6, y: rect.midY + 6))
            check.line(to: NSPoint(x: rect.minX + 14, y: rect.midY - 5))
            check.lineWidth = 3
            check.lineCapStyle = .square
            color.setStroke()
            check.stroke()
        case .error:
            NSGraphicsContext.current?.shouldAntialias = false
            NSBezierPath(rect: NSRect(x: rect.midX - 2, y: rect.midY - 7, width: 4, height: 10)).fill()
            NSBezierPath(rect: NSRect(x: rect.midX - 2, y: rect.midY + 5, width: 4, height: 4)).fill()
        case .idle:
            break
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawActivityEffects(in rect: NSRect, activity: PetActivity, tool: String?) {
        NSGraphicsContext.saveGraphicsState()
        switch activity {
        case .thinking:
            // 头顶三个思考气泡,向上飘(在气泡与蟹壳之间)
            for i in 0..<3 {
                let phase = (tick / 4 + i) % 3
                let alpha = 0.9 - Double(phase) * 0.22
                let size = CGFloat(6 - phase)
                let x = rect.midX - 22 + CGFloat(i) * 15
                let y = rect.minY - 12 - CGFloat(phase) * 3
                activity.accentColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
                NSBezierPath(ovalIn: NSRect(x: x - 2, y: y + size + 5, width: 3, height: 3)).fill()
            }
        case .working:
            drawWorkingDesk(in: rect)
        case .tool:
            drawToolProp(in: rect, tool: tool)
        case .waitingApproval:
            drawApprovalBoard(in: rect)
        case .waitingReply:
            drawReplyBubble(in: rect)
        case .done:
            drawCelebration(in: rect)
        case .error:
            drawErrorMark(in: rect)
        case .idle:
            drawCoffee(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 工作中:迷你笔记本屏幕 + 键盘,两只小手臂在键盘上敲
    private func drawWorkingDesk(in rect: NSRect) {
        let cx = rect.midX
        let screen = NSRect(x: cx - 34, y: rect.maxY - 58, width: 68, height: 40)
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: screen, xRadius: 4, yRadius: 4).fill()
        NSColor(white: 0.38, alpha: 1).setStroke()
        let bezel = NSBezierPath(roundedRect: screen.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
        bezel.lineWidth = 1.5
        bezel.stroke()

        let codeColors: [NSColor] = [
            NSColor(srgbRed: 0.36, green: 0.78, blue: 0.56, alpha: 1),
            NSColor(srgbRed: 0.39, green: 0.68, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.94, green: 0.72, blue: 0.30, alpha: 1),
        ]
        for i in 0..<5 {
            let w = CGFloat(16 + ((tick + i * 7) % 24))
            let line = NSRect(x: screen.minX + 6, y: screen.minY + 5 + CGFloat(i) * 6.2,
                              width: min(w, screen.width - 12), height: 2.6)
            codeColors[i % codeColors.count].withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: line, xRadius: 1.3, yRadius: 1.3).fill()
        }
        if (tick / 3) % 2 == 0 {
            NSColor.white.withAlphaComponent(0.85).setFill()
            let lineIndex = (tick / 3) % 5
            let cursor = NSRect(x: screen.minX + 6 + CGFloat(18 + (tick / 3) % 16),
                                y: screen.minY + 5 + CGFloat(lineIndex) * 6.2 + 3.6,
                                width: 2.5, height: 8)
            NSBezierPath(rect: cursor).fill()
        }

        let keyboard = NSRect(x: cx - 46, y: rect.maxY - 12, width: 92, height: 12)
        NSColor(srgbRed: 0.19, green: 0.20, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: keyboard, xRadius: 3, yRadius: 3).fill()
        for row in 0..<2 {
            for col in 0..<12 {
                let key = NSRect(x: keyboard.minX + 3 + CGFloat(col) * 7.2,
                                 y: keyboard.minY + 2.5 + CGFloat(row) * 4.6,
                                 width: 5.4, height: 3.2)
                if (tick + col * 3 + row) % 7 == 0 {
                    PetActivity.working.accentColor.withAlphaComponent(0.95).setFill()
                } else {
                    NSColor(white: 0.48, alpha: 1).setFill()
                }
                NSBezierPath(roundedRect: key, xRadius: 1, yRadius: 1).fill()
            }
        }

        for side in [-1.0, 1.0] {
            let lift = CGFloat((tick + (side > 0 ? 1 : 0)) % 2) * 3
            let arm = NSRect(x: cx + CGFloat(side) * 45 - 3, y: rect.maxY - 42 + lift,
                             width: 6, height: 30)
            ClawdSprite.bodyColor.setFill()
            NSBezierPath(rect: arm).fill()
            // 手按在键盘上:加一圈深色描边,避免和身体橙色糊在一起
            let hand = NSRect(x: arm.minX - 2, y: keyboard.minY - 4 + lift * 0.4,
                              width: 10, height: 5)
            ClawdSprite.bodyColor.setFill()
            NSBezierPath(rect: hand).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let border = NSBezierPath(rect: hand)
            border.lineWidth = 1
            border.stroke()
        }
    }

    /// 调用工具:从壳右侧伸出一只小手臂,握住扳手敲击,火花四溅
    private func drawToolAction(in rect: NSRect) {
        let shoulder = NSPoint(x: rect.maxX - 26, y: rect.minY + 40)
        ClawdSprite.bodyColor.setFill()
        NSBezierPath(rect: NSRect(x: shoulder.x, y: shoulder.y, width: 6, height: 24)).fill()
        let pivot = NSPoint(x: rect.maxX - 12, y: rect.minY + 62)
        let angle = sin(Double(tick) * 0.85) * 0.55
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: pivot.x, yBy: pivot.y)
        transform.rotate(byRadians: CGFloat(angle))
        transform.concat()
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor(srgbRed: 0.80, green: 0.83, blue: 0.88, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: -2, y: 0, width: 4, height: 15)).fill()
        NSBezierPath(rect: NSRect(x: -7, y: 12, width: 14, height: 5)).fill()
        NSBezierPath(rect: NSRect(x: -7, y: 9, width: 4, height: 5)).fill()
        NSBezierPath(rect: NSRect(x: 3, y: 9, width: 4, height: 5)).fill()
        NSGraphicsContext.restoreGraphicsState()

        for i in 0..<5 {
            if (tick + i * 2) % 5 < 3 {
                let x = pivot.x + CGFloat(10 + (i % 2) * 8)
                let y = pivot.y - CGFloat(6 + i * 4)
                NSColor(srgbRed: 0.98, green: 0.82, blue: 0.28, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: x, y: y, width: 3, height: 3)).fill()
            }
        }
    }

    /// 等待确认:抱着一只小怀表,秒针转动
    private func drawWaitingClock(in rect: NSRect) {
        let center = NSPoint(x: rect.minX - 56, y: rect.minY + 92)
        let radius: CGFloat = 17
        let face = NSRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        NSColor(srgbRed: 0.15, green: 0.16, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(ovalIn: face.insetBy(dx: -2, dy: -2)).fill()
        NSColor(srgbRed: 0.92, green: 0.91, blue: 0.86, alpha: 1).setFill()
        NSBezierPath(ovalIn: face).fill()
        NSColor(srgbRed: 0.95, green: 0.72, blue: 0.25, alpha: 1).setStroke()
        let ring = NSBezierPath(ovalIn: face.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 1.5
        ring.stroke()
        for i in 0..<12 {
            let angle = Double(i) * .pi / 6
            let inner = NSPoint(x: center.x + CGFloat(cos(angle)) * (radius - 4),
                                y: center.y + CGFloat(sin(angle)) * (radius - 4))
            let outer = NSPoint(x: center.x + CGFloat(cos(angle)) * (radius - 1.5),
                                y: center.y + CGFloat(sin(angle)) * (radius - 1.5))
            let tickPath = NSBezierPath()
            tickPath.move(to: inner)
            tickPath.line(to: outer)
            tickPath.lineWidth = 1
            NSColor(white: 0.35, alpha: 1).setStroke()
            tickPath.stroke()
        }
        let minuteAngle = Double(tick) * 0.12
        let hourAngle = Double(tick) * 0.01
        func hand(_ angle: Double, length: CGFloat, width: CGFloat) {
            let path = NSBezierPath()
            path.move(to: center)
            path.line(to: NSPoint(x: center.x + CGFloat(sin(angle)) * length,
                                  y: center.y - CGFloat(cos(angle)) * length))
            path.lineWidth = width
            path.lineCapStyle = .round
            NSColor(white: 0.2, alpha: 1).setStroke()
            path.stroke()
        }
        hand(hourAngle, length: radius * 0.45, width: 2)
        hand(minuteAngle, length: radius * 0.7, width: 1.5)
        NSColor(srgbRed: 0.95, green: 0.72, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: center.x - 2, y: face.minY - 4, width: 4, height: 4)).fill()
    }

    /// 空闲:右手端着一杯咖啡,偶尔抬起来吸一口,杯口冒热气
    private func drawCoffee(in rect: NSRect) {
        let cycle = (tick + 18) % 50  // 让启动瞬间是“端着咖啡”的静止态
        let sipping = cycle < 10
        let lift = sipping ? CGFloat(cycle) * 0.9 : 0
        let cupWidth: CGFloat = 26
        let cupHeight: CGFloat = 22
        let cupX = rect.maxX - 40
        let cupY = rect.minY + 70 - lift
        let cup = NSRect(x: cupX, y: cupY, width: cupWidth, height: cupHeight)

        // 从壳右侧伸出的手臂
        ClawdSprite.bodyColor.setFill()
        NSBezierPath(rect: NSRect(x: rect.maxX - 58, y: cup.midY - 2,
                                  width: 22, height: 6)).fill()

        // 配色刻意避开小螃蟹的橙色:白瓷 + 深蓝花纹 + 蓝色把手/杯垫
        let navy = NSColor(srgbRed: 0.13, green: 0.27, blue: 0.48, alpha: 1)
        let blue = NSColor(srgbRed: 0.32, green: 0.60, blue: 0.90, alpha: 1)
        let cream = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.88, alpha: 1)

        // 杯垫(不喝时):深蓝,和橙色壳拉开
        if !sipping {
            NSColor(srgbRed: 0.12, green: 0.18, blue: 0.30, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: cup.minX - 5, y: cup.maxY - 2,
                                        width: cup.width + 10, height: 7)).fill()
            blue.withAlphaComponent(0.85).setStroke()
            let saucerRing = NSBezierPath(ovalIn: NSRect(x: cup.minX - 2, y: cup.maxY - 1,
                                                          width: cup.width + 4, height: 5))
            saucerRing.lineWidth = 1
            saucerRing.stroke()
        }

        NSGraphicsContext.saveGraphicsState()
        if sipping {
            let transform = NSAffineTransform()
            transform.translateX(by: cup.midX, yBy: cup.maxY)
            transform.rotate(byRadians: -0.28)
            transform.translateX(by: -cup.midX, yBy: -cup.maxY)
            transform.concat()
        }

        // 杯身:白瓷 + 深蓝描边
        let cupPath = NSBezierPath(roundedRect: cup, xRadius: 5, yRadius: 5)
        cream.setFill()
        cupPath.fill()
        NSColor(srgbRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.9).setStroke()
        cupPath.lineWidth = 1.2
        cupPath.stroke()

        // 杯身上的蓝色花纹:两道横条 + 中段杯套上的白点
        blue.setFill()
        NSBezierPath(roundedRect: NSRect(x: cup.minX + 3, y: cup.minY + 6,
                                         width: cup.width - 6, height: 3.5),
                     xRadius: 1.5, yRadius: 1.5).fill()
        NSBezierPath(roundedRect: NSRect(x: cup.minX + 3, y: cup.minY + 15,
                                         width: cup.width - 6, height: 3.5),
                     xRadius: 1.5, yRadius: 1.5).fill()

        // 把手:蓝色,和白瓷杯身区分
        blue.setStroke()
        let handle = NSBezierPath(ovalIn: NSRect(x: cup.maxX - 4, y: cup.midY - 8,
                                                width: 12, height: 15))
        handle.lineWidth = 3
        handle.stroke()

        // 咖啡液面
        NSColor(srgbRed: 0.24, green: 0.14, blue: 0.08, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: cup.minX + 3, y: cup.minY + 3,
                                    width: cup.width - 6, height: 6)).fill()

        // 中段深蓝杯套 + 白点花纹
        navy.setFill()
        NSBezierPath(roundedRect: NSRect(x: cup.minX + 1, y: cup.midY - 3,
                                         width: cup.width - 2, height: 8), xRadius: 2, yRadius: 2).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        for i in 0..<3 {
            let dot = NSRect(x: cup.minX + 6 + CGFloat(i) * 7, y: cup.midY - 0.5,
                             width: 2.2, height: 2.2)
            NSBezierPath(ovalIn: dot).fill()
        }

        // 握着杯子的手(橙色是螃蟹的手,保留)
        let hand = NSRect(x: cup.minX - 5, y: cup.midY + 1, width: 9, height: 8)
        ClawdSprite.bodyColor.setFill()
        NSBezierPath(roundedRect: hand, xRadius: 2, yRadius: 2).fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        let handBorder = NSBezierPath(roundedRect: hand, xRadius: 2, yRadius: 2)
        handBorder.lineWidth = 1
        handBorder.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // 热气
        let steamBase = sipping ? cup.minY - 2 : cup.minY - 4
        for i in 0..<3 {
            let phase = (tick / 4 + i) % 3
            let x = cup.midX - 7 + CGFloat(i) * 7
            let y = steamBase - 4 - CGFloat(phase) * 4
            NSColor.white.withAlphaComponent(0.38 - Double(phase) * 0.08).setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: y))
            path.curve(to: NSPoint(x: x, y: y - 7),
                       controlPoint1: NSPoint(x: x - 4, y: y - 2.5),
                       controlPoint2: NSPoint(x: x + 4, y: y - 4.5))
            path.lineWidth = 1.4
            path.stroke()
        }
    }

    /// 调用工具:左侧小道具随工具类型变化(编辑=纸笔,读取=书,搜索=放大镜,运行=终端)
    private func drawToolProp(in rect: NSRect, tool: String?) {
        let kind = toolKind(tool)
        let panel = NSRect(x: rect.minX - 66, y: rect.minY + 72, width: 48, height: 46)
        let accent: NSColor
        switch kind {
        case .edit: accent = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 1)
        case .read: accent = NSColor(srgbRed: 0.42, green: 0.72, blue: 0.96, alpha: 1)
        case .search: accent = NSColor(srgbRed: 0.55, green: 0.82, blue: 0.55, alpha: 1)
        case .run: accent = NSColor(srgbRed: 0.45, green: 0.86, blue: 0.58, alpha: 1)
        case .browser: accent = NSColor(srgbRed: 0.60, green: 0.68, blue: 0.98, alpha: 1)
        case .list: accent = NSColor(srgbRed: 0.40, green: 0.82, blue: 0.82, alpha: 1)
        case .task: accent = NSColor(srgbRed: 0.86, green: 0.54, blue: 0.92, alpha: 1)
        case .plan: accent = NSColor(srgbRed: 0.96, green: 0.78, blue: 0.34, alpha: 1)
        case .skill: accent = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.45, alpha: 1)
        case .notify: accent = NSColor(srgbRed: 0.45, green: 0.78, blue: 0.95, alpha: 1)
        case .generic: accent = NSColor(srgbRed: 0.80, green: 0.82, blue: 0.88, alpha: 1)
        }

        // 托着道具的小手臂
        ClawdSprite.bodyColor.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX - 20, y: panel.midY - 3, width: 24, height: 6)).fill()

        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6).fill()
        accent.withAlphaComponent(0.55).setStroke()
        let border = NSBezierPath(roundedRect: panel.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
        border.lineWidth = 1.2
        border.stroke()

        switch kind {
        case .edit:
            let paper = NSRect(x: panel.minX + 6, y: panel.minY + 6, width: panel.width - 12, height: panel.height - 12)
            NSColor(srgbRed: 0.94, green: 0.93, blue: 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: paper, xRadius: 2, yRadius: 2).fill()
            accent.setFill()
            for i in 0..<4 {
                let w = CGFloat(10 + ((tick + i * 5) % 14))
                NSBezierPath(rect: NSRect(x: paper.minX + 3, y: paper.minY + 4 + CGFloat(i) * 5,
                                          width: min(w, paper.width - 6), height: 2)).fill()
            }
            // 铅笔在纸上移动
            let pencilX = paper.minX + 6 + CGFloat((tick / 2) % 18)
            NSColor(srgbRed: 0.98, green: 0.80, blue: 0.28, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: pencilX, y: paper.midY - 2, width: 12, height: 3)).fill()
            NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: pencilX, y: paper.midY - 3, width: 2, height: 5)).fill()
        case .read:
            NSColor(srgbRed: 0.94, green: 0.93, blue: 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: panel.minX + 4, y: panel.minY + 8, width: 18, height: panel.height - 16), xRadius: 2, yRadius: 2).fill()
            NSBezierPath(roundedRect: NSRect(x: panel.maxX - 22, y: panel.minY + 8, width: 18, height: panel.height - 16), xRadius: 2, yRadius: 2).fill()
            accent.setFill()
            NSBezierPath(rect: NSRect(x: panel.midX - 1, y: panel.minY + 8, width: 2, height: panel.height - 16)).fill()
            for i in 0..<4 {
                let y = panel.minY + 13 + CGFloat(i) * 6
                NSBezierPath(rect: NSRect(x: panel.minX + 7, y: y, width: 10, height: 1.5)).fill()
                NSBezierPath(rect: NSRect(x: panel.maxX - 17, y: y, width: 10, height: 1.5)).fill()
            }
        case .search:
            NSColor(srgbRed: 0.90, green: 0.89, blue: 0.84, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: panel.minX + 8, y: panel.minY + 15, width: 26, height: 20), xRadius: 2, yRadius: 2).fill()
            NSColor(srgbRed: 0.55, green: 0.54, blue: 0.50, alpha: 1).setFill()
            for i in 0..<4 {
                NSBezierPath(rect: NSRect(x: panel.minX + 11, y: panel.minY + 18 + CGFloat(i) * 4, width: 20, height: 1.5)).fill()
            }
            let glassCenter = NSPoint(x: panel.midX + 4, y: panel.minY + 15 + CGFloat((tick / 2) % 12))
            let ring = NSBezierPath(ovalIn: NSRect(x: glassCenter.x - 7, y: glassCenter.y - 7, width: 14, height: 14))
            ring.lineWidth = 2.2
            accent.setStroke()
            ring.stroke()
            NSBezierPath(rect: NSRect(x: glassCenter.x + 5, y: glassCenter.y + 5, width: 3, height: 10)).fill()
        case .run:
            NSColor(srgbRed: 0.06, green: 0.08, blue: 0.09, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: panel.minX + 5, y: panel.minY + 6, width: panel.width - 10, height: panel.height - 12), xRadius: 3, yRadius: 3).fill()
            accent.withAlphaComponent(0.9).setStroke()
            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: panel.minX + 11, y: panel.minY + 15))
            prompt.line(to: NSPoint(x: panel.minX + 17, y: panel.minY + 19))
            prompt.line(to: NSPoint(x: panel.minX + 11, y: panel.minY + 23))
            prompt.lineWidth = 2
            prompt.stroke()
            accent.setFill()
            NSBezierPath(rect: NSRect(x: panel.minX + 21, y: panel.minY + 20, width: 15, height: 2)).fill()
            if (tick / 3) % 2 == 0 {
                NSBezierPath(rect: NSRect(x: panel.minX + 38, y: panel.minY + 17, width: 2, height: 7)).fill()
            }
        case .browser:
            let globe = NSBezierPath(ovalIn: NSRect(x: panel.minX + 10, y: panel.minY + 9, width: 28, height: 28))
            globe.lineWidth = 2
            accent.setStroke()
            globe.stroke()
            let lat = NSBezierPath(ovalIn: NSRect(x: panel.minX + 10, y: panel.minY + 18, width: 28, height: 10))
            lat.lineWidth = 1.5
            lat.stroke()
            let lon = NSBezierPath(ovalIn: NSRect(x: panel.minX + 18, y: panel.minY + 9, width: 12, height: 28))
            lon.lineWidth = 1.5
            lon.stroke()
        case .list:
            NSColor(srgbRed: 0.90, green: 0.89, blue: 0.84, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: panel.minX + 11, y: panel.minY + 8, width: 26, height: 30),
                         xRadius: 2, yRadius: 2).fill()
            accent.setFill()
            NSBezierPath(rect: NSRect(x: panel.minX + 15, y: panel.minY + 13, width: 18, height: 2)).fill()
            for i in 0..<4 {
                NSBezierPath(rect: NSRect(x: panel.minX + 15, y: panel.minY + 19 + CGFloat(i) * 4,
                                          width: 11 + CGFloat((i * 3) % 8), height: 1.5)).fill()
            }
        case .task:
            accent.setStroke()
            NSBezierPath(ovalIn: NSRect(x: panel.minX + 8, y: panel.minY + 10, width: 8, height: 8)).stroke()
            NSBezierPath(ovalIn: NSRect(x: panel.minX + 32, y: panel.minY + 10, width: 8, height: 8)).stroke()
            NSBezierPath(ovalIn: NSRect(x: panel.minX + 20, y: panel.minY + 26, width: 8, height: 8)).stroke()
            let link = NSBezierPath()
            link.move(to: NSPoint(x: panel.minX + 16, y: panel.minY + 14))
            link.line(to: NSPoint(x: panel.minX + 20, y: panel.minY + 28))
            link.line(to: NSPoint(x: panel.minX + 32, y: panel.minY + 14))
            link.lineWidth = 1.5
            link.stroke()
        case .plan:
            for i in 0..<3 {
                let box = NSRect(x: panel.minX + 12, y: panel.minY + 10 + CGFloat(i) * 9, width: 5, height: 5)
                accent.setStroke()
                let boxPath = NSBezierPath(rect: box)
                boxPath.lineWidth = 1.5
                boxPath.stroke()
                accent.setFill()
                NSBezierPath(rect: NSRect(x: panel.minX + 21, y: panel.minY + 12 + CGFloat(i) * 9,
                                          width: 14, height: 1.6)).fill()
            }
        case .skill:
            accent.setFill()
            NSBezierPath(rect: NSRect(x: panel.midX - 2, y: panel.minY + 8, width: 4, height: 28)).fill()
            NSBezierPath(rect: NSRect(x: panel.minX + 10, y: panel.midY - 2, width: 28, height: 4)).fill()
            NSBezierPath(ovalIn: NSRect(x: panel.midX - 3, y: panel.midY - 3, width: 6, height: 6)).fill()
        case .notify:
            NSColor(srgbRed: 0.92, green: 0.91, blue: 0.86, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: panel.minX + 8, y: panel.minY + 13, width: 32, height: 20),
                         xRadius: 2, yRadius: 2).fill()
            accent.setStroke()
            let flap = NSBezierPath()
            flap.move(to: NSPoint(x: panel.minX + 8, y: panel.minY + 13))
            flap.line(to: NSPoint(x: panel.midX, y: panel.minY + 23))
            flap.line(to: NSPoint(x: panel.minX + 40, y: panel.minY + 13))
            flap.lineWidth = 1.5
            flap.stroke()
        case .generic:
            NSColor(srgbRed: 0.80, green: 0.82, blue: 0.88, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: panel.midX - 2, y: panel.minY + 10, width: 5, height: 22)).fill()
            NSBezierPath(rect: NSRect(x: panel.midX - 8, y: panel.minY + 24, width: 17, height: 6)).fill()
        }
    }

    /// 等待审批:左边一块小审批板,红色“待批”章反复盖下
    private func drawApprovalBoard(in rect: NSRect) {
        let board = NSRect(x: rect.minX - 66, y: rect.minY + 62, width: 50, height: 62)
        NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: board, xRadius: 6, yRadius: 6).fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: board.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
        border.lineWidth = 1.2
        border.stroke()

        let paper = board.insetBy(dx: 4, dy: 4)
        NSColor(srgbRed: 0.93, green: 0.92, blue: 0.87, alpha: 1).setFill()
        NSBezierPath(roundedRect: paper, xRadius: 3, yRadius: 3).fill()
        // 夹子
        NSColor(white: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: board.midX - 7, y: board.minY - 2, width: 14, height: 5),
                     xRadius: 2, yRadius: 2).fill()
        // 纸上的字/线
        NSColor(white: 0.55, alpha: 1).setFill()
        for i in 0..<3 {
            NSBezierPath(rect: NSRect(x: paper.minX + 5, y: paper.minY + 8 + CGFloat(i) * 5,
                                      width: paper.width - 10, height: 2)).fill()
        }
        drawText("?", in: NSRect(x: paper.minX + 4, y: paper.minY + 26, width: paper.width - 8, height: 26),
                 font: NSFont.systemFont(ofSize: 22, weight: .bold),
                 color: PetActivity.waitingApproval.accentColor, alignment: .center)

        // 盖章:从上往下落
        let phase = tick % 26
        let stampY = paper.minY + 6 + CGFloat(min(phase, 14))
        let stamp = NSRect(x: paper.maxX - 20, y: stampY, width: 17, height: 12)
        PetActivity.waitingApproval.accentColor.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: stamp, xRadius: 2, yRadius: 2).fill()
        drawText("待批", in: stamp, font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
                 color: .white, alignment: .center)

        // 从左壳伸出的手臂扶着板
        ClawdSprite.bodyColor.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX - 20, y: rect.minY + 92, width: 24, height: 6)).fill()
    }

    /// 等待回复:左边一个对话气泡,三个点循环闪
    private func drawReplyBubble(in rect: NSRect) {
        let bubble = NSRect(x: rect.minX - 70, y: rect.minY + 72, width: 52, height: 36)
        NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 10, yRadius: 10).fill()
        PetActivity.waitingReply.accentColor.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: bubble.insetBy(dx: 0.75, dy: 0.75), xRadius: 9.5, yRadius: 9.5)
        border.lineWidth = 1.2
        border.stroke()

        // 尾巴指向螃蟹
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bubble.maxX - 6, y: bubble.maxY - 2))
        tail.line(to: NSPoint(x: bubble.maxX + 12, y: bubble.maxY + 3))
        tail.line(to: NSPoint(x: bubble.maxX - 8, y: bubble.maxY + 8))
        tail.close()
        NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.98).setFill()
        tail.fill()

        // 三个跳动的点
        for i in 0..<3 {
            let phase = (tick / 3 + i) % 3
            let alpha = phase == 0 ? 1.0 : (phase == 1 ? 0.55 : 0.28)
            let dot = NSRect(x: bubble.minX + 11 + CGFloat(i) * 11,
                             y: bubble.midY - 2 - CGFloat(phase == 0 ? 2 : 0),
                             width: 5, height: 5)
            PetActivity.waitingReply.accentColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        // 扶着气泡的小手臂
        ClawdSprite.bodyColor.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX - 24, y: rect.minY + 92, width: 28, height: 6)).fill()
    }

    /// 完成:跳起来 + 举起手臂 + 星星
    private func drawCelebration(in rect: NSRect) {
        ClawdSprite.bodyColor.setFill()
        for side in [-1.0, 1.0] {
            let x = rect.midX + CGFloat(side) * 48 - 3
            let arm = NSRect(x: x, y: rect.minY - 10, width: 6, height: 20)
            NSBezierPath(rect: arm).fill()
        }
        for i in 0..<8 {
            let phase = (tick / 3 + i) % 7
            let x = rect.minX + CGFloat(8 + (i * 31) % Int(rect.width - 16))
            let y = rect.minY - 16 + CGFloat(phase * 6)
            NSColor(srgbRed: 0.98, green: 0.85, blue: 0.35, alpha: 0.95 - Double(phase) * 0.1).setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: 4, height: 4)).fill()
        }
    }

    /// 出错:头顶红色感叹号 + 发抖
    private func drawErrorMark(in rect: NSRect) {
        let color = PetActivity.error.accentColor
        color.withAlphaComponent(0.95).setFill()
        NSBezierPath(rect: NSRect(x: rect.midX - 3, y: rect.minY - 16, width: 6, height: 12)).fill()
        NSBezierPath(rect: NSRect(x: rect.midX - 3, y: rect.minY - 1, width: 6, height: 5)).fill()
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                          alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    // MARK: 命中/交互

    private func hitTestPart(_ point: NSPoint) -> HitPart {
        let l = pixelLayout()
        let slack = 4 * l.textScale
        if l.closeRect.insetBy(dx: -slack, dy: -slack).contains(point) { return .close }
        if l.bubbleRect.contains(point) { return .bubble }
        // 气泡下方的整块区域(螃蟹 + 状态牌 + 空白)都算“点宠物”→ 刷新额度
        if point.y >= l.bubbleRect.maxY - 2 { return .crab }
        return .none
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef = trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let part = hitTestPart(point)
        if part != hoverPart {
            hoverPart = part
            needsDisplay = true
        }
        switch part {
        case .crab: NSCursor.openHand.set()
        case .bubble: NSCursor.pointingHand.set()
        case .close: NSCursor.pointingHand.set()
        case .none: NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverPart = .none
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        clickPart = hitTestPart(mouseDownPoint)
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        dragMoved = false
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let deltaX = current.x - dragStartMouse.x
        let deltaY = current.y - dragStartMouse.y
        if !dragMoved && hypot(deltaX, deltaY) > 6 {
            dragMoved = true
            if clickPart == .crab { NSCursor.closedHand.set() }
        }
        guard dragMoved, let window = window else { return }
        var origin = NSPoint(x: dragStartOrigin.x + deltaX, y: dragStartOrigin.y + deltaY)
        if let clampOrigin = clampOrigin { origin = clampOrigin(origin) }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragMoved = false; clickPart = .none; isDragging = false }
        if dragMoved {
            delegate?.petViewDidFinishDrag(self)
            return
        }
        switch clickPart {
        case .crab:
            scurryTicks = 14 // 点一下螃蟹:原地兴奋碎步约 2.8s,同时刷新
            delegate?.petViewRequestRefresh(self)
        case .bubble: delegate?.petViewCyclePage(self)
        case .close: delegate?.petViewRequestQuit(self)
        case .none: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.petViewRequestMenu(self, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // 普通滚轮留给 Claude 页面滚动;Option=宠物大小,Option+Shift=字体大小
        guard event.modifierFlags.contains(.option) else { return }
        guard abs(event.scrollingDeltaY) > 0.05 else { return }
        let delta = event.scrollingDeltaY > 0 ? 1.0 : -1.0
        if event.modifierFlags.contains(.shift) {
            delegate?.petViewAdjustTextScale(self, delta: delta)
        } else {
            delegate?.petViewAdjustScale(self, delta: delta)
        }
    }
}

// MARK: - 应用控制器

// MARK: - 跟随 Claude App 窗口

/// 跟踪 Claude 桌面 App 的主窗口(CGWindowList,不需要屏幕录制权限读 owner/bounds),
/// 把宠物窗口限制/跟随在 Claude 窗口内 —— 视觉上"住在 Claude Code App 里"。
final class ClaudeWindowTracker {
    struct Info: Equatable {
        let pid: pid_t
        let cgBounds: CGRect
        let appKitFrame: NSRect
    }

    private var timer: Timer?
    private var handler: ((Info?) -> Void)?
    private var lastInfo: Info?
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    static var mainScreenHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
    }

    static func cgRect(fromAppKit rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    static func appKitRect(fromCG rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: mainScreenHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    func start(handler: @escaping (Info?) -> Void) {
        self.handler = handler
        refresh()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    static func findCurrent() -> Info? {
        let claude = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == claudeBundleID
        }
        guard let pid = claude?.processIdentifier else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var best: CGRect?
        for window in windows {
            let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            guard ownerPID == pid else { continue }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = number(bounds["X"]),
                  let y = number(bounds["Y"]),
                  let width = number(bounds["Width"]),
                  let height = number(bounds["Height"]),
                  width > 200, height > 200 else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if best == nil || rect.width * rect.height > best!.width * best!.height {
                best = rect
            }
        }
        guard let cgBounds = best else { return nil }
        return Info(pid: pid, cgBounds: cgBounds, appKitFrame: appKitRect(fromCG: cgBounds))
    }

    private func refresh() {
        let info = Self.findCurrent()
        if info != lastInfo {
            lastInfo = info
            handler?(info)
        } else if lastInfo == nil {
            handler?(info)
        }
    }

    private static func number(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber { return CGFloat(truncating: number) }
        if let double = value as? Double { return CGFloat(double) }
        return nil
    }

    private func deliver(_ info: Info?) {
        if info == lastInfo { return }
        lastInfo = info
        handler?(info)
    }

    static func isClaudeFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
    }

    static func isClaudeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == claudeBundleID && !$0.isTerminated }
    }

    static func isFullscreenBounds(_ cgBounds: CGRect) -> Bool {
        // Claude 原生全屏:窗口宽度占满屏幕,高度到 visibleFrame(菜单栏仍可能在)
        NSScreen.screens.contains { screen in
            abs(cgBounds.width - screen.frame.width) < 4 &&
            cgBounds.height >= screen.visibleFrame.height - 4
        }
    }
}

/// 读取 Claude Code hooks 写入的状态文件(claude-activity.json),
/// 把「思考中 / 调用工具 / 工作中 / 等待确认 / 完成」映射成宠物动画状态。
final class ClaudeActivityWatcher {
    private var timer: Timer?
    private var last: (PetActivity, String?)?
    private var handler: ((PetActivity, String?) -> Void)?
    private let fileURL = appSupportDir.appendingPathComponent("claude-activity.json")

    func start(handler: @escaping (PetActivity, String?) -> Void) {
        self.handler = handler
        refresh()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stateRaw = raw["state"] as? String,
              let state = PetActivity(rawValue: stateRaw) else {
            deliver(.idle, nil)
            return
        }
        let ts = (raw["ts"] as? Double) ?? 0
        let age = Date().timeIntervalSince1970 - ts / 1000
        let tool = (raw["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastTool = (raw["last_tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastToolTs = (raw["last_tool_ts"] as? Double) ?? 0
        let lastToolAge = Date().timeIntervalSince1970 - lastToolTs / 1000
        var effective = state
        var effectiveTool = tool
        // 快速工具(Edit/Read 的 Pre/Post 可能只差几十毫秒):用 last_tool 保证
        // 至少展示 1.2s 的“编辑中/读取中/…”,避免轮询只看到 PostToolUse 直接跳 working。
        if let last = lastTool, !last.isEmpty, lastToolAge >= 0, lastToolAge < 1.2 {
            effective = .tool
            effectiveTool = last
        } else {
            // 工具执行期间保持按工具细分的状态(编辑中/读取中/搜索中/运行中…),
            // 直到 PostToolUse 才转 working;不要 0.6s 后就换成 working,否则长时间 Search/List 只闪一下。
            // 工具结束后先保持 4s 工作中;4s 内没有下一个工具,说明模型进入长时间思考/生成。
            if state == .working && age > 4.0 { effective = .thinking }
        }
        // 完成态展示几秒后回到空闲;等待确认/思考等长时间无新事件也回空闲,避免卡住
        if state == .done && age > 6 { effective = .idle }
        if age > 900 { effective = .idle }
        if (state == .waitingApproval || state == .waitingReply) && age > 600 { effective = .idle }
        deliver(effective, (effective == .tool || effective == .working) ? effectiveTool : nil)
    }

    private func deliver(_ state: PetActivity, _ tool: String?) {
        let toolKey = tool ?? ""
        if let last = last, last.0 == state, (last.1 ?? "") == toolKey { return }
        last = (state, tool)
        handler?(state, tool)
    }
}

/// 把宠物窗口原点限制在 Claude 窗口内(离边 6pt,顶部让开 34pt 标题栏)
func clampOriginToClaude(_ origin: NSPoint, size: NSSize, claudeCG: CGRect) -> NSPoint {
    var x = origin.x
    var cgY = ClaudeWindowTracker.mainScreenHeight - origin.y - size.height
    x = min(max(x, claudeCG.minX + 6), claudeCG.maxX - size.width - 6)
    cgY = min(max(cgY, claudeCG.minY + 34), claudeCG.maxY - size.height - 6)
    return NSPoint(x: x, y: ClaudeWindowTracker.mainScreenHeight - cgY - size.height)
}

final class AppController: NSObject, NSApplicationDelegate, PetViewDelegate {
    private var config = ConfigStore.load()
    private var snapshot: QuotaSnapshot?
    private var panel: NSPanel!
    private var petView: PetView!
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var lastFetchAt = Date.distantPast
    private var visibleHint = false
    private var statusItem: NSStatusItem?
    private let claudeTracker = ClaudeWindowTracker()
    private let activityWatcher = ClaudeActivityWatcher()
    private var claudeWindow: ClaudeWindowTracker.Info?
    /// 记录最近一次看到的 Claude 是否处于原生全屏(切到别的 Space 后 tracker 看不到窗口,需要缓存)
    private var lastClaudeFullscreen = false
    /// Claude 前台时的最后可见位置;切到别的桌面后用它把面板放回同一个屏幕位置
    private var lastVisibleFrame: NSRect?
    private var demoStateUntil: Date?
    private var demoStateTimer: Timer?
    private var manuallyHidden = false
    private var activationObserver: NSObjectProtocol?
    private var panelShown = false
    private var suppressShowUntil = Date.distantPast

    func applicationWillTerminate(_ notification: Notification) {
        saveWindowPosition()
        let pidURL = appSupportDir.appendingPathComponent("clawdfloat.pid")
        if let text = try? String(contentsOf: pidURL, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines) == String(ProcessInfo.processInfo.processIdentifier) {
            try? FileManager.default.removeItem(at: pidURL)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupPanel()
        setupStatusItem()
        setupClaudeTracking()
        setupActivityWatcher()
        scheduleRefreshTimer()
        scheduleTickTimer()
        log("ClawdFloat launched, unit=\(config.unit), anchor=\(config.anchorMode)")
        refresh()
    }

    private func setupPanel() {
        petView = PetView(frame: .zero)
        petView.delegate = self
        petView.unit = CGFloat(config.unit)
        petView.textScale = CGFloat(config.textScale ?? 1.0)
        petView.page = config.page
        petView.renewalDay = config.renewalDay
        petView.renewalDateString = config.renewalDate
        petView.planCycle = config.planCycle
        petView.refreshMinutes = config.refreshMinutes
        let size = petView.desiredSize()
        petView.frame = NSRect(origin: .zero, size: size)

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.alphaValue = 0
        panel.contentView = petView
        petView.clampOrigin = { [weak self] origin in
            self?.clampToCurrentMode(origin) ?? origin
        }
        if config.anchorMode == "claudeWindow" {
            applyAnchoredWindowBehavior()
            panel.orderOut(nil) // 等 tracker 找到 Claude 窗口且 Claude 在前台再显示
        } else {
            applyLevelMode()
            positionPanel()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panelShown = true
        }
        log("window #\(panel.windowNumber) frame=\(panel.frame) anchor=\(config.anchorMode)")
    }

    private func setupClaudeTracking() {
        claudeTracker.start { [weak self] info in
            guard let self = self else { return }
            let frameChanged = info?.cgBounds != self.claudeWindow?.cgBounds
            if let info = info {
                self.lastClaudeFullscreen = ClaudeWindowTracker.isFullscreenBounds(info.cgBounds)
            } else if !ClaudeWindowTracker.isClaudeRunning() {
                self.lastClaudeFullscreen = false
            }
            self.claudeWindow = info
            if info == nil, !self.shouldKeepAcrossDesktops() {
                self.hidePanelNow()
                return
            }
            if self.config.anchorMode == "claudeWindow", info != nil, frameChanged {
                self.repositionInClaude()
            }
            self.applyVisibility()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let app = NSWorkspace.shared.frontmostApplication
            let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            if isSelf {
                // 点桌宠/点菜单栏导致本 App 成为前台:不要因此隐藏或闪烁
                return
            }
            if app?.bundleIdentifier == ClaudeWindowTracker.claudeBundleID {
                // 切回 Claude:稍等窗口激活完成再显示,避免过渡帧闪一下
                self.suppressShowUntil = Date().addingTimeInterval(0.22)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                    self?.applyVisibility()
                }
            } else if self.shouldKeepAcrossDesktops() {
                // Claude 正在原生全屏:切到别的桌面也保持桌宠可见(用户明确开了 allSpaces)
                self.applyVisibility()
            } else {
                // 切到任何其他 App:立刻隐藏,并短暂禁止 tracker 回调把它重新 orderFront
                self.suppressShowUntil = Date().addingTimeInterval(0.9)
                self.hidePanelNow()
            }
        }
        // Claude 被切走时也立刻隐藏
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == ClaudeWindowTracker.claudeBundleID {
                if self.shouldKeepAcrossDesktops() {
                    self.applyVisibility()
                } else {
                    self.suppressShowUntil = Date().addingTimeInterval(0.9)
                    self.hidePanelNow()
                }
            }
        }
        // Space 切换:Claude 原生全屏时把面板重新放回当前 Space 的同一屏幕位置
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.shouldKeepAcrossDesktops() {
                self.applyAnchoredWindowBehavior()
                if let last = self.lastVisibleFrame { self.panel.setFrame(last, display: true) }
                self.panel.alphaValue = 1
                self.panel.orderOut(nil)
                self.panel.orderFrontRegardless()
                self.panelShown = true
            } else if self.config.anchorMode == "claudeWindow",
                      !ClaudeWindowTracker.isClaudeFrontmost() {
                self.hidePanelNow()
            }
        }
    }

    private func hidePanelNow() {
        guard panel != nil else { return }
        panel.alphaValue = 0
        panel.orderOut(nil)
        panelShown = false
        rebuildStatusMenu()
    }

    private func setupActivityWatcher() {
        activityWatcher.start { [weak self] state, tool in
            guard let self = self else { return }
            // 演示状态期间不被 hooks 覆盖
            if let until = self.demoStateUntil, Date() < until { return }
            self.petView.setActivity(state, tool: tool)
            log("activity -> \(state.rawValue)\(tool.map { " tool=\($0)" } ?? "")")
        }
    }

    @objc private func menuDemoState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let state = PetActivity(rawValue: raw) else { return }
        demoStateUntil = Date().addingTimeInterval(9)
        petView.setActivity(state, tool: state == .tool ? "Bash" : nil)
        demoStateTimer?.invalidate()
        demoStateTimer = Timer(timeInterval: 9, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.demoStateUntil = nil
            self.petView.setActivity(.idle)
        }
        RunLoop.main.add(demoStateTimer!, forMode: .common)
        rebuildStatusMenu()
    }

    // MARK: 跟随 Claude 窗口

    private func applyAnchoredWindowBehavior() {
        // 只在 Claude 前台时显示,所以可以浮在 Claude 普通窗口之上;不跨 App 显示。
        // 默认只跟随当前桌面;用户选“所有桌面空间 + 全屏”时才加入所有 Space/全屏。
        switch config.levelMode {
        case "allSpaces":
            // 先设 isFloatingPanel,再设 level;反过来 AppKit 可能把 level 重置回 floating。
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        default:
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        }
        log("anchored behavior mode=\(config.levelMode) level=\(panel.level.rawValue) cb=\(panel.collectionBehavior.rawValue)")
    }

    /// Claude 原生全屏 + allSpaces 时,即使切到别的桌面/别的 App 也保持桌宠可见。
    /// 不是全屏时仍然维持原来的「只在 Claude 前台显示」。
    private func shouldKeepAcrossDesktops() -> Bool {
        guard config.anchorMode == "claudeWindow",
              config.levelMode == "allSpaces",
              lastClaudeFullscreen,
              ClaudeWindowTracker.isClaudeRunning() else { return false }
        return true
    }

    private func applyVisibility() {
        guard panel != nil else { return }
        if manuallyHidden {
            hidePanelNow()
            return
        }
        if config.anchorMode == "claudeWindow" {
            let keepAcross = shouldKeepAcrossDesktops()
            let claudeFront = ClaudeWindowTracker.isClaudeFrontmost()
            if !claudeFront && !keepAcross {
                hidePanelNow()
                return
            }
            if !keepAcross {
                guard claudeWindow != nil, Date() >= suppressShowUntil else {
                    hidePanelNow()
                    return
                }
            }
            applyAnchoredWindowBehavior()
            if claudeFront, claudeWindow != nil {
                repositionInClaude()
            } else if keepAcross, let last = lastVisibleFrame {
                panel.setFrame(last, display: true)
            }
            if keepAcross {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
                panelShown = true
            } else if !panelShown || !panel.isVisible {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
                panelShown = true
            }
        } else {
            applyLevelMode()
            if !panelShown || !panel.isVisible {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
                panelShown = true
            }
        }
        rebuildStatusMenu()
    }

    /// 全屏 Space 里 CGWindow 可能带巨大的 Space 偏移;锚定时统一用屏幕 frame,避免把宠物算到屏幕外。
    private func effectiveClaudeCG(_ cg: CGRect) -> CGRect {
        if ClaudeWindowTracker.isFullscreenBounds(cg),
           let screen = NSScreen.screens.first(where: { abs($0.frame.width - cg.width) < 4 }) {
            return screen.frame
        }
        return cg
    }

    private func repositionInClaude(force: Bool = false) {
        guard let claude = claudeWindow, !petView.isDragging else { return }
        let size = panel.frame.size
        let cg = effectiveClaudeCG(claude.cgBounds)
        var dx = CGFloat(config.anchorDX ?? Double(cg.width - size.width - 36))
        var dy = CGFloat(config.anchorDY ?? Double(cg.height - size.height - 44))
        dx = min(max(dx, 6), max(6, cg.width - size.width - 6))
        dy = min(max(dy, 34), max(34, cg.height - size.height - 6))
        config.anchorDX = Double(dx)
        config.anchorDY = Double(dy)
        let origin = NSPoint(
            x: cg.minX + dx,
            y: ClaudeWindowTracker.mainScreenHeight - (cg.minY + dy) - size.height)
        if force || abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 {
            panel.setFrameOrigin(origin)
        }
        lastVisibleFrame = panel.frame
    }

    private func clampToCurrentMode(_ origin: NSPoint) -> NSPoint {
        let size = panel.frame.size
        guard config.anchorMode == "claudeWindow", let cg = claudeWindow?.cgBounds else {
            return constrainOrigin(origin, size: size)
        }
        return clampOriginToClaude(origin, size: size, claudeCG: effectiveClaudeCG(cg))
    }

    // 菜单栏常驻小螃蟹:窗口被别的 App 盖住时也能找到它 / 退出
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🦀"
        item.button?.toolTip = "Clawd 悬浮窗"
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "隐藏 Clawd", action: #selector(statusToggleVisible), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let refreshItem = NSMenuItem(title: "刷新额度", action: #selector(menuRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let stateItem = NSMenuItem(title: "状态演示", action: nil, keyEquivalent: "")
        stateItem.submenu = stateDemoMenu()
        menu.addItem(stateItem)

        let anchorItem = NSMenuItem(title: "显示位置", action: nil, keyEquivalent: "")
        anchorItem.submenu = anchorModeMenu()
        menu.addItem(anchorItem)

        let textItem = NSMenuItem(title: "字体大小(气泡)", action: nil, keyEquivalent: "")
        textItem.submenu = textScaleMenu()
        menu.addItem(textItem)
        menu.addItem(.separator())

        let levelMenu = NSMenu()
        for (mode, title) in [("normal", "当前桌面(跟随 Claude)"),
                              ("floating", "当前桌面 + 浮于普通窗口之上"),
                              ("allSpaces", "所有桌面空间 + 全屏")] {
            let entry = NSMenuItem(title: title, action: #selector(menuLevel(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode
            entry.state = config.levelMode == mode ? .on : .off
            levelMenu.addItem(entry)
        }
        let levelItem = NSMenuItem(title: "置顶方式", action: nil, keyEquivalent: "")
        levelItem.submenu = levelMenu
        menu.addItem(levelItem)

        let centerItem = NSMenuItem(title: "回到右下角", action: #selector(menuResetPosition), keyEquivalent: "")
        centerItem.target = self
        menu.addItem(centerItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Clawd", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func statusToggleVisible() {
        manuallyHidden.toggle()
        applyVisibility()
    }

    private func rebuildStatusMenu() {
        guard let menu = statusItem?.menu, let first = menu.items.first else { return }
        first.title = manuallyHidden ? "显示 Clawd" : "隐藏 Clawd"
        for item in menu.items where item.title == "显示位置" {
            for entry in item.submenu?.items ?? [] {
                entry.state = (entry.representedObject as? String) == config.anchorMode ? .on : .off
            }
        }
        for item in menu.items where item.title == "字体大小(气泡)" {
            let current = config.textScale ?? 1.0
            for entry in item.submenu?.items ?? [] {
                entry.state = abs(current - Double(entry.tag) / 100.0) < 0.01 ? .on : .off
            }
        }
    }

    private func textScaleMenu() -> NSMenu {
        let menu = NSMenu()
        let current = config.textScale ?? 1.0
        for (title, value) in [("小", 0.85), ("中", 1.0), ("大", 1.25), ("特大", 1.5)] {
            let item = NSMenuItem(title: "\(title)(\(String(format: "%.2g", value))x)", action: #selector(menuTextScale(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(value * 100)
            item.state = abs(current - value) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuTextScale(_ sender: NSMenuItem) {
        applyTextScale(Double(sender.tag) / 100.0)
    }

    private func stateDemoMenu() -> NSMenu {
        let menu = NSMenu()
        for (raw, title) in [("idle", "空闲"), ("thinking", "思考中"), ("tool", "调用工具"),
                             ("working", "工作中"), ("waitingApproval", "等待审批"),
                             ("waitingReply", "等待回复"),
                             ("done", "完成"), ("error", "出错")] {
            let item = NSMenuItem(title: title, action: #selector(menuDemoState(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = raw
            menu.addItem(item)
        }
        return menu
    }

    private func anchorModeMenu() -> NSMenu {
        let menu = NSMenu()
        for (mode, title) in [("claudeWindow", "跟随 Claude App 窗口(默认)"),
                              ("desktop", "桌面自由悬浮")] {
            let entry = NSMenuItem(title: title, action: #selector(menuAnchorMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode
            entry.state = config.anchorMode == mode ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func menuAnchorMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        config.anchorMode = mode
        manuallyHidden = false
        ConfigStore.save(config)
        if mode == "claudeWindow" {
            applyAnchoredWindowBehavior()
            repositionInClaude(force: true)
            applyVisibility()
        } else {
            applyLevelMode()
            positionPanel()
            panel.orderFrontRegardless()
            rebuildStatusMenu()
        }
        log("anchor mode -> \(mode)")
    }

    private func applyLevelMode() {
        switch config.levelMode {
        case "floating":
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.collectionBehavior = [.moveToActiveSpace]
        case "allSpaces":
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        default:
            panel.level = .normal
            panel.isFloatingPanel = false
            panel.collectionBehavior = []
        }
    }

    private func positionPanel() {
        let size = panel.frame.size
        var origin: NSPoint
        if let x = config.posX, let y = config.posY {
            origin = NSPoint(x: x, y: y)
        } else if let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 36,
                             y: screen.visibleFrame.minY + 36)
        } else {
            origin = NSPoint(x: 200, y: 200)
        }
        origin = constrainOrigin(origin, size: size)
        panel.setFrameOrigin(origin)
    }

    private func constrainOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let point = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }
        var x = origin.x
        var y = origin.y
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    private func saveWindowPosition() {
        guard let panel = panel else { return }
        if config.anchorMode == "claudeWindow", let cg = claudeWindow?.cgBounds {
            let petCGY = ClaudeWindowTracker.mainScreenHeight - panel.frame.origin.y - panel.frame.height
            config.anchorDX = Double(panel.frame.origin.x - cg.minX)
            config.anchorDY = Double(petCGY - cg.minY)
        } else {
            config.posX = Double(panel.frame.origin.x)
            config.posY = Double(panel.frame.origin.y)
        }
        ConfigStore.save(config)
    }

    // MARK: 定时器

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, config.refreshMinutes) * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func scheduleTickTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.petView.tick += 1
            if self.petView.scurryTicks > 0 { self.petView.scurryTicks -= 1 }
            self.petView.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: 刷新

    private func refresh(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastFetchAt) < 12 && snapshot != nil { return }
        lastFetchAt = now
        petView.busy = true
        petView.needsDisplay = true

        let currentConfig = config
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = QuotaClient.fetch(currentConfig)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.petView.busy = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    log("quota ok: 5h=\(snapshot.fiveHour?.percentage ?? -1)% week=\(snapshot.weekly?.percentage ?? -1)% level=\(snapshot.level) source=\(snapshot.source)")
                    if snapshot.fiveHour?.resetAt == nil {
                        log("quota note: 5h window has no nextResetTime (idle window, API only returns it after first use)")
                    }
                case .failure(let error):
                    let message = error.localizedDescription
                    if var previous = self.snapshot {
                        previous.error = message
                        self.snapshot = previous
                    } else {
                        self.snapshot = QuotaSnapshot(fetchedAt: Date().timeIntervalSince1970 * 1000,
                                                      level: "", fiveHour: nil, weekly: nil,
                                                      error: message, source: "")
                    }
                    log("quota failed: \(message)")
                }
                self.petView.snapshot = self.snapshot
                self.petView.needsDisplay = true
            }
        }
    }

    // MARK: PetViewDelegate

    func petViewRequestRefresh(_ view: PetView) {
        refresh(force: true)
    }

    func petViewCyclePage(_ view: PetView) {
        let count = max(1, petView.pageCount)
        config.page = (config.page + 1) % count
        petView.page = config.page
        ConfigStore.save(config)
        petView.needsDisplay = true
    }

    func petViewRequestQuit(_ view: PetView) {
        saveWindowPosition()
        log("ClawdFloat quit by user")
        NSApp.terminate(nil)
    }

    func petViewAdjustScale(_ view: PetView, delta: Double) {
        let newUnit = min(32, max(8, Double(config.unit) + delta))
        guard abs(newUnit - config.unit) > 0.1 else { return }
        config.unit = newUnit
        applyUnit(newUnit)
    }

    func petViewAdjustTextScale(_ view: PetView, delta: Double) {
        let current = config.textScale ?? 1.0
        let next = min(2.2, max(0.55, current + delta * 0.05))
        guard abs(next - current) > 0.001 else { return }
        applyTextScale(next)
    }

    private func applyTextScale(_ value: Double) {
        let oldFrame = panel.frame
        petView.textScale = CGFloat(value)
        let newSize = petView.desiredSize()
        petView.frame = NSRect(origin: .zero, size: newSize)
        if config.anchorMode == "claudeWindow" {
            panel.setFrame(NSRect(origin: oldFrame.origin, size: newSize), display: true)
            repositionInClaude(force: true)
        } else {
            var origin = NSPoint(x: oldFrame.maxX - newSize.width, y: oldFrame.minY)
            origin = constrainOrigin(origin, size: newSize)
            panel.setFrame(NSRect(origin: origin, size: newSize), display: true)
        }
        config.textScale = value
        saveWindowPosition()
        petView.needsDisplay = true
    }

    private func applyUnit(_ unit: Double) {
        let oldFrame = panel.frame
        petView.unit = CGFloat(unit)
        let newSize = petView.desiredSize()
        petView.frame = NSRect(origin: .zero, size: newSize)
        if config.anchorMode == "claudeWindow" {
            panel.setFrame(NSRect(origin: oldFrame.origin, size: newSize), display: true)
            repositionInClaude(force: true)
        } else {
            var origin = NSPoint(x: oldFrame.maxX - newSize.width, y: oldFrame.minY)
            origin = constrainOrigin(origin, size: newSize)
            panel.setFrame(NSRect(origin: origin, size: newSize), display: true)
        }
        config.unit = unit
        saveWindowPosition()
        petView.needsDisplay = true
    }

    func petViewDidFinishDrag(_ view: PetView) {
        saveWindowPosition()
    }

    func petViewRequestMenu(_ view: PetView, event: NSEvent) {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "刷新额度", action: #selector(menuRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let stateItem = NSMenuItem(title: "状态演示", action: nil, keyEquivalent: "")
        stateItem.submenu = stateDemoMenu()
        menu.addItem(stateItem)

        let anchorItem = NSMenuItem(title: "显示位置", action: nil, keyEquivalent: "")
        anchorItem.submenu = anchorModeMenu()
        menu.addItem(anchorItem)
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for (title, unit) in [("小", 10.0), ("中", 14.0), ("大", 20.0)] {
            let item = NSMenuItem(title: "\(title)(\(Int(unit))pt/像素)", action: #selector(menuSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(unit)
            item.state = abs(config.unit - unit) < 0.1 ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "宠物大小(滚轮也可调)", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let textItem = NSMenuItem(title: "字体大小(气泡,Option+Shift+滚轮)", action: nil, keyEquivalent: "")
        textItem.submenu = textScaleMenu()
        menu.addItem(textItem)

        let levelMenu = NSMenu()
        let modes = [("normal", "当前桌面(跟随 Claude)"),
                     ("floating", "当前桌面 + 浮于普通窗口之上"),
                     ("allSpaces", "所有桌面空间 + 全屏")]
        for (mode, title) in modes {
            let item = NSMenuItem(title: title, action: #selector(menuLevel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = config.levelMode == mode ? .on : .off
            levelMenu.addItem(item)
        }
        let levelItem = NSMenuItem(title: "置顶方式", action: nil, keyEquivalent: "")
        levelItem.submenu = levelMenu
        menu.addItem(levelItem)

        menu.addItem(.separator())
        let resetItem = NSMenuItem(title: "回到右下角", action: #selector(menuResetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let quitItem = NSMenuItem(title: "退出 Clawd", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func menuRefresh() {
        refresh(force: true)
    }

    @objc private func menuSize(_ sender: NSMenuItem) {
        applyUnit(Double(sender.tag))
    }

    @objc private func menuLevel(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        config.levelMode = mode
        if config.anchorMode == "claudeWindow" {
            applyAnchoredWindowBehavior()
            repositionInClaude(force: true)
            if ClaudeWindowTracker.isClaudeFrontmost() {
                // 改了 collectionBehavior 后要重新 orderFront,全屏/Space 才会立刻生效
                panel.orderFrontRegardless()
                panelShown = true
            }
        } else {
            applyLevelMode()
        }
        ConfigStore.save(config)
        petView.needsDisplay = true
        if let menu = statusItem?.menu {
            for item in menu.items {
                for entry in item.submenu?.items ?? [] {
                    if let value = entry.representedObject as? String,
                       ["normal", "floating", "allSpaces"].contains(value) {
                        entry.state = value == mode ? .on : .off
                    }
                }
            }
        }
    }

    @objc private func menuResetPosition() {
        if config.anchorMode == "claudeWindow" {
            config.anchorDX = nil
            config.anchorDY = nil
            repositionInClaude(force: true)
        } else {
            config.posX = nil
            config.posY = nil
            positionPanel()
        }
        ConfigStore.save(config)
    }

    @objc private func menuQuit() {
        saveWindowPosition()
        NSApp.terminate(nil)
    }
}

// MARK: - 截图/自检工具

func makePetView(unit: CGFloat, page: Int, renewalDay: Int, snapshot: QuotaSnapshot, tick: Int = 6, busy: Bool = false) -> PetView {
    let view = PetView(frame: .zero)
    view.unit = unit
    view.page = page
    view.renewalDay = renewalDay
    view.snapshot = snapshot
    view.tick = tick
    view.busy = busy
    let size = view.desiredSize()
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    return view
}

func syntheticSnapshot(percentage: Int, level: String = "MAX") -> QuotaSnapshot {
    let now = Date().timeIntervalSince1970 * 1000
    let five = QuotaWindow(used: 28000 * Double(percentage) / 100, total: 28000,
                           percentage: percentage, resetAt: now + 2 * 3600 * 1000)
    let week = QuotaWindow(used: 140000 * 0.26, total: 140000,
                           percentage: 26, resetAt: now + 4 * 86400 * 1000)
    return QuotaSnapshot(fetchedAt: now, level: level, fiveHour: five, weekly: week,
                         error: nil, source: "cc-switch")
}

@discardableResult
func renderPNG(view: PetView, to path: String, scale: CGFloat = 2) -> Bool {
    let size = view.frame.size
    guard let pdfData = view.dataWithPDF(inside: NSRect(origin: .zero, size: size)) as Data?,
          let image = NSImage(data: pdfData) else { return false }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return false }
    rep.size = size
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size.width, height: size.height).fill()
    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        return true
    } catch {
        return false
    }
}

func writeJSON(_ object: [String: Any], to path: String) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - 命令行入口

func printUsage() {
    print("""
    ClawdFloat — Claude 真·桌宠「Clawd 悬浮窗」

    用法:
      ClawdFloat                         启动悬浮桌宠
      ClawdFloat --selftest [--out DIR]  自检:Key 发现 / 额度接口 / 窗口属性 / 截图
      ClawdFloat --snapshot PATH         渲染一张截图(--mood 0-100, --page 0-4, --unit 14, --state thinking, --tool Edit)
      ClawdFloat --help                  显示本帮助

    配置: ~/Library/Application Support/ClawdFloat/config.json
    日志: ~/Library/Application Support/ClawdFloat/app.log
    """)
}

func argumentValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: name), index + 1 < args.count {
        return args[index + 1]
    }
    return nil
}

func hasFlag(_ name: String) -> Bool {
    CommandLine.arguments.contains(name)
}

func runSnapshot() {
    let path = argumentValue("--snapshot") ?? "clawd-snapshot.png"
    let unit = CGFloat(Double(argumentValue("--unit") ?? "14") ?? 14)
    let page = Int(argumentValue("--page") ?? "0") ?? 0
    let mood = Int(argumentValue("--mood") ?? "28") ?? 28
    let stateRaw = argumentValue("--state") ?? "idle"
    let activity = PetActivity(rawValue: stateRaw) ?? .idle
    let toolArg = argumentValue("--tool") ?? "Bash"
    let config = ConfigStore.load()
    let textScale = Double(argumentValue("--text-scale") ?? "\(config.textScale ?? 1.0)") ?? (config.textScale ?? 1.0)
    _ = NSApplication.shared
    let snapshot = syntheticSnapshot(percentage: mood)
    let view = makePetView(unit: unit, page: page, renewalDay: config.renewalDay, snapshot: snapshot)
    view.renewalDateString = config.renewalDate
    view.planCycle = config.planCycle
    view.textScale = CGFloat(textScale)
    view.frame = NSRect(origin: .zero, size: view.desiredSize())
    view.setActivity(activity, tool: activity == .tool ? toolArg : nil)
    let ok = renderPNG(view: view, to: path)
    print(ok ? "snapshot written: \(path)" : "snapshot failed")
    exit(ok ? 0 : 1)
}

final class RecordingPetDelegate: NSObject, PetViewDelegate {
    var events: [String] = []
    func petViewRequestRefresh(_ view: PetView) { events.append("refresh") }
    func petViewCyclePage(_ view: PetView) { events.append("cycle") }
    func petViewRequestQuit(_ view: PetView) { events.append("quit") }
    func petViewAdjustScale(_ view: PetView, delta: Double) { events.append("scale:\(delta)") }
    func petViewAdjustTextScale(_ view: PetView, delta: Double) { events.append("textScale:\(delta)") }
    func petViewDidFinishDrag(_ view: PetView) { events.append("drag") }
    func petViewRequestMenu(_ view: PetView, event: NSEvent) { events.append("menu") }
}

func runSelfTest(outDir: String?) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    var report: [String: Any] = [:]
    let config = ConfigStore.load()

    // 1. Key 发现
    do {
        let auth = try QuotaClient.resolveAuth(config)
        report["auth"] = ["ok": true, "source": auth.source, "host": auth.host,
                          "tokenLength": auth.token.count]
    } catch {
        report["auth"] = ["ok": false, "error": error.localizedDescription]
    }

    // 2. 真机拉取额度
    let result = QuotaClient.fetch(config)
    switch result {
    case .success(let snapshot):
        var quota: [String: Any] = [
            "ok": true,
            "source": snapshot.source,
            "level": snapshot.level,
            "worstPercentage": snapshot.worstPercentage,
        ]
        if let five = snapshot.fiveHour {
            quota["fiveHour"] = ["percentage": five.percentage, "used": five.used,
                                 "total": five.total, "resetAt": five.resetAt ?? 0]
        }
        if let week = snapshot.weekly {
            quota["weekly"] = ["percentage": week.percentage, "used": week.used,
                               "total": week.total, "resetAt": week.resetAt ?? 0]
        }
        report["quota"] = quota
    case .failure(let error):
        report["quota"] = ["ok": false, "error": error.localizedDescription]
    }

    // 2.5 当前峰谷时段(官方:周一至五 14:00–18:00 高峰,UTC+8)
    let peak = peakInfo(now: Date())
    report["peak"] = [
        "isPeak": peak.isPeak,
        "label": peak.label,
        "discount": peak.discount,
        "rule": peak.rule,
        "note": peak.note,
    ]

    // 3. 窗口属性(创建 → 显示 → 查 CGWindowList → 关闭)
    let view = makePetView(unit: CGFloat(config.unit), page: 0, renewalDay: config.renewalDay,
                           snapshot: syntheticSnapshot(percentage: 28))
    view.renewalDateString = config.renewalDate
    view.planCycle = config.planCycle
    view.textScale = CGFloat(config.textScale ?? 1.0)
    let size = view.desiredSize()
    let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.contentView = view
    switch config.levelMode {
    case "floating", "allSpaces":
        panel.level = .floating
        panel.collectionBehavior = config.levelMode == "allSpaces"
            ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace]
    default:
        panel.level = .normal
    }
    panel.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]] ?? []
    let windowInfo = windowList.first ?? [:]
    report["window"] = [
        "visible": panel.isVisible,
        "frame": ["x": panel.frame.origin.x, "y": panel.frame.origin.y,
                  "width": panel.frame.width, "height": panel.frame.height],
        "isOpaque": panel.isOpaque,
        "backgroundColorAlpha": panel.backgroundColor.alphaComponent,
        "level": panel.level.rawValue,
        "collectionBehavior": panel.collectionBehavior.rawValue,
        "cgWindowOnscreen": windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false,
        "cgWindowBounds": windowInfo[kCGWindowBounds as String] ?? [:],
        "cgWindowAlpha": windowInfo[kCGWindowAlpha as String] ?? 0,
    ]
    // 3.5 布局/命中区域检查
    let layout = view.debugLayoutReport()
    let bubble = layout["bubble"] as? [String: CGFloat] ?? [:]
    let crab = layout["crab"] as? [String: CGFloat] ?? [:]
    let hitCrabPoint = (x: (crab["x"] ?? 0) + (crab["w"] ?? 0) / 2, y: (crab["y"] ?? 0) + (crab["h"] ?? 0) / 2)
    let hitBubblePoint = (x: (bubble["x"] ?? 0) + (bubble["w"] ?? 0) / 2, y: (bubble["y"] ?? 0) + (bubble["h"] ?? 0) / 2)
    let crabViewPoint = NSPoint(x: hitCrabPoint.x, y: hitCrabPoint.y)
    let bubbleViewPoint = NSPoint(x: hitBubblePoint.x, y: hitBubblePoint.y)
    report["layout"] = layout
    report["hitTest"] = [
        "crabCenter": view.debugHitName(x: crabViewPoint.x, y: crabViewPoint.y),
        "bubbleCenter": view.debugHitName(x: bubbleViewPoint.x, y: bubbleViewPoint.y),
        "outside": view.debugHitName(x: -20, y: -20),
    ]

    // 3.6 点击路由(合成 NSEvent 直接投给视图,验证 点螃蟹/点气泡/点✕)
    let recorder = RecordingPetDelegate()
    view.delegate = recorder
    func clickView(at point: NSPoint) {
        let windowPoint = NSPoint(x: point.x, y: view.bounds.height - point.y)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
                                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint,
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }
    var clicks: [String: Any] = [:]
    recorder.events = []
    clickView(at: crabViewPoint)
    clicks["crab"] = recorder.events
    recorder.events = []
    clickView(at: bubbleViewPoint)
    clicks["bubble"] = recorder.events
    recorder.events = []
    let closeRect = layout["close"] as? [String: CGFloat] ?? [:]
    clickView(at: NSPoint(x: (closeRect["x"] ?? 0) + (closeRect["w"] ?? 16) / 2,
                          y: (closeRect["y"] ?? 0) + (closeRect["h"] ?? 16) / 2))
    clicks["close"] = recorder.events
    recorder.events = []
    clickView(at: NSPoint(x: -10, y: -10))
    clicks["outside"] = recorder.events
    report["clickRouting"] = clicks

    // 3.55 跟随 Claude 窗口:吸附范围检查(用真实 Claude 窗口 bounds,不改动它们)
    if let claude = ClaudeWindowTracker.findCurrent() {
        let cg = claude.cgBounds
        let clamped = clampOriginToClaude(NSPoint(x: -5000, y: -5000), size: size, claudeCG: cg)
        let petCGY = ClaudeWindowTracker.mainScreenHeight - clamped.y - size.height
        let inside = clamped.x >= cg.minX + 6 - 0.5 &&
            clamped.x + size.width <= cg.maxX - 6 + 0.5 &&
            petCGY >= cg.minY + 34 - 0.5 &&
            petCGY + size.height <= cg.maxY - 6 + 0.5
        report["anchor"] = [
            "mode": config.anchorMode,
            "claudeFrontmost": ClaudeWindowTracker.isClaudeFrontmost(),
            "claudeWindow": ["x": cg.minX, "y": cg.minY, "width": cg.width, "height": cg.height],
            "clampedOriginInside": inside,
            "clampMargins": ["left": 6, "right": 6, "top": 34, "bottom": 6],
        ]
    } else {
        report["anchor"] = ["mode": config.anchorMode, "claudeWindowFound": false]
    }
    report["interactionOK"] = (clicks["crab"] as? [String] == ["refresh"]
        && clicks["bubble"] as? [String] == ["cycle"]
        && clicks["close"] as? [String] == ["quit"]
        && (clicks["outside"] as? [String])?.isEmpty == true)
    panel.orderOut(nil)

    // 4. 截图证据
    if let outDir = outDir {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let moods = [28, 60, 85, 97]
        var snapshotFiles: [String] = []
        for mood in moods {
            let snap = syntheticSnapshot(percentage: mood)
            let snapshotView = makePetView(unit: CGFloat(config.unit), page: 0,
                                           renewalDay: config.renewalDay, snapshot: snap)
            let file = outDir + "/clawd-mood-\(mood).png"
            if renderPNG(view: snapshotView, to: file) { snapshotFiles.append(file) }
        }
        let pageTitles = ["5h", "week", "renewal", "status"]
        for page in 0..<4 {
            let snapshotView = makePetView(unit: CGFloat(config.unit), page: page,
                                           renewalDay: config.renewalDay,
                                           snapshot: syntheticSnapshot(percentage: 60))
            let file = outDir + "/clawd-page-\(page)-\(pageTitles[page]).png"
            if renderPNG(view: snapshotView, to: file) { snapshotFiles.append(file) }
        }
        report["snapshots"] = snapshotFiles
        writeJSON(report, to: outDir + "/selftest.json")
    }

    if let data = try? JSONSerialization.data(withJSONObject: report,
                                              options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

if hasFlag("--help") || hasFlag("-h") {
    printUsage()
    exit(0)
}
if hasFlag("--snapshot") {
    runSnapshot()
}
if hasFlag("--selftest") {
    runSelfTest(outDir: argumentValue("--out"))
}

// 单实例保护:已经有 Clawd 在跑就退出,避免桌宠重复
ensureSupportDir()
let pidURL = appSupportDir.appendingPathComponent("clawdfloat.pid")
if let existing = try? String(contentsOf: pidURL, encoding: .utf8),
   let pid = pid_t(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
   kill(pid, 0) == 0, pid != ProcessInfo.processInfo.processIdentifier {
    print("ClawdFloat 已经在运行 (pid \(pid))")
    exit(0)
}
try? String(ProcessInfo.processInfo.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = AppController()
application.delegate = controller
application.run()
