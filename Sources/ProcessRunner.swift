import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// 运行外部命令并等待结束。所有调用都在极短命令（pmset / sudo / osascript）上，
/// 因此在主线程以轮询方式等待是可以接受的。
@discardableResult
func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    if process.isRunning {
        process.terminate()
        let killDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < killDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: outData, encoding: .utf8) ?? ""
    let err = String(data: errData, encoding: .utf8) ?? ""
    return ProcessResult(status: process.isRunning ? -2 : process.terminationStatus, stdout: out, stderr: err)
}

extension String {
    /// 用单引号包住，供 shell 安全使用（内含单引号会被转义）。
    var shellSingleQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 转义为 AppleScript 字符串字面量内容（调用方保证命令本身是单行）。
    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
