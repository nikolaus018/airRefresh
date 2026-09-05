import Testing
import Foundation
@testable import AirRefresh

/// `Shell` is the only place in the app doing real concurrency, and everything
/// else is built on it, so it gets exercised against actual processes.
struct ShellTests {

    private func collect(_ tool: String, _ args: [String]) async throws -> (lines: [String], exitCode: Int32) {
        var lines: [String] = []
        var code: Int32 = -999
        for try await event in Shell.stream(tool, args) {
            switch event {
            case .line(let line): lines.append(line)
            case .finished(let exitCode): code = exitCode
            }
        }
        return (lines, code)
    }

    @Test func streamsWholeLines() async throws {
        let result = try await collect("/bin/echo", ["one\ntwo\nthree"])
        #expect(result.lines == ["one", "two", "three"])
        #expect(result.exitCode == 0)
    }

    /// Output arriving in pieces that do not line up with newlines is the
    /// normal case for a pipe, and the line buffer has to stitch it back up.
    @Test func reassemblesOutputSplitAcrossReads() async throws {
        let script = "printf 'alpha'; sleep 0.1; printf 'beta\\n'; printf 'gamma\\n'"
        let result = try await collect("/bin/sh", ["-c", script])
        #expect(result.lines == ["alphabeta", "gamma"])
    }

    /// A last line with no trailing newline must not be swallowed — that is
    /// exactly where xcodebuild likes to put its final error.
    @Test func emitsATrailingLineWithNoNewline() async throws {
        let result = try await collect("/bin/sh", ["-c", "printf 'no newline here'"])
        #expect(result.lines == ["no newline here"])
    }

    @Test func mergesStandardErrorIntoTheSameStream() async throws {
        let result = try await collect("/bin/sh", ["-c", "echo out; echo err >&2"])
        #expect(result.lines.sorted() == ["err", "out"])
    }

    @Test func reportsTheExitCode() async throws {
        #expect(try await collect("/bin/sh", ["-c", "exit 42"]).exitCode == 42)
    }

    /// A process killed by a signal must not look like a clean exit 0.
    @Test func signalsBecomeDistinctExitCodes() async throws {
        let result = try await collect("/bin/sh", ["-c", "kill -TERM $$"])
        #expect(result.exitCode == 128 + 15)
    }

    @Test func aMissingBinaryThrowsRatherThanHanging() async {
        await #expect(throws: ShellError.self) {
            _ = try await Shell.capture("/nonexistent/definitely-not-a-tool", [])
        }
    }

    /// The Stop button's contract: cancelling the consuming task must actually
    /// end the child process, not leave it running behind the UI.
    @Test func cancellingTheTaskStopsTheChild() async throws {
        let started = Date()
        let task = Task {
            for try await _ in Shell.stream("/bin/sh", ["-c", "sleep 30"]) {}
        }
        // Give it a moment to be genuinely running, then pull the plug.
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value

        #expect(Date().timeIntervalSince(started) < 10,
                "cancellation should not wait out the child's own 30s sleep")
    }

    @Test func captureCollectsEverythingAsOneString() async throws {
        let result = try await Shell.capture("/bin/sh", ["-c", "echo first; echo second"])
        #expect(result.exitCode == 0)
        #expect(result.output == "first\nsecond")
    }

    @Test func describeReadsLikeSomethingYouCouldPaste() {
        let described = Shell.describe("/usr/bin/xcrun", [
            "xcodebuild", "-project", "/Users/me/My Project/App.xcodeproj", "build"
        ])
        #expect(described == #"/usr/bin/xcrun xcodebuild -project "/Users/me/My Project/App.xcodeproj" build"#)
    }
}

struct SchemeFailureMessageTests {

    @Test func liftsXcodebuildsActualComplaint() {
        let output = """
        Command line invocation:
            /usr/bin/xcodebuild -list -json

        xcodebuild: error: The directory /Users/me/Nope does not contain an Xcode project.
        """
        #expect(AppState.schemeFailureMessage(output)
                == "The directory /Users/me/Nope does not contain an Xcode project.")
    }

    @Test func fallsBackWhenThereIsNothingUseful() {
        #expect(AppState.schemeFailureMessage(nil).hasPrefix("Could not read"))
        #expect(AppState.schemeFailureMessage("").hasPrefix("Could not read"))
        #expect(AppState.schemeFailureMessage("just some chatter").hasPrefix("Could not read"))
    }
}
