import Darwin
import Foundation

@MainActor
enum Launch {
    static func run(file: String, args: [String], bottleName: String, extraEnv: [String: String]) async throws {
        var exe = URL(filePath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: exe.path(percentEncoded: false)) else { throw DecantError("no such file: \(file)") }
        try await Runtime.ensureInstalled()
        let bottle = try Bottles.open(bottleName, create: true)
        var args = args
        if exe.pathExtension.lowercased() == "msi" {
            // Z: maps to the macOS root.
            args = ["/i", "Z:" + exe.path(percentEncoded: false).replacingOccurrences(of: "/", with: "\\")] + args
            exe = bottle.appending(path: "drive_c/windows/system32/msiexec.exe")
        }
        let command = try await Kit.prepareLaunch(exe: exe, args: args, bottle: bottle, extraEnv: extraEnv)

        let logs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/\(Kit.bundleID)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let log = logs.appending(path: "\(stamp)-\(exe.deletingPathExtension().lastPathComponent).log")
        let pid = try spawnDetached(command, log: log)
        print("started \(exe.lastPathComponent) in bottle '\(bottleName)' (pid \(pid)); log: \(log.path)")
    }

    /// Runs `/bin/sh -c command` in a new session with output to `log`, so it
    /// outlives decant and holds none of its file descriptors.
    static func spawnDetached(_ command: String, log: URL) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path(percentEncoded: false), O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, environ)
        guard rc == 0 else { throw DecantError("posix_spawn failed: \(String(cString: strerror(rc)))") }
        return pid
    }
}
