#if os(macOS)
import Foundation
import Transport

/// `meep lsp` as a program on this Mac: finding `meep`, starting it, and stopping it. (The iPad will reach a
/// language server through a daemon instead: Meep2 prompt 8.)
public final class LanguageServerProcess: @unchecked Sendable {
    public let executable: String
    public let stream: PipeStream
    private let process: Process

    /// Starts `meep lsp` from `executable`.
    public init(executable: String, environment: [String: String]? = nil) throws {
        self.executable = executable
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["lsp"]
        if let environment { process.environment = environment }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        stream = PipeStream(reading: output.fileHandleForReading, writing: input.fileHandleForWriting)
    }

    public var isRunning: Bool { process.isRunning }

    /// Stops it, if asking it to exit didn't.
    public func terminate() {
        stream.close()
        if process.isRunning { process.terminate() }
    }

    /// Where `meep` is: `$MEEP_EXECUTABLE`, then `$PATH`, then the login shell's `PATH` (which an app started from the
    /// Finder doesn't have), then the usual places for .NET tools. Nil if it isn't anywhere.
    public static func findMeep(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let files = FileManager.default
        if let given = environment["MEEP_EXECUTABLE"], files.isExecutableFile(atPath: given) { return given }
        let home = NSHomeDirectory()
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += loginShellPath(environment: environment)
        directories += ["\(home)/.dotnet/tools", "/usr/local/bin", "/opt/homebrew/bin", "\(home)/.local/bin"]
        for directory in directories where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent("meep")
            if files.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The `PATH` an interactive login shell sets up, asked for once, with a time limit.
    private static func loginShellPath(environment: [String: String]) -> [String] {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '%s' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            return []
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // A shell's start-up files can print other things; the PATH is the last line.
        return (text.split(separator: "\n").last ?? "").split(separator: ":").map(String.init)
    }
}
#endif
