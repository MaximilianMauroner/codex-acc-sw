import Darwin
import Foundation
import XCTest
@testable import AIUsageBar

final class ProcessCaptureTests: XCTestCase {
    func testCapturesStandardOutputAndError() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf captured-output; printf captured-error >&2"]

        let result = try ProcessCapture.run(process, timeout: 2)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "captured-output")
        XCTAssertEqual(String(data: result.error, encoding: .utf8), "captured-error")
    }

    func testPassesConfiguredStandardInputToSpawnedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe()
        process.standardInput = input
        input.fileHandleForWriting.write(Data("configured-input".utf8))
        try input.fileHandleForWriting.close()

        let result = try ProcessCapture.run(process, timeout: 2)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "configured-input")
    }

    func testExplicitNilStandardInputReadsEOF() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = nil

        let result = try ProcessCapture.run(process, timeout: 2)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty)
    }

    func testReturnsNonzeroExitStatus() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 23"]

        let result = try ProcessCapture.run(process, timeout: 2)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 23)
    }

    func testReturnsTerminatingSignalAsStatus() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "kill -TERM $$"]

        let result = try ProcessCapture.run(process, timeout: 2)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, SIGTERM)
    }

    func testTimeoutKillsDescendantThatKeepsBothPipesOpen() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sh -c 'trap \"\" TERM; echo descendant-pid=$$; echo captured-before-kill >&2; while :; do sleep 1; done' & exit 0"
        ]
        let started = Date()

        let result = try ProcessCapture.run(process, timeout: 0.5)

        let output = try XCTUnwrap(String(data: result.output, encoding: .utf8))
        let pid = try XCTUnwrap(pidAfterPrefix("descendant-pid=", in: output))
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(String(data: result.error, encoding: .utf8), "captured-before-kill\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertTrue(waitForExit(pid), "descendant \(pid) survived ProcessCapture.run")
    }

    func testTimeoutKillsChildWhileLauncherIsStillRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 30 & child=$!; echo child-pid=$child; echo stderr-marker >&2; wait"
        ]
        let started = Date()

        let result = try ProcessCapture.run(process, timeout: 0.5)

        let output = try XCTUnwrap(String(data: result.output, encoding: .utf8))
        let pid = try XCTUnwrap(pidAfterPrefix("child-pid=", in: output))
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(String(data: result.error, encoding: .utf8), "stderr-marker\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertTrue(waitForExit(pid), "child \(pid) survived ProcessCapture.run")
    }

    private func pidAfterPrefix(_ prefix: String, in output: String) -> pid_t? {
        output.split(separator: "\n").lazy
            .map(String.init)
            .first { $0.hasPrefix(prefix) }
            .flatMap { pid_t($0.dropFirst(prefix.count)) }
    }

    private func waitForExit(_ pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if kill(pid, 0) == -1 && errno == ESRCH {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }
}
