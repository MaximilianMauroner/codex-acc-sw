import Darwin
import Foundation

struct CapturedProcessResult {
    let status: Int32
    let output: Data
    let error: Data
    let timedOut: Bool
}

enum ProcessCapture {
    private static let pollIntervalMicroseconds: useconds_t = 10_000
    private static let terminationGrace: TimeInterval = 1
    private static let finalDrainGrace: TimeInterval = 1

    static func run(_ process: Process, timeout: TimeInterval) throws -> CapturedProcessResult {
        guard let executableURL = process.executableURL else {
            throw CocoaError(.executableNotLoadable)
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        defer {
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForWriting.close()
        }

        let pid = try spawn(
            executableURL: executableURL,
            arguments: process.arguments ?? [],
            environment: process.environment ?? ProcessInfo.processInfo.environment,
            currentDirectoryURL: process.currentDirectoryURL,
            standardInput: process.standardInput,
            standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
            standardError: errorPipe.fileHandleForWriting.fileDescriptor
        )

        // Keep the child unreaped until capture finishes or the final signal is sent.
        // Its reserved PID makes the negative process-group ID safe from reuse.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        let outputFD = outputPipe.fileHandleForReading.fileDescriptor
        let errorFD = errorPipe.fileHandleForReading.fileDescriptor
        setNonBlocking(outputFD)
        setNonBlocking(errorFD)

        var output = Data()
        var error = Data()
        var outputIsOpen = true
        var errorIsOpen = true
        var waitStatus: Int32 = 0
        var childWasReaped = false
        let timeoutDeadline = deadline(after: timeout)

        while DispatchTime.now().uptimeNanoseconds < timeoutDeadline {
            drain(outputFD, into: &output, isOpen: &outputIsOpen)
            drain(errorFD, into: &error, isOpen: &errorIsOpen)

            if !outputIsOpen && !errorIsOpen {
                childWasReaped = reap(pid, status: &waitStatus, blocking: false)
                if childWasReaped {
                    return result(status: waitStatus, output: output, error: error, timedOut: false)
                }
            }

            usleep(pollIntervalMicroseconds)
        }

        // The task starts in a new process group before executing user code, and its
        // descendants inherit that group. Signal members that retain the inherited
        // group instead of taking a PID snapshot that can become stale.
        // A descendant that deliberately changes groups is outside this boundary.
        _ = kill(-pid, SIGTERM)
        drainUntil(
            deadline: deadline(after: terminationGrace),
            outputFD: outputFD,
            output: &output,
            outputIsOpen: &outputIsOpen,
            errorFD: errorFD,
            error: &error,
            errorIsOpen: &errorIsOpen
        )

        // The leader is still our live child or an unreaped zombie, so its PID cannot
        // have been assigned to another process group during the grace period.
        _ = kill(-pid, SIGKILL)

        let finalDeadline = deadline(after: finalDrainGrace)
        while DispatchTime.now().uptimeNanoseconds < finalDeadline {
            drain(outputFD, into: &output, isOpen: &outputIsOpen)
            drain(errorFD, into: &error, isOpen: &errorIsOpen)
            if !childWasReaped {
                childWasReaped = reap(pid, status: &waitStatus, blocking: false)
            }
            if childWasReaped && !outputIsOpen && !errorIsOpen {
                break
            }
            usleep(pollIntervalMicroseconds)
        }

        if !childWasReaped {
            childWasReaped = reap(pid, status: &waitStatus, blocking: false)
        }
        drain(outputFD, into: &output, isOpen: &outputIsOpen)
        drain(errorFD, into: &error, isOpen: &errorIsOpen)
        if !childWasReaped {
            // No synchronous waitpid call occurs after this ownership handoff.
            scheduleReaper(for: pid)
        }

        return CapturedProcessResult(
            status: childWasReaped ? decodedStatus(waitStatus) : SIGKILL,
            output: output,
            error: error,
            timedOut: true
        )
    }

    private static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        standardInput: Any?,
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var code = posix_spawn_file_actions_init(&fileActions)
        guard code == 0 else { throw posixError(code) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { throw posixError(code) }
        defer { posix_spawnattr_destroy(&attributes) }

        code = posix_spawnattr_setpgroup(&attributes, 0)
        guard code == 0 else { throw posixError(code) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        code = posix_spawnattr_setflags(&attributes, flags)
        guard code == 0 else { throw posixError(code) }

        if let currentDirectoryURL {
            code = currentDirectoryURL.path.withCString {
                posix_spawn_file_actions_addchdir_np(&fileActions, $0)
            }
            guard code == 0 else { throw posixError(code) }
        }

        if let inputFD = fileDescriptor(for: standardInput) {
            if inputFD == STDIN_FILENO {
                code = posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO)
            } else {
                code = posix_spawn_file_actions_adddup2(&fileActions, inputFD, STDIN_FILENO)
            }
            guard code == 0 else { throw posixError(code) }
        } else {
            // Process defaults this property to stdin. An explicit nil means
            // /dev/null, matching Foundation's EOF behavior.
            code = "/dev/null".withCString {
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    $0,
                    O_RDONLY,
                    0
                )
            }
            guard code == 0 else { throw posixError(code) }
        }
        code = posix_spawn_file_actions_adddup2(&fileActions, standardOutput, STDOUT_FILENO)
        guard code == 0 else { throw posixError(code) }
        code = posix_spawn_file_actions_adddup2(&fileActions, standardError, STDERR_FILENO)
        guard code == 0 else { throw posixError(code) }

        let argumentStrings = [executableURL.path] + arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        var argumentPointers = argumentStrings.map { strdup($0) }
        var environmentPointers = environmentStrings.map { strdup($0) }
        argumentPointers.append(nil)
        environmentPointers.append(nil)
        defer {
            argumentPointers.compactMap { $0 }.forEach { free($0) }
            environmentPointers.compactMap { $0 }.forEach { free($0) }
        }

        var pid: pid_t = 0
        code = executableURL.path.withCString {
            posix_spawn(
                &pid,
                $0,
                &fileActions,
                &attributes,
                &argumentPointers,
                &environmentPointers
            )
        }
        guard code == 0 else { throw posixError(code) }
        return pid
    }

