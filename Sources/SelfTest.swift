import Foundation
import CoreGraphics

/// `LidNoSleep --self-test`：不启动图形界面，直接验证各能力是否可用。
func runSelfTest() -> Int32 {
    print("LidNoSleep 自检")
    print("──────────────────────────────────────")

    let lid = LidMonitor()
    if lid.hasLid {
        print("上盖：\(lid.isLidClosed ? "已合上" : "已打开")")
    } else {
        print("上盖：本机没有内置屏幕（无需本工具）")
    }

    print("电源：\(PowerSource.isOnAC() ? "电源适配器" : "电池")"
        + (PowerSource.batteryPercent().map { "（\($0)%）" } ?? ""))

    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)
    print("活动显示器数量：\(displayCount)")

    let brightness = BrightnessController()
    guard brightness.isSupported else {
        print("亮度控制：不支持（DisplayServices 无法加载）")
        return 1
    }
    print("亮度控制：支持")

    guard let original = brightness.currentBrightness else {
        print("当前亮度：读取失败")
        return 1
    }
    print(String(format: "当前亮度：%.1f%%", original * 100))

    let sleepControl = SleepControl()
    print("sudo 权限：\(sleepControl.isAuthorized() ? "已授权" : "未授权（菜单里点「完成一次性授权」）")")
    print("系统休眠设置：\(sleepControl.sleepDisabledSystemWide() == true ? "已禁用" : "正常")")

    print("──────────────────────────────────────")
    print("把亮度设为 0，保持 2 秒后恢复…")
    brightness.dimToZero()
    Thread.sleep(forTimeInterval: 2.0)

    if let dimmed = brightness.currentBrightness {
        print(String(format: "亮度归零后：%.1f%%  %@", dimmed * 100, dimmed < 0.02 ? "✓" : "✗ 未生效"))
    }
    brightness.restoreIfDimmed()

    if let restored = brightness.currentBrightness {
        print(String(format: "恢复后：%.1f%%", restored * 100))
        return abs(restored - original) < 0.02 ? 0 : 1
    }
    return 1
}
