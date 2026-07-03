import Foundation

struct BashTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "bash",
            description: "Run a zsh command in the workspace directory. stdout and stderr are merged. Default timeout 120s (set timeout_ms, max 600000). Prefer read_file/list_dir/glob/grep over cat/ls/find/grep for reading and searching.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The command to execute."],
                    "timeout_ms": ["type": "integer", "description": "Timeout in milliseconds (default 120000, max 600000)."],
                ],
                "required": ["command"],
            ]
        )
    }

    var permissionClass: PermissionClass { .execute }

    func summarize(input: JSONValue) -> String {
        let firstLine = (input["command"]?.stringValue ?? "?")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? "?"
        return "$ " + String(firstLine.prefix(80))
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let command = input["command"]?.stringValue, !command.isEmpty else {
            return .error("bash: missing required parameter `command`.")
        }
        let timeoutMs = input["timeout_ms"]?.intValue ?? 120_000
        let timeout = min(max(Double(timeoutMs) / 1000.0, 1), 600)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = context.workspaceRoot
        var env = ProcessInfo.processInfo.environment
        // GUI apps inherit a minimal PATH; prepend the usual CLI locations.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .error("Failed to launch command: \(error.localizedDescription)")
        }

        let timedOut = await Self.waitForExit(process, timeout: timeout)

        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            collector.append(rest)
        }

        var output = String(decoding: collector.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { output = "(no output)" }

        let hint = DisplayHint.commandOutput(command: command)
        if timedOut {
            return ToolOutput(
                content: Util.truncateForModel(output, maxChars: 50_000)
                    + "\n[command timed out after \(Int(timeout))s]",
                isError: true, displayHint: hint)
        }
        let code = process.terminationStatus
        if code != 0 {
            return ToolOutput(
                content: Util.truncateForModel(output, maxChars: 50_000) + "\n[exit code \(code)]",
                isError: true, displayHint: hint)
        }
        return ToolOutput(content: Util.truncateForModel(output, maxChars: 50_000), displayHint: hint)
    }

    /// Waits for exit; on timeout sends SIGTERM, then SIGKILL after a 2s grace.
    /// Returns true when the command timed out.
    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let timedOut = Flag()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Flag()
            process.terminationHandler = { _ in
                if once.setIfUnset() { cont.resume() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                _ = timedOut.setIfUnset()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        return timedOut.isSet
    }
}

// MARK: - Thread-safe helpers

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        // Cap runaway output at 4MB — plenty past the 50k-char model cut.
        if buffer.count < 4_000_000 { buffer.append(d) }
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Returns true only for the caller that flips it.
    func setIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
