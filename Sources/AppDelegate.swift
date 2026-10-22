import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ControlPanelDelegate {
    private enum Key {
        static let enabled = "keepAwakeWhenLidClosed"
        static let dim = "dimWhenLidClosed"
        static let acOnly = "onlyOnACPower"
    }

    private static let showPanelNotification = Notification.Name("com.zcode.lidnosleep.showPanel")

    private let lid = LidMonitor()
    private let brightness = BrightnessController()
    private let sleepControl = SleepControl()
    private let defaults = UserDefaults.standard
    private let panel = ControlPanelController()

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var tickCount = 0

    /// pmset disablesleep 当前是否由本程序置为 1
    private var sleepDisabledApplied = false
    private var authorized = false
    private var lastErrorMessage: String?
    private var lastAuthorizationCheck = Date.distantPast
    private var lastSleepAttempt = Date.distantPast

    private var lidClosed = false
    private var onAC = true
    private var didStart = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isAnotherInstanceRunning() else {
            log("已有实例在运行，通知它打开控制面板后退出")
            DistributedNotificationCenter.default().postNotificationName(
                Self.showPanelNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            NSApp.terminate(nil)
            return
        }

        defaults.register(defaults: [
            Key.enabled: true,
            Key.dim: true,
            Key.acOnly: true,
        ])
        didStart = true

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showPanel),
            name: Self.showPanelNotification, object: nil
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu

        authorized = sleepControl.isAuthorized()
        sleepDisabledApplied = authorized && (sleepControl.sleepDisabledSystemWide() ?? false)

        lidClosed = lid.isLidClosed
        onAC = PowerSource.isOnAC()

        installSignalHandlers()
        registerWakeNotifications()

        refreshStatusItem()
        rebuildMenu()

        let newTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer

        tick()
        log("启动完成：上盖=\(lidClosed ? "合上" : "打开")，电源=\(onAC ? "适配器" : "电池")，"
            + "授权=\(authorized ? "是" : "否")，系统休眠=\(sleepDisabledApplied ? "已禁用" : "正常")")

        // 菜单栏图标被系统挤掉时（菜单栏太满），这里能看到 visible=false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            log("状态栏项可见性：\(self.statusItem.isVisible)，"
                + "frame=\(self.statusItem.button?.window?.frame ?? .zero)")
        }

        // 登录自启动时带 --background，不弹窗；手动打开 App 时直接显示控制面板
        if CommandLine.arguments.contains("--background") {
            log("以后台模式启动")
        } else {
            panel.show(delegate: self)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 第二实例在这一步之前就退出了，不能让它清理主实例接管的状态
        guard didStart else { return }
        timer?.invalidate()
        timer = nil
        sleepControl.releaseSystemAwake()
        if sleepDisabledApplied {
            _ = sleepControl.setSleepDisabled(false)
        }
        brightness.restoreIfDimmed()
        sleepDisabledApplied = false
        log("已退出：亮度与休眠设置已恢复")
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated && $0 != NSRunningApplication.current }
    }

    // MARK: - Core loop

    /// 每秒评估一次。
    ///
    /// 关键点：`disablesleep` 必须「提前」置位，因为合盖后系统几乎立即休眠，
    /// 事后再改就来不及了。所以只要生效条件满足（默认：插电时），就先把
    /// SleepDisabled 设为 1，合盖瞬间系统才不会睡。
    private func tick() {
        tickCount += 1
        lidClosed = lid.isLidClosed
        onAC = PowerSource.isOnAC()

        let armed = defaults.bool(forKey: Key.enabled)
            && (!defaults.bool(forKey: Key.acOnly) || onAC)

        applyArmState(armed: armed)

        if tickCount % 20 == 0 {
            healIfNeeded(armed: armed)
        }

        brightness.retryRestoreIfNeeded()
        refreshStatusItem()
        panel.refresh()
    }

    private func applyArmState(armed: Bool) {
        if armed {
            let retryInterval: TimeInterval = authorized ? 15 : 60
            if !sleepDisabledApplied, Date().timeIntervalSince(lastSleepAttempt) > retryInterval {
                lastSleepAttempt = Date()
                sleepDisabledApplied = setSleepDisabled(true)
            }
            if lidClosed {
                sleepControl.holdSystemAwake(reason: "LidNoSleep：合盖后保持运行")
                if defaults.bool(forKey: Key.dim) {
                    // 环境光/系统偶尔会把亮度调回来，持续压回 0
                    if !brightness.isDimmed {
                        brightness.dimToZero()
                    } else if let current = brightness.currentBrightness, current > 0.02 {
                        log("合盖期间亮度回升到 \(Int((current * 100).rounded()))%，重新归零")
                        brightness.dimToZero()
                    }
                }
            } else {
                sleepControl.releaseSystemAwake()
                if brightness.isDimmed {
                    brightness.restoreIfDimmed()
                }
            }
        } else {
            sleepControl.releaseSystemAwake()
            if sleepDisabledApplied {
                _ = setSleepDisabled(false)
                sleepDisabledApplied = false
            }
            if brightness.isDimmed {
                brightness.restoreIfDimmed()
            }
        }
    }

    /// 每 20 秒核对一次真实系统状态，纠正被外部改动的情况
    private func healIfNeeded(armed: Bool) {
        if !authorized {
            if Date().timeIntervalSince(lastAuthorizationCheck) > 30 {
                lastAuthorizationCheck = Date()
                authorized = sleepControl.isAuthorized()
            }
            return
        }
        guard let systemDisabled = sleepControl.sleepDisabledSystemWide() else { return }
        if armed != systemDisabled {
            log("自愈：系统休眠状态为 \(systemDisabled)，期望 \(armed)，重新写入")
            sleepDisabledApplied = setSleepDisabled(armed)
        } else {
            sleepDisabledApplied = systemDisabled
        }
    }

    @discardableResult
    private func setSleepDisabled(_ disabled: Bool) -> Bool {
        let result = sleepControl.setSleepDisabled(disabled)
        if result.ok {
            authorized = true
            lastErrorMessage = nil
            log("pmset disablesleep \(disabled ? "1" : "0") 成功")
            return true
        }
        let message = result.message
        if message != lastErrorMessage {
            log("pmset disablesleep \(disabled ? "1" : "0") 失败：\(message)")
        }
        lastErrorMessage = message
        if message.contains("password is required")
            || message.contains("not allowed")
            || message.contains("may not run") {
            authorized = false
        }
        return false
    }

    // MARK: - Status item & menu

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let symbol: String
        if sleepDisabledApplied && lidClosed {
            symbol = "moon.zzz.fill"
        } else if lidClosed {
            symbol = "moon.zzz"
        } else {
            symbol = "moon"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "合盖不休眠")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "LidNoSleep — \(stateDescription)"
    }

    private var stateDescription: String {
        if !defaults.bool(forKey: Key.enabled) { return "已停用" }
        if !authorized { return "未授权：合盖仍会休眠" }
        if !defaults.bool(forKey: Key.acOnly) || onAC {
            return lidClosed ? "合盖保持运行中" : "已就绪：合盖不会休眠"
        }
        return "电池供电，已暂停：合盖会正常休眠"
    }

    private var brightnessDescription: String {
        guard let value = brightness.currentBrightness else { return "不可读（可能已熄屏）" }
        return "\(Int((value * 100).rounded()))%"
    }

    private var powerDescription: String {
        if let percent = PowerSource.batteryPercent(), !onAC {
            return "电池（\(percent)%）"
        }
        return onAC ? "电源适配器" : "电池"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.autoenablesItems = false

        for line in statusText.split(separator: "\n") {
            addInfoRow(String(line))
        }

        menu.addItem(.separator())

        let panelItem = NSMenuItem(title: "打开控制面板…", action: #selector(showPanel), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)

        addToggle("合盖时保持运行（不休眠）", key: Key.enabled, action: #selector(toggleEnabled))
        addToggle("合盖时把屏幕亮度调为 0", key: Key.dim, action: #selector(toggleDim))
        addToggle("仅在接电源时生效（更安全）", key: Key.acOnly, action: #selector(toggleACOnly))

        menu.addItem(.separator())

        if !authorized {
            let item = NSMenuItem(
                title: "⚠️ 完成一次性授权…",
                action: #selector(requestAuthorization),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        if brightness.isSupported, !lidClosed {
            let test = NSMenuItem(title: "测试：亮度归零 3 秒", action: #selector(runBrightnessTest), keyEquivalent: "")
            test.target = self
            menu.addItem(test)
        }

        let autostart = NSMenuItem(title: "开机自启动", action: #selector(toggleAutostart), keyEquivalent: "")
        autostart.target = self
        autostart.state = LaunchAgent.isInstalled ? .on : .off
        menu.addItem(autostart)

        let logItem = NSMenuItem(title: "查看日志", action: #selector(revealLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出（恢复亮度与休眠设置）", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addInfoRow(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addToggle(_ title: String, key: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = defaults.bool(forKey: key) ? .on : .off
        menu.addItem(item)
    }

    // MARK: - ControlPanelDelegate

    var statusText: String {
        var lines: [String] = []
        lines.append("上盖：\(lid.hasLid ? (lidClosed ? "已合上" : "已打开") : "本机没有内置屏幕")")
        lines.append("屏幕亮度：\(brightnessDescription)")
        lines.append("电源：\(powerDescription)")
        lines.append("系统休眠：\(sleepDisabledApplied ? "已禁用（不会休眠）" : "正常")")
        lines.append("状态：\(stateDescription)")
        if !authorized {
            lines.append("权限：未授权，合盖仍会休眠（点「完成授权…」）")
        }
        return lines.joined(separator: "\n")
    }

    var isFeatureEnabled: Bool { defaults.bool(forKey: Key.enabled) }
    var isDimEnabled: Bool { defaults.bool(forKey: Key.dim) }
    var isACOnly: Bool { defaults.bool(forKey: Key.acOnly) }
    var isAuthorized: Bool { authorized }
    var isAutostartEnabled: Bool { LaunchAgent.isInstalled }
    var canTestBrightness: Bool { brightness.isSupported && !lidClosed }

    func setFeatureEnabled(_ value: Bool) {
        defaults.set(value, forKey: Key.enabled)
        tick()
    }

    func setDimEnabled(_ value: Bool) {
        defaults.set(value, forKey: Key.dim)
        if !value, brightness.isDimmed {
            brightness.restoreIfDimmed()
        }
        tick()
    }

    func setACOnly(_ value: Bool) {
        defaults.set(value, forKey: Key.acOnly)
        tick()
    }

    func setAutostart(_ value: Bool) {
        guard value != LaunchAgent.isInstalled else { return }
        if value {
            if let error = LaunchAgent.install() {
                showAlert(title: "开启开机自启动失败", message: error)
            }
        } else if let error = LaunchAgent.remove() {
            showAlert(title: "关闭开机自启动失败", message: error)
        }
        rebuildMenu()
        panel.refresh()
    }

    // MARK: - Actions

    @objc private func showPanel() {
        log("打开控制面板")
        panel.show(delegate: self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    @objc private func toggleEnabled() {
        setFeatureEnabled(!isFeatureEnabled)
    }

    @objc private func toggleDim() {
        setDimEnabled(!isDimEnabled)
    }

    @objc private func toggleACOnly() {
        setACOnly(!isACOnly)
    }

    @objc func runBrightnessTest() {
        guard canTestBrightness else { return }
        brightness.dimToZero()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.brightness.restoreIfDimmed()
            self?.panel.refresh()
        }
    }

    @objc private func toggleAutostart() {
        setAutostart(!LaunchAgent.isInstalled)
    }

    @objc func revealLog() {
        NSWorkspace.shared.selectFile(LogFile.path, inFileViewerRootedAtPath: "")
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    /// 写入一条只允许 pmset disablesleep 0/1 的 sudoers 规则，避免每次都要输密码。
    @objc func requestAuthorization() {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, "
            + "/usr/bin/pmset -a disablesleep 0"
        let tempPath = "/tmp/lidnosleep-\(UUID().uuidString).sudoers"
        let command = [
            "/bin/echo \(rule.shellSingleQuoted) > \(tempPath.shellSingleQuoted)",
            "/usr/sbin/visudo -cf \(tempPath.shellSingleQuoted)",
            "/bin/chmod 0440 \(tempPath.shellSingleQuoted)",
            "/usr/sbin/chown root:wheel \(tempPath.shellSingleQuoted)",
            "/bin/mv -f \(tempPath.shellSingleQuoted) /etc/sudoers.d/lidnosleep",
            "/usr/sbin/visudo -cf /etc/sudoers.d/lidnosleep",
        ].joined(separator: " && ")

        let script = "do shell script \"\(command.appleScriptEscaped)\" with administrator privileges"
        // 密码框由用户操作，可能停留较久，超时给足
        let result = runProcess("/usr/bin/osascript", ["-e", script], timeout: 180)
        try? FileManager.default.removeItem(atPath: tempPath)

        guard result.status == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            showAlert(title: "授权失败", message: message.isEmpty ? "未知错误，请查看日志。" : message)
            return
        }

        authorized = sleepControl.isAuthorized()
        if authorized {
            lastErrorMessage = nil
            sleepDisabledApplied = false
            lastSleepAttempt = .distantPast
            tick()
            showAlert(title: "授权完成", message: "现在合盖后会保持不休眠。")
        } else {
            showAlert(title: "授权未生效", message: "命令已执行，但权限检查未通过，请查看日志。")
        }
    }

    private func showAlert(title: String, message: String) {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Notifications & signals

    private func registerWakeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )
    }

    @objc private func handleWake() {
        log("系统/屏幕唤醒，重新评估")
        tickCount = 0
        tick()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
