import Foundation
import IOKit.pwr_mgt

final class SleepControl {
    private var assertionID: IOPMAssertionID = 0
    private(set) var holdingAssertion = false

    /// 阻止「空闲导致的系统休眠」。
    /// 注意：这个断言无法阻止合盖休眠 —— 合盖立即休眠是固件/powerd 的行为，
    /// 只能通过 pmset disablesleep 关闭，因此两者都要用。
    func holdSystemAwake(reason: String) {
        guard !holdingAssertion else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            holdingAssertion = true
            log("已创建防休眠断言 #\(id)")
        } else {
            log("创建防休眠断言失败：IOReturn \(result)")
        }
    }

    func releaseSystemAwake() {
        guard holdingAssertion else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        holdingAssertion = false
        log("已释放防休眠断言")
    }

    /// 全局关闭/恢复休眠（pmset -a disablesleep），需要 root 权限。
    func setSleepDisabled(_ disabled: Bool) -> (ok: Bool, message: String) {
        let result = runProcess(
            "/usr/bin/sudo",
            ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        )
        if result.status == 0 { return (true, "") }
        let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, message)
    }

    /// 只检查该 sudo 规则是否存在，不改变任何状态
    func isAuthorized() -> Bool {
        runProcess(
            "/usr/bin/sudo",
            ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]
        ).status == 0
    }

    func sleepDisabledSystemWide() -> Bool? {
        let result = runProcess("/usr/bin/pmset", ["-g", "live"])
        guard result.status == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] != "0"
            }
        }
        return nil
    }
}
