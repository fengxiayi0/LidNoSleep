import Foundation

enum LogFile {
    static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LidNoSleep.log").path
    }

    static var url: URL { URL(fileURLWithPath: path) }
}

private let logQueue = DispatchQueue(label: "com.zcode.lidnosleep.log")

private func logTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date())
}

/// 写日志到 ~/Library/Logs/LidNoSleep.log（超过 256KB 自动清空），同时进系统日志。
func log(_ message: String) {
    NSLog("LidNoSleep: %@", message)
    let line = "[\(logTimestamp())] \(message)\n"
    logQueue.async {
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: LogFile.path),
           let size = attributes[.size] as? Int, size > 256 * 1024 {
            try? fileManager.removeItem(at: LogFile.url)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: LogFile.url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: LogFile.url)
        }
    }
}
