// The only file that imports WhiskyKit; a pin bump should only break this file.
import Foundation
import WhiskyKit

@MainActor
enum Kit {
    /// Runtime major version this WhiskyKit pin works with.
    static let pinnedRuntimeMajor = 3

    static var bundleID: String { Bundle.whiskyBundleIdentifier }
    static var appSupport: URL { WhiskyWineInstaller.applicationFolder }
    static var stableManifestURL: URL { URL(string: DistributionConfig.versionPlistURL)! }

    static func librariesURL(version: String) -> URL {
        URL(string: DistributionConfig.librariesURL(version: version))!
    }

    struct RuntimeInfo {
        var version: String
        var dxmt: String?
        var sha256: String?
    }

    private static func info(_ v: WhiskyWineVersion) -> RuntimeInfo {
        RuntimeInfo(version: "\(v.version)", dxmt: v.dxmtVersion, sha256: v.sha256)
    }

    static func installedRuntime() -> RuntimeInfo? {
        guard WhiskyWineInstaller.isWhiskyWineInstalled(), let v = WhiskyWineInstaller.whiskyWineInfo() else { return nil }
        return info(v)
    }

    static func parseManifest(_ data: Data) throws -> RuntimeInfo {
        info(try PropertyListDecoder().decode(WhiskyWineVersion.self, from: data))
    }

    static func sha256(of file: URL) -> String? { WhiskyWineInstaller.sha256(ofFileAt: file) }

    static func installRuntime(tarball: URL) throws { try WhiskyWineInstaller.install(from: tarball) }

    static func isBottle(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "Metadata.plist").path(percentEncoded: false))
    }

    static func isPrefixCreated(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "drive_c/windows/system32").path(percentEncoded: false))
    }

    static func describe(_ url: URL) -> String {
        let s = Bottle(bottleUrl: url, isAvailable: true).settings
        return "\(s.name)\twindows=\(s.windowsVersion.rawValue)\tbackend=\(s.graphicsBackend.rawValue)"
    }

    /// Writes Metadata.plist only; the Wine prefix is created on first launch.
    static func createBottle(at url: URL, name: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bottle = Bottle(bottleUrl: url, inFlight: true)
        bottle.settings.name = name
        bottle.settings.windowsVersion = .win10
        bottle.settings.graphicsBackend = .dxmt
    }

    static func setBackend(_ backend: String, bottle url: URL) throws {
        guard let gfx = GraphicsBackend(rawValue: backend) else { throw DecantError("invalid backend: \(backend)") }
        Bottle(bottleUrl: url, isAvailable: true).settings.graphicsBackend = gfx
    }

    /// Records the version; if the prefix exists already, applies it with winecfg.
    static func setWindowsVersion(_ version: String, bottle url: URL) async throws {
        guard let win = WinVersion(rawValue: version) else { throw DecantError("invalid windows version: \(version)") }
        let bottle = Bottle(bottleUrl: url, isAvailable: true)
        bottle.settings.windowsVersion = win
        if isPrefixCreated(url) {
            try await Wine.runWine(["winecfg", "-v", win.rawValue], bottle: bottle)
        }
    }

    /// Creates the prefix if needed, deploys the backend DLLs (DXMT into system32
    /// and syswow64) and DLL overrides, and returns the shell command that starts
    /// the program. `extraEnv` is injected as `env K=V` right before wine64 so it
    /// beats WhiskyKit's own values (e.g. WINEDEBUG).
    static func prepareLaunch(exe: URL, args: [String], bottle url: URL, extraEnv: [String: String]) async throws -> String {
        let bottle = Bottle(bottleUrl: url, isAvailable: true)
        let command = try await Program(url: exe, bottle: bottle).prepareTerminalCommand(args: args)
        guard !extraEnv.isEmpty else { return command }
        let wine = Wine.wineBinary.path(percentEncoded: false).esc
        guard let range = command.range(of: wine) else { throw DecantError("cannot inject env into: \(command)") }
        let assignments = extraEnv.map { "\($0.key)=\($0.value.esc)" }.joined(separator: " ")
        return command.replacingCharacters(in: range, with: "/usr/bin/env \(assignments) \(wine)")
    }
}
