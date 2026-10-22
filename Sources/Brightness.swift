import Foundation
import CoreGraphics

/// 通过私有框架 DisplayServices 控制屏幕亮度。
/// 这是系统「亮度键」调用的同一个接口，在 Apple Silicon 上工作正常。
/// 仅对内置屏（以及部分 Apple 显示器）有效，第三方显示器需走 DDC，不在本工具范围内。
final class BrightnessController {
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var setFn: SetBrightnessFn?
    private var getFn: GetBrightnessFn?

    /// 归零前记录的亮度，用于恢复
    private var savedBrightness: [CGDirectDisplayID: Float] = [:]
    private var fallbackBrightness: Float?
    private var retryDeadline: Date?
    private(set) var isDimmed = false

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        frameworkHandle = handle
        if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
            setFn = unsafeBitCast(symbol, to: SetBrightnessFn.self)
        }
        if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getFn = unsafeBitCast(symbol, to: GetBrightnessFn.self)
        }
    }

    var isSupported: Bool { setFn != nil && getFn != nil }

    var currentBrightness: Float? {
        for id in activeDisplayIDs() {
            if let value = brightness(of: id), value >= 0 { return value }
        }
        return nil
    }

    /// 把所有可控屏幕的亮度设为 0（背光关闭），并记住原亮度。
    func dimToZero() {
        guard let setFn else { return }
        let wasDimmed = isDimmed
        if !wasDimmed {
            savedBrightness.removeAll()
            fallbackBrightness = nil
        }

        for id in activeDisplayIDs() {
            if !wasDimmed, let value = brightness(of: id), value > 0.005 {
                savedBrightness[id] = value
            }
            _ = setFn(id, 0)
        }
        if !wasDimmed {
            fallbackBrightness = savedBrightness.values.max()
        }
        isDimmed = true
        retryDeadline = nil
        if wasDimmed {
            log("亮度被系统改回，已重新归零")
        } else {
            log("亮度已归零（记录原值: \(savedBrightness)）")
        }
    }

    /// 恢复到归零前的亮度。屏幕若因合盖暂时离线，会在随后几秒内自动重试。
    func restoreIfDimmed() {
        guard isDimmed else { return }
        guard let setFn else {
            isDimmed = false
            return
        }

        let ids = activeDisplayIDs()
        guard !ids.isEmpty else {
            // 合盖时内置屏可能已从活动列表消失，等屏幕回来再恢复
            retryDeadline = Date().addingTimeInterval(8)
            return
        }

        for id in ids {
            if let value = savedBrightness[id] ?? fallbackBrightness {
                _ = setFn(id, value)
            }
        }
        savedBrightness.removeAll()
        fallbackBrightness = nil
        retryDeadline = nil
        isDimmed = false
        log("亮度已恢复")
    }

    func retryRestoreIfNeeded() {
        guard retryDeadline != nil else { return }
        if let deadline = retryDeadline, Date() >= deadline {
            retryDeadline = nil
            savedBrightness.removeAll()
            fallbackBrightness = nil
            isDimmed = false
            return
        }
        restoreIfDimmed()
    }

    // MARK: - Helpers

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func brightness(of id: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = -1
        guard getFn(id, &value) == 0 else { return nil }
        return value
    }
}
