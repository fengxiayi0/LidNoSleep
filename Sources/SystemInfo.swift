import Foundation
import IOKit
import IOKit.ps

/// 读取笔记本盖子（clamshell）状态。
/// AppleClamshellState 由 powerd 实时维护：true = 盖子已合上。
final class LidMonitor {
    private let rootDomain: io_service_t

    init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    }

    deinit {
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
    }

    /// 本机是否真的有上盖（iMac / Mac mini 等返回 false）
    var hasLid: Bool { clamshellState != nil }

    var isLidClosed: Bool { clamshellState ?? false }

    /// 系统是否认为「合盖会休眠」（仅供参考，会随电源与显示器配置变化）
    var clamshellCausesSleep: Bool? {
        guard rootDomain != 0,
              let value = IORegistryEntryCreateCFProperty(
                  rootDomain, "AppleClamshellCausesSleep" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private var clamshellState: Bool? {
        guard rootDomain != 0,
              let value = IORegistryEntryCreateCFProperty(
                  rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}

enum PowerSource {
    static func isOnAC() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let typeRef = IOPSGetProvidingPowerSourceType(snapshot) else {
            return true
        }
        return (typeRef.takeUnretainedValue() as String) == "AC Power"
    }

    static func batteryPercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            guard (description["Type"] as? String) == "InternalBattery",
                  let current = description["Current Capacity"] as? Int,
                  let maximum = description["Max Capacity"] as? Int,
                  maximum > 0 else { continue }
            return Int((Double(current) / Double(maximum) * 100).rounded())
        }
        return nil
    }
}
