import Foundation
import Darwin

/// One event from a running child process.
enum ShellEvent {
    case line(String)
    case finished(exitCode: Int32)
}

enum ShellError: LocalizedError {
    case launchFailed(String)
    /// `summary` is what to put in front of a human — "Build failed" — not the
    /// argv. Reading it as a command name is how the status pill ended up
    /// saying "Build failed exited with code 65".
    case failed(summary: String, exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let why):
            return "Could not launch process: \(why)"
        case .failed(let summary, let code):
            return "\(summary) (exit code \(code))"
        }
    }
}

/// Thread-safe accumulator that turns raw pipe data into whole lines.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func take(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let raw = data[data.startIndex..<newline]
            data.removeSubrange(data.startIndex...newline)
            lines.append(String(decoding: raw, as: UTF8.self))
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        let rest = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return rest.isEmpty ? nil : rest
    }
}

enum Shell {

    /// How long a child gets to exit after SIGTERM before it is killed outright.
    static let terminationGrace: TimeInterval = 5

    /// Upper bound on lines held in the stream if the consumer falls behind.
    /// `xcodebuild` can emit hundreds of thousands of lines; an unbounded
    /// buffer would let one bad build grow the app's memory without limit.
    /// Oldest lines are dropped, which matches what the log view keeps anyway.
    static let bufferedLines = 50_000

    /// Runs `tool args…`, streaming merged stdout/stderr line by line.
    ///
    /// Cancelling the consuming `Task` terminates the child process, so a stuck
    /// `xcodebuild` never outlives the Stop button.
    static func stream(_ tool: String,
                       _ arguments: [String],
                       currentDirectory: URL? = nil,
                       environment extra: [String: String] = [:]) -> AsyncThrowingStream<ShellEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(bufferedLines)) { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            if !extra.isEmpty {
                var env = ProcessInfo.processInfo.environment
                for (key, value) in extra { env[key] = value }
                process.environment = env
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            let buffer = LineBuffer()
            let reader = pipe.fileHandleForReading

            // The stream ends only once the pipe has hit end-of-file *and* the
            // process has exited, and only the readability handler ever reads.
            // Finishing from the termination handler instead raced the reader:
            // a chunk it had already pulled off the pipe was yielded after
            // `finish()` and silently dropped — sometimes the whole output,
            // and usually the last lines, which is where xcodebuild puts the
            // error worth reading.
            let done = DispatchGroup()
            done.enter()    // end-of-file
            done.enter()    // process exit

            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    if let tail = buffer.flush() { continuation.yield(.line(tail)) }
                    done.leave()
                    return
                }
                for line in buffer.take(chunk) { continuation.yield(.line(line)) }
            }

            process.terminationHandler = { _ in done.leave() }

            continuation.onTermination = { _ in
                guard process.isRunning else { return }
                process.terminate()
                // SIGTERM is a request, and a wedged xcodebuild is entitled to
                // ignore it. Stop has to actually stop things, so escalate.
                DispatchQueue.global().asyncAfter(deadline: .now() + terminationGrace) {
                    guard process.isRunning else { return }
                    kill(process.processIdentifier, SIGKILL)
                }
            }

            do {
                try process.run()
            } catch {
                reader.readabilityHandler = nil
                continuation.finish(throwing: ShellError.launchFailed(error.localizedDescription))
                return
            }

            done.notify(queue: .global()) {
                let code = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus
                                                                        : process.terminationStatus
                continuation.yield(.finished(exitCode: code))
                continuation.finish()
            }
        }
    }

    /// Runs a command to completion and returns its exit code plus captured output.
    @discardableResult
    static func capture(_ tool: String,
                        _ arguments: [String],
                        currentDirectory: URL? = nil) async throws -> (exitCode: Int32, output: String) {
        var collected: [String] = []
        var code: Int32 = -1
        for try await event in stream(tool, arguments, currentDirectory: currentDirectory) {
            switch event {
            case .line(let line): collected.append(line)
            case .finished(let exitCode): code = exitCode
            }
        }
        return (code, collected.joined(separator: "\n"))
    }

    /// Pretty-prints a command the way you would type it in Terminal.
    static func describe(_ tool: String, _ arguments: [String]) -> String {
        ([tool] + arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }
}