    private static func fileDescriptor(for standardInput: Any?) -> Int32? {
        if let pipe = standardInput as? Pipe {
            return pipe.fileHandleForReading.fileDescriptor
        }
        return (standardInput as? FileHandle)?.fileDescriptor
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private static func drain(_ fileDescriptor: Int32, into data: inout Data, isOpen: inout Bool) {
        guard isOpen else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // A child that writes continuously must not keep this call inside read()
        // forever and prevent the outer loop from enforcing its deadline.
        for _ in 0..<64 {
            let byteCount = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if byteCount > 0 {
                data.append(contentsOf: buffer.prefix(byteCount))
            } else if byteCount == 0 {
                isOpen = false
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                isOpen = false
                return
            }
        }
    }

    private static func drainUntil(
        deadline: UInt64,
        outputFD: Int32,
        output: inout Data,
        outputIsOpen: inout Bool,
        errorFD: Int32,
        error: inout Data,
        errorIsOpen: inout Bool
    ) {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            drain(outputFD, into: &output, isOpen: &outputIsOpen)
            drain(errorFD, into: &error, isOpen: &errorIsOpen)
            if !outputIsOpen && !errorIsOpen {
                return
            }
            usleep(pollIntervalMicroseconds)
        }
    }

    private static func reap(_ pid: pid_t, status: inout Int32, blocking: Bool) -> Bool {
        while true {
            let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
            if result == pid { return true }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    private static func decodedStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return signal
    }

    private static func scheduleReaper(for pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

    private static func deadline(after interval: TimeInterval) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard interval.isFinite else {
            return interval > 0 ? UInt64.max : now
        }
        let seconds = max(0, interval)
        let maximumSeconds = Double(UInt64.max - now) / 1_000_000_000
        guard seconds < maximumSeconds else { return UInt64.max }
        return now + UInt64(seconds * 1_000_000_000)
    }

    private static func result(
        status: Int32,
        output: Data,
        error: Data,
        timedOut: Bool
    ) -> CapturedProcessResult {
        CapturedProcessResult(
            status: decodedStatus(status),
            output: output,
            error: error,
            timedOut: timedOut
        )
    }

    private static func posixError(_ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
