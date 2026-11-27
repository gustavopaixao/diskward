import Foundation

/// Runs command-line tools. GUI apps don't inherit the shell PATH, so we search the usual
/// Homebrew / Docker Desktop locations ourselves.
public enum ShellRunner {
    public static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
        public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        public var succeeded: Bool { status == 0 }
    }

    public static func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    /// Runs `tool` (name or absolute path) and waits for it, killing it after `timeout` seconds.
    public static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 60) async throws -> Output {
        guard let executable = which(tool) else { throw ProviderError("\(tool) not found") }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                env["NO_COLOR"] = "1"
                process.environment = env

                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                // Drain stderr concurrently so a chatty tool can't fill the pipe and deadlock.
                let errBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()

                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: outData,
                    stderr: String(decoding: errBox.data, as: UTF8.self)
                ))
            }
        }
    }
}
