// TokenBar — DeepSeek 余额 + DSH token 用量菜单栏组件
//
// 数据全部来自 collect.py 写出的 usage.json，本程序只读文件、不碰网络、不碰密钥。
// 构建见 build.sh（只需 Command Line Tools，不需要 Xcode）。

import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 阈值
private let warnBalance: Double = 5.0    // 低于此值转黄
private let dangerBalance: Double = 2.0  // 低于此值转红
private let uiReloadSeconds: TimeInterval = 5  // 界面重读 usage.json 的频率

// ---------------------------------------------------------------- 数据模型
struct Agg: Decodable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0
    var total = 0
    var requests = 0
    var cacheHitRate: Double?

    private enum K: String, CodingKey {
        case input, output, cacheRead, cacheWrite, reasoning, total, requests, cacheHitRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        input = (try? c.decode(Int.self, forKey: .input)) ?? 0
        output = (try? c.decode(Int.self, forKey: .output)) ?? 0
        cacheRead = (try? c.decode(Int.self, forKey: .cacheRead)) ?? 0
        cacheWrite = (try? c.decode(Int.self, forKey: .cacheWrite)) ?? 0
        reasoning = (try? c.decode(Int.self, forKey: .reasoning)) ?? 0
        total = (try? c.decode(Int.self, forKey: .total)) ?? 0
        requests = (try? c.decode(Int.self, forKey: .requests)) ?? 0
        cacheHitRate = try? c.decode(Double.self, forKey: .cacheHitRate)
    }
}

struct Balance: Decodable {
    var total: Double?
    var granted: Double?
    var toppedUp: Double?
    var currency: String?
    var isAvailable: Bool?
}

struct Spend: Decodable {
    var today: Double?
    var dailyRate: Double?
    var daysLeft: Double?
    var spanDays: Double?
}

struct DayUse: Decodable {
    var date: String
    var total: Int
    var requests: Int
}

struct Usage: Decodable {
    var updatedAt: Double?
    var updatedAtISO: String?
    var ok: Bool?
    var error: String?
    var balance: Balance?
    var today: Agg?
    var session: Agg?
    var sessionId: String?
    var week: [DayUse]?
    var spend: Spend?
    var dataAgeMs: Double?
    var allTime: Agg?
    var sessionsScanned: Int?
    var refreshSeconds: Int?
}

// ---------------------------------------------------------------- 格式化
func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

func currencySymbol(_ code: String?) -> String {
    switch code {
    case "CNY", "RMB": return "¥"
    case "USD": return "$"
    default: return ""
    }
}

func fmtMoney(_ v: Double?, symbol: String) -> String {
    guard let v else { return "—" }
    return String(format: "%@%.2f", symbol, v)
}

func fmtAge(_ ms: Double?) -> String {
    guard let ms else { return "从未更新" }
    let secs = Date().timeIntervalSince1970 - ms / 1000
    if secs < 0 { return "刚刚" }
    if secs < 60 { return "\(Int(secs)) 秒前" }
    if secs < 3600 { return "\(Int(secs / 60)) 分钟前" }
    if secs < 86400 { return String(format: "%.1f 小时前", secs / 3600) }
    return "\(Int(secs / 86400)) 天前"
}

// ---------------------------------------------------------------- 状态
final class Store: ObservableObject {
    @Published var usage: Usage?
    @Published var readError: String?
    @Published var refreshing = false
    @Published var collectMessage: String?

    let usagePath: String

    init(usagePath: String) {
        self.usagePath = usagePath
        reload()
    }

    /// 只读本地文件，不触发网络
    func reload() {
        guard FileManager.default.fileExists(atPath: usagePath) else {
            readError = "还没有数据，点「立即刷新」"
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: usagePath))
            usage = try JSONDecoder().decode(Usage.self, from: data)
            readError = nil
        } catch {
            readError = "读取失败: \(error.localizedDescription)"
        }
    }

    /// 跑一次 collect.py，结束后重读
    func refreshNow() {
        guard !refreshing else { return }
        refreshing = true
        collectMessage = nil
        let script = kCollectPy
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: kPythonPath)
            proc.arguments = [script]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var message: String
            do {
                try proc.run()
                proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                message = proc.terminationStatus == 0
                    ? "已刷新"
                    : "采集失败(\(proc.terminationStatus)): \(out.suffix(160))"
            } catch {
                message = "无法运行: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self?.refreshing = false
                self?.collectMessage = message
                self?.reload()
            }
        }
    }

    /// 界面顶部要显示的异常：collect.py 的错误 + 文件读取错误
    var displayError: String? {
        if let readError { return readError }
        if let e = usage?.error, !e.isEmpty { return e }
        return nil
    }

    var symbol: String { currencySymbol(usage?.balance?.currency) }

    var balanceColor: Color {
        guard let t = usage?.balance?.total else { return .secondary }
        if t < dangerBalance { return .red }
        if t < warnBalance { return .orange }
        return .primary
    }

    var title: String {
        let money = fmtMoney(usage?.balance?.total, symbol: symbol)
        let today = fmtTokens(usage?.today?.total ?? 0)
        return "\(money) · \(today)"
    }
}

