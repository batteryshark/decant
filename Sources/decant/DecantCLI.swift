import Foundation

struct DecantError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let usage = """
usage:
  decant [--bottle NAME] [--env KEY=VALUE]... <file.exe|file.msi> [args...]
  decant bottles list
  decant bottles create NAME [--windows VER] [--backend B]
  decant bottles set NAME [--windows VER] [--backend B]
  decant runtime status [--check] [--prerelease]
  decant runtime update [--prerelease] [--force]
  decant runtime import-gptk <dmg-or-dir>

  VER: winxp64 win7 win8 win81 win10 win11    B: dxmt dxvk d3dMetal wined3d recommended
"""

/// Splits `--opt value` pairs and `--flag`s from positionals. Parsing stops at the
/// first positional when `stopAtPositional`, so a program's own arguments pass through.
func parse(_ args: [String], valued: Set<String>, flags: Set<String> = [], stopAtPositional: Bool = false)
    throws -> (values: [String: [String]], flags: Set<String>, rest: [String]) {
    var values: [String: [String]] = [:], seen: Set<String> = [], rest: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        if valued.contains(arg), i + 1 < args.count {
            values[arg, default: []].append(args[i + 1]); i += 2
        } else if flags.contains(arg) {
            seen.insert(arg); i += 1
        } else if arg.hasPrefix("--") {
            throw DecantError("bad option \(arg)\n\(usage)")
        } else if stopAtPositional {
            rest += args[i...]; break
        } else {
            rest.append(arg); i += 1
        }
    }
    return (values, seen, rest)
}

@MainActor
func runCLI(_ argv: [String]) async throws {
    switch argv.first {
    case nil, "-h", "--help":
        print(usage)
    case "runtime":
        if argv.dropFirst().first == "import-gptk" {
            guard argv.count == 3, !argv[2].hasPrefix("--") else { throw DecantError(usage) }
            try Kit.importGPTK(URL(filePath: argv[2]).standardizedFileURL)
            return
        }
        let o = try parse(Array(argv.dropFirst()), valued: [], flags: ["--prerelease", "--force", "--check"])
        let pre = o.flags.contains("--prerelease")
        switch o.rest {
        case ["status"] where !o.flags.contains("--force"):
            try await Runtime.status(prerelease: pre, check: o.flags.contains("--check"))
        case ["update"] where !o.flags.contains("--check"):
            try await Runtime.update(prerelease: pre, force: o.flags.contains("--force"))
        default: throw DecantError(usage)
        }
    case "bottles":
        let o = try parse(Array(argv.dropFirst()), valued: ["--windows", "--backend"])
        guard o.rest == ["list"] || (o.rest.count == 2 && ["create", "set"].contains(o.rest[0])) else { throw DecantError(usage) }
        if o.rest[0] != "list" {
            if let b = o.values["--backend"]?.last { try Kit.validateBackend(b) }
            let url = try Bottles.open(o.rest[1], create: o.rest[0] == "create")
            if let b = o.values["--backend"]?.last { try Kit.setBackend(b, bottle: url) }
            if let w = o.values["--windows"]?.last { try await Kit.setWindowsVersion(w, bottle: url) }
        }
        Bottles.list()
    default:
        let o = try parse(argv, valued: ["--bottle", "--env"], stopAtPositional: true)
        guard let file = o.rest.first else { throw DecantError(usage) }
        var env: [String: String] = [:]
        for kv in o.values["--env"] ?? [] {
            let parts = kv.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { throw DecantError("bad --env \(kv)") }
            env[String(parts[0])] = String(parts[1])
        }
        try await Launch.run(file: file, args: Array(o.rest.dropFirst()),
                             bottleName: o.values["--bottle"]?.last ?? "Default", extraEnv: env)
    }
}

@main
struct DecantCLI {
    static func main() async {
        do {
            try await runCLI(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("decant: \(error)\n".utf8))
            exit(1)
        }
    }
}
