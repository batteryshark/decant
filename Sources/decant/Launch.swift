// Turn a file argument into a Wine launch and start it detached.
import Darwin
import Foundation

@MainActor
enum Launch {
    static var logsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/\(Kit.bundleID)")
    }

    /// `C:\foo\bar.exe` maps into the bottle's drive_c; anything else is a macOS path.
    static func resolve(_ raw: String, bottle: URL) -> URL {
        if raw.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
            let rest = raw.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
            return bottle.appending(path: "drive_\(raw.prefix(1).lowercased())").appending(path: rest)
        }
        return URL(filePath: raw, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)).standardizedFileURL
    }

    static func run(file raw: String, args: [String], bottleName: String, extraEnv: [String: String]) async throws {
        let isWindowsPath = raw.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
        if !isWindowsPath, !FileManager.default.fileExists(atPath: resolve(raw, bottle: Bottles.root).path(percentEncoded: false)) {
            throw DecantError.message("no such file: \(raw)")
        }
        try await Runtime.ensureInstalled()
        let bottle = try Bottles.open(bottleName, createIfMissing: true)
        var exe = resolve(raw, bottle: bottle)
        var args = args
        if exe.pathExtension.lowercased() == "msi" {
            // msiexec wants a Windows path; Z: is the root of the macOS filesystem.
            args = ["/i", "Z:" + exe.path(percentEncoded: false).replacingOccurrences(of: "/", with: "\\")] + args
            exe = bottle.appending(path: "drive_c/windows/system32/msiexec.exe")
        }
        if !FileManager.default.fileExists(atPath: bottle.appending(path: "drive_c").path(percentEncoded: false)) {
            print("first run in '\(bottleName)': creating the Wine prefix (takes ~30 s)")
        }
        let command = try await Kit.prepareLaunch(exe: exe, args: args, bottle: bottle, extraEnv: extraEnv)

        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let log = logsDir.appending(path: "\(stamp)-\(exe.deletingPathExtension().lastPathComponent).log")
        try "# decant \(exe.path) in bottle \(bottleName)\n# \(command)\n".write(to: log, atomically: false, encoding: .utf8)
        let pid = try spawnDetached(command, log: log)
        print("started \(exe.lastPathComponent) in bottle '\(bottleName)' (pid \(pid)); log: \(log.path)")
    }

    /// `/bin/sh -c command` in its own session, stdin from /dev/null and
    /// output to `log`, so it outlives us and holds none of our pipes.
    static func spawnDetached(_ command: String, log: URL) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path(percentEncoded: false), O_WRONLY | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, environ)
        guard rc == 0 else { throw DecantError.message("posix_spawn failed: \(String(cString: strerror(rc)))") }
        return pid
    }

    /// Foreground wine64 with the bottle's environment, for diagnostics (`decant wine reg query ...`).
    static func wine(_ args: [String], bottleName: String) async throws -> Int32 {
        try await Runtime.ensureInstalled()
        let bottle = try Bottles.open(bottleName, createIfMissing: false)
        let proc = Process()
        proc.executableURL = Kit.wineBinary
        proc.arguments = args
        proc.environment = ProcessInfo.processInfo.environment.merging(Kit.wineEnvironment(bottle: bottle)) { _, new in new }
        if let debug = ProcessInfo.processInfo.environment["WINEDEBUG"] { proc.environment?["WINEDEBUG"] = debug }
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
