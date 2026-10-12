// decant: run Windows programs in Wine bottles, silently, through WhiskyKit.
import Foundation

enum DecantError: Error, CustomStringConvertible {
    case message(String)
    case badValue(String, String)
    case usage

    var description: String {
        switch self {
        case let .message(m): m
        case let .badValue(what, value): "invalid \(what): '\(value)'"
        case .usage: usageText
        }
    }
}

let usageText = """
usage:
  decant [--bottle NAME] [--env KEY=VALUE]... <file.exe|file.msi|C:\\path> [args...]
      run in bottle NAME (default "Default", created on demand) and return at once
  decant bottles list
  decant bottles create NAME [--windows VER] [--backend B]
  decant bottles set NAME [--windows VER] [--backend B]
  decant runtime status [--prerelease]
  decant runtime update [--prerelease] [--force]
  decant wine [--bottle NAME] <wine args...>    foreground wine64 in a bottle (diagnostics)
  decant kill [--bottle NAME]                   wineserver -k

  windows versions: winxp64, win7, win8, win81, win10 (default), win11
  backends: dxmt (D3D10/11 on Metal, older DX on wined3d), dxvk, d3dMetal, wined3d, recommended
"""

/// Splits known `--opt value` / `--flag` options from positionals. With
/// `stopAtPositional`, everything from the first positional on is left
/// untouched, so a program's own arguments pass through.
struct Options {
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    var rest: [String] = []

    init(_ args: [String], valued: Set<String>, flags known: Set<String>, stopAtPositional: Bool) throws {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" { rest += args[(i + 1)...]; break }
            if valued.contains(arg) {
                guard i + 1 < args.count else { throw DecantError.message("\(arg) needs a value") }
                values[arg, default: []].append(args[i + 1]); i += 2; continue
            }
            if known.contains(arg) { flags.insert(arg); i += 1; continue }
            if arg.hasPrefix("--") { throw DecantError.message("unknown option \(arg)") }
            if stopAtPositional { rest += args[i...]; break }
            rest.append(arg); i += 1
        }
    }

    func value(_ key: String) -> String? { values[key]?.last }
}

@MainActor
func main(_ argv: [String]) async throws -> Int32 {
    guard let first = argv.first, !["-h", "--help", "help"].contains(first) else {
        print(usageText); return argv.isEmpty ? 64 : 0
    }
    switch first {
    case "runtime":
        let opts = try Options(Array(argv.dropFirst()), valued: [], flags: ["--prerelease", "--force"], stopAtPositional: false)
        switch opts.rest.first {
        case "status": await Runtime.status(prerelease: opts.flags.contains("--prerelease"))
        case "update": try await Runtime.update(prerelease: opts.flags.contains("--prerelease"), force: opts.flags.contains("--force"))
        default: throw DecantError.usage
        }
    case "bottles":
        let opts = try Options(Array(argv.dropFirst()), valued: ["--windows", "--backend"], flags: [], stopAtPositional: false)
        switch (opts.rest.first, opts.rest.count) {
        case ("list", 1): Bottles.printList()
        case ("create", 2):
            let url = try Bottles.create(opts.rest[1], windows: opts.value("--windows"), backend: opts.value("--backend"))
            print("created \(url.path)")
        case ("set", 2):
            let url = try Bottles.open(opts.rest[1], createIfMissing: false)
            if let b = opts.value("--backend") { try Kit.setBackend(b, bottle: url) }
            if let w = opts.value("--windows") { try await Runtime.ensureInstalled(); try await Kit.setWindowsVersion(w, bottle: url) }
            Bottles.printList()
        default: throw DecantError.usage
        }
    case "wine":
        let opts = try Options(Array(argv.dropFirst()), valued: ["--bottle"], flags: [], stopAtPositional: true)
        return try await Launch.wine(opts.rest, bottleName: opts.value("--bottle") ?? Bottles.defaultName)
    case "kill":
        let opts = try Options(Array(argv.dropFirst()), valued: ["--bottle"], flags: [], stopAtPositional: false)
        Kit.killBottle(try Bottles.open(opts.value("--bottle") ?? Bottles.defaultName, createIfMissing: false))
    default:
        let opts = try Options(argv, valued: ["--bottle", "--env"], flags: [], stopAtPositional: true)
        guard let file = opts.rest.first else { throw DecantError.usage }
        var env: [String: String] = [:]
        for kv in opts.values["--env"] ?? [] {
            guard let eq = kv.firstIndex(of: "="), eq != kv.startIndex else { throw DecantError.badValue("--env", kv) }
            env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        }
        try await Launch.run(file: file, args: Array(opts.rest.dropFirst()),
                             bottleName: opts.value("--bottle") ?? Bottles.defaultName, extraEnv: env)
    }
    return 0
}

do {
    exit(try await main(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("decant: \(error)\n".utf8))
    exit(1)
}
