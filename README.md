# 合盖不休眠（LidNoSleep）

一个 macOS 菜单栏小工具：**合上盖子时把屏幕亮度调为 0，同时让系统继续运行（不休眠）**；打开盖子后恢复亮度，退出时恢复系统的休眠设置。

已在本机验证：Apple M5 / macOS 26.5.2。亮度归零与恢复可精确到小数点后 3 位。

## 功能

| 功能 | 实现 |
|------|------|
| 监听上盖 | IOKit `IOPMrootDomain` 的 `AppleClamshellState`，每秒读取一次 |
| 亮度归零 / 恢复 | 私有框架 `DisplayServices`（系统亮度键用的同一个接口），记住原值后恢复 |
| 阻止合盖休眠 | `sudo pmset -a disablesleep 1`（唯一可靠方式，见下） |
| 防空闲休眠 | `IOKit` 的 `PreventUserIdleSystemSleep` 断言（辅助） |
| 安全兜底 | 默认「仅接电源时生效」；异常退出后重新打开会自动修正休眠设置 |

## 为什么需要一次性授权

macOS 上「合盖立即休眠」是固件 / powerd 的行为，`caffeinate` 和 IOKit 的防休眠断言**都拦不住合盖休眠**。唯一可靠的软件方式是 `pmset -a disablesleep 1`，它需要 root。

所以本工具只申请一条最小权限规则，写入 `/etc/sudoers.d/lidnosleep`：

```
<你的用户名> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

只允许这一条命令的两个取值，不能执行其他任何 root 操作。

## 安装

```bash
cd LidNoSleep
./install.sh
```

脚本会：编译 → 安装到 `/Applications/LidNoSleep.app` → 写入 sudoers 规则（需要输一次密码）→ 启动。

之后：
- 打开 App 会显示控制面板（菜单栏空间够时也会出现月亮图标）。
- 勾选「开机自启动」写 `~/Library/LaunchAgents/com.zcode.lidnosleep.plist`，登录时以后台模式启动，不弹窗。
- 菜单栏图标若被 macOS 藏起来（菜单栏排满时会排到刘海区域，系统不给显示），直接打开 App 用控制面板即可。

## 使用

1. 打开 App，点「完成授权…」（已用 `install.sh` 装过则跳过）。
2. 保持勾选「合盖时保持运行」「合盖时把屏幕亮度调为 0」「仅在接电源时生效」。
3. 合上盖子 → 屏幕熄灭（亮度 0），系统继续运行；打开盖子 → 亮度恢复。
4. 想临时停用：取消勾选第一条（钉住菜单栏时也可用菜单）。退出程序会恢复系统的休眠设置。

## 验证

```bash
# 自检（会真的把亮度归零 2 秒再恢复）
/Applications/LidNoSleep.app/Contents/MacOS/LidNoSleep --self-test

# 授权后、接电源、功能开启时应为 1
pmset -g live | grep SleepDisabled

# 合盖后用手机 ping 本机 / SSH 登录 / 后台任务是否继续
```

日志：`~/Library/Logs/LidNoSleep.log`（App 菜单或控制面板里的「查看日志」可直接打开）。

## 重要行为与风险（请务必读）

- **程序会提前关闭系统休眠。** 合盖后系统几乎立刻休眠，事后再改设置来不及，所以只要「生效条件」满足（默认：接电源），程序就会先把 `disablesleep` 置 1。这段时间内 Mac **不会自动休眠**，**显示器也不会自动熄灭**（`disablesleep` 会连带让显示休眠失效）。这也是合盖后能继续运行的前提。
- **亮度归零不是装饰。** 因为合盖时系统不会休眠，面板背光会一直亮着；把亮度设为 0 正好关掉背光，开盖再恢复原值。
- **散热**：`disablesleep=1` 时合盖放入包里，机器会持续运行并发热。建议保持「仅接电源时生效」，不用时取消勾选或退出程序。
- **外接显示器亮度**：`DisplayServices` 只管内置屏（和部分 Apple 显示器）；第三方显示器走 DDC，本工具不处理。
- **系统升级风险**：`DisplayServices` 是私有框架，`disablesleep` 是未公开文档的 `pmset` 开关，macOS 大版本升级后可能失效。失效时工具会显示「未授权」或亮度不生效，日志里能看到原因。
- **异常退出**：崩溃或被强杀可能留下 `disablesleep=1`。重新打开 App 会自动修正；也可手动执行 `sudo pmset -a disablesleep 0`。
- 本机若是 iMac / Mac mini 等没有上盖的机型，工具会提示「本机没有内置屏幕」，无需使用。

## 卸载

```bash
./uninstall.sh
```

会退出 App、`pmset -a disablesleep 0`、删除 sudoers 规则 / LaunchAgent / App / 日志 / 偏好设置。

## 目录结构

```
LidNoSleep/
├── Sources/
│   ├── main.swift              入口（含 --self-test）
│   ├── AppDelegate.swift       状态机、菜单栏、授权流程
│   ├── ControlPanel.swift      控制面板（菜单栏排满时的主界面）
│   ├── Brightness.swift        DisplayServices 亮度读写
│   ├── SystemInfo.swift        上盖状态、电源状态
│   ├── SleepControl.swift      pmset disablesleep + IOKit 断言
│   ├── LaunchAgent.swift       开机自启动
│   ├── ProcessRunner.swift     外部命令执行
│   ├── Logger.swift            日志
│   └── SelfTest.swift          自检
├── Resources/Info.plist
├── build.sh
├── install.sh
└── uninstall.sh
```

## 构建

```bash
./build.sh   # 产物：build/LidNoSleep.app（arm64, macOS 13+）
```
