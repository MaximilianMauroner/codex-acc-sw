import Darwin
import Foundation

struct CapturedProcessResult {
    let status: Int32
    let output: Data
    let error: Data
    let timedOut: Bool
}

enum ProcessCapture {
    static func run(_ process: Process, timeout: TimeInterval) throws -> CapturedProcessResult {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let reads = DispatchGroup()
        var outputData = Data()
        var errorData = Data()
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            reads.leave()
        }

        let exit = DispatchGroup()
        exit.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exit.leave()
        }

        let timedOut = exit.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exit.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exit.wait()
            }
        }
        reads.wait()

        return CapturedProcessResult(
            status: process.terminationStatus,
            output: outputData,
            error: errorData,
            timedOut: timedOut
        )
    }
}
