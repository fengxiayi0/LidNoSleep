import AppKit

protocol ControlPanelDelegate: AnyObject {
    var statusText: String { get }
    var isFeatureEnabled: Bool { get }
    var isDimEnabled: Bool { get }
    var isACOnly: Bool { get }
    var isAuthorized: Bool { get }
    var isAutostartEnabled: Bool { get }
    var canTestBrightness: Bool { get }

    func setFeatureEnabled(_ value: Bool)
    func setDimEnabled(_ value: Bool)
    func setACOnly(_ value: Bool)
    func setAutostart(_ value: Bool)
    func requestAuthorization()
    func runBrightnessTest()
    func revealLog()
    func quitApp()
}

/// 菜单栏空间不足时（macOS 会把排不下的项藏进刘海区域），这个面板就是主界面。
final class ControlPanelController: NSObject {
    private weak var delegate: ControlPanelDelegate?
    private var window: NSWindow?
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var enabledCheck = checkbox("合盖时保持运行（不休眠）", action: #selector(toggleEnabled))
    private lazy var dimCheck = checkbox("合盖时把屏幕亮度调为 0", action: #selector(toggleDim))
    private lazy var acCheck = checkbox("仅在接电源时生效（更安全）", action: #selector(toggleACOnly))
    private lazy var autostartCheck = checkbox("开机自启动", action: #selector(toggleAutostart))
    private lazy var authButton = NSButton(title: "完成授权…", target: self, action: #selector(authorize))
    private lazy var testButton = NSButton(title: "测试：亮度归零 3 秒", target: self, action: #selector(testDim))

    var isVisible: Bool { window?.isVisible ?? false }

    func show(delegate: ControlPanelDelegate) {
        self.delegate = delegate
        if window == nil {
            buildWindow()
        }
        refresh()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        // 后台（accessory）App 被前台 App 挡住时，makeKeyAndOrderFront 不一定能顶上来
        window?.orderFrontRegardless()
    }

    func refresh() {
        guard window != nil, let delegate else { return }
        statusLabel.stringValue = delegate.statusText
        enabledCheck.state = delegate.isFeatureEnabled ? .on : .off
        dimCheck.state = delegate.isDimEnabled ? .on : .off
        acCheck.state = delegate.isACOnly ? .on : .off
        autostartCheck.state = delegate.isAutostartEnabled ? .on : .off
        authButton.isHidden = delegate.isAuthorized
        testButton.isEnabled = delegate.canTestBrightness
    }

    // MARK: - UI

    private func buildWindow() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))

        let header = NSTextField(labelWithString: "🌙  合盖不休眠")
        header.font = .systemFont(ofSize: 17, weight: .semibold)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = 420
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let hint = NSTextField(labelWithString:
            "为了赶在合盖休眠之前生效，满足生效条件时（默认：接电源）程序会一直关闭系统休眠："
            + "这段时间 Mac 不会自动睡，显示器也不会自动熄。合盖时会把亮度归零，"
            + "注意放进包里会持续发热。退出程序即恢复系统原有设置。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = 420
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [authButton, testButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let logButton = NSButton(title: "查看日志", target: self, action: #selector(revealLog))
        let quitButton = NSButton(title: "退出程序", target: self, action: #selector(quit))
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.addView(logButton, in: .leading)
        bottomRow.addView(quitButton, in: .trailing)

        let divider1 = divider()
        let divider2 = divider()

        let stack = NSStackView(views: [
            header, statusLabel, divider1,
            enabledCheck, dimCheck, acCheck, autostartCheck,
            buttonRow, divider2, hint, bottomRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider1.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider2.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "合盖不休眠"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LidNoSleepPanel")

        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        window.setContentSize(NSSize(width: max(460, fitting.width), height: fitting.height))
        self.window = window
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func checkbox(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.font = .systemFont(ofSize: 13)
        return button
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        delegate?.setFeatureEnabled(enabledCheck.state == .on)
        refresh()
    }

    @objc private func toggleDim() {
        delegate?.setDimEnabled(dimCheck.state == .on)
        refresh()
    }

    @objc private func toggleACOnly() {
        delegate?.setACOnly(acCheck.state == .on)
        refresh()
    }

    @objc private func toggleAutostart() {
        delegate?.setAutostart(autostartCheck.state == .on)
        refresh()
    }

    @objc private func authorize() {
        delegate?.requestAuthorization()
        refresh()
    }

    @objc private func testDim() {
        delegate?.runBrightnessTest()
    }

    @objc private func revealLog() {
        delegate?.revealLog()
    }

    @objc private func quit() {
        delegate?.quitApp()
    }
}