// ---------------------------------------------------------------- 界面
struct PanelView: View {
    @ObservedObject var store: Store

    private var u: Usage? { store.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 余额主角
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(store.symbol + (u?.balance?.total.map { String(format: "%.2f", $0) } ?? "—"))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(store.balanceColor)
                Text("余额")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let avail = u?.balance?.isAvailable, !avail {
                    Text("账户不可用").font(.caption2).foregroundStyle(.red)
                }
            }

            if let err = store.displayError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    label("今日用量"); value(fmtTokens(u?.today?.total ?? 0) + " tok")
                    label("缓存命中"); value(hitRate(u?.today?.cacheHitRate))
                }
                GridRow {
                    label("本次会话"); value(fmtTokens(u?.session?.total ?? 0) + " tok")
                    label("请求次数"); value("\(u?.today?.requests ?? 0)")
                }
                GridRow {
                    label("今日已花"); value(fmtMoney(u?.spend?.today, symbol: store.symbol))
                    label("日均花费"); value(fmtMoney(u?.spend?.dailyRate, symbol: store.symbol))
                }
                GridRow {
                    label("输入/输出")
                    value("\(fmtTokens(u?.today?.input ?? 0)) / \(fmtTokens(u?.today?.output ?? 0))")
                    label("预计可用"); value(daysLeft(u?.spend?.daysLeft))
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("更新于 \(fmtAge(u?.updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let s = u?.refreshSeconds {
                    Text("· 每 \(s)s 刷新").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.refreshing ? "刷新中…" : "立即刷新") { store.refreshNow() }
                    .disabled(store.refreshing)
                    .controlSize(.small)
                Button("退出") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }

            if let msg = store.collectMessage, msg != "已刷新" {
                Text(msg).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    @ViewBuilder private func label(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func value(_ s: String, color: Color = .primary) -> some View {
        Text(s).font(.caption).monospacedDigit().foregroundStyle(color)
    }

    private func hitRate(_ r: Double?) -> String {
        guard let r else { return "—" }
        return String(format: "%.1f%%", r * 100)
    }

    private func daysLeft(_ d: Double?) -> String {
        guard let d else { return "—" }
        return String(format: "%.1f 天", d)
    }
}

// ---------------------------------------------------------------- App
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let store = Store(usagePath: kUsagePath)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // 不占 Dock

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
        }

        let hosting = NSHostingController(rootView: PanelView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hosting

        // 数据变化 → 更新菜单栏标题
        store.$usage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()

        // 只重读本地文件，开销可忽略
        timer = Timer.scheduledTimer(withTimeInterval: uiReloadSeconds, repeats: true) { [weak self] _ in
            self?.store.reload()
            self?.updateTitle()
        }
        RunLoop.main.add(timer!, forMode: .common)

        // 自诊断: TOKENBAR_RENDER=<path> 时把面板离屏渲染成 PNG 后退出
        // （不依赖屏幕录制权限，用于验证界面真实长相）
        if let out = ProcessInfo.processInfo.environment["TOKENBAR_RENDER"] {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                defer { NSApp.terminate(nil) }
                guard let self else { return }
                let hosting = NSHostingView(rootView: PanelView(store: self.store))
                hosting.layoutSubtreeIfNeeded()
                let size = hosting.fittingSize
                hosting.frame = NSRect(origin: .zero, size: size)

                let container = NSView(frame: NSRect(origin: .zero, size: size))
                container.wantsLayer = true
                container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                container.addSubview(hosting)
                container.layoutSubtreeIfNeeded()

                guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
                    print("DEBUG render: 无法创建 bitmap")
                    return
                }
                container.cacheDisplay(in: container.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: out))
                    print("DEBUG render: 已写出 \(out) 尺寸 \(Int(size.width))x\(Int(size.height))")
                } else {
                    print("DEBUG render: PNG 编码失败")
                }
            }
        }
        // 自诊断: TOKENBAR_DEBUG=1 时打印状态项信息后退出
        if ProcessInfo.processInfo.environment["TOKENBAR_DEBUG"] != nil {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self, let button = self.statusItem.button else {
                    print("DEBUG: statusItem.button 为 nil")
                    NSApp.terminate(nil)
                    return
                }
                print("DEBUG title      = \(button.title)")
                print("DEBUG isVisible  = \(self.statusItem.isVisible)")
                print("DEBUG buttonFrame= \(button.frame)")
                print("DEBUG windowFrame= \(String(describing: button.window?.frame))")
                print("DEBUG windowVis  = \(String(describing: button.window?.isVisible))")
                print("DEBUG usage      = \(self.store.usage == nil ? "nil" : "loaded")")
                print("DEBUG readError  = \(self.store.readError ?? "none")")
                print("DEBUG usagePath  = \(self.store.usagePath)")
                NSApp.terminate(nil)
            }
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        button.attributedTitle = NSAttributedString(string: store.title, attributes: attrs)
        button.toolTip = "DeepSeek 余额 \(fmtMoney(store.usage?.balance?.total, symbol: store.symbol))"
            + " · 今日 \(fmtTokens(store.usage?.today?.total ?? 0)) tok"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// ---------------------------------------------------------------- 入口
private let appDelegate = AppDelegate()

@main
struct TokenBarMain {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}
