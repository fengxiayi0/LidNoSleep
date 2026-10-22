import Foundation

/// 登录自启动：写 ~/Library/LaunchAgents 下的 plist 即可，
/// launchd 会在下次登录时自动加载（无需 sudo）。
///
/// 注意：这里刻意不调用 launchctl bootstrap/bootout —— 当 App 正在运行时，
/// 对自身所在 job 执行 bootout 会把自己杀掉。
enum LaunchAgent {
    static let label = "com.zcode.lidnosleep"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install() -> String? {
        guard let executable = Bundle.main.executableURL?.path else {
            return "无法确定 App 可执行文件路径。"
        }
        // 自启动项指向的路径必须长期存在，否则登录时会静默失败
        guard executable.hasPrefix("/Applications/") || executable.hasPrefix(NSHomeDirectory() + "/Applications/") else {
            return "请先运行 ./install.sh 把 App 安装到「应用程序」文件夹，再开启开机自启动。\n当前路径：\(executable)"
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--background"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return "写入 LaunchAgent 失败：\(error.localizedDescription)"
        }
        log("已开启开机自启动（下次登录生效）：\(executable)")
        return nil
    }

    static func remove() -> String? {
        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch {
            return "删除 LaunchAgent 失败：\(error.localizedDescription)"
        }
        log("已关闭开机自启动")
        return nil
    }
}
