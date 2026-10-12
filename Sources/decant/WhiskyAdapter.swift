// The only file that imports WhiskyKit. When bumping the WhiskyKit pin, fix
// compile errors here and nowhere else. Bottles are addressed by folder URL so
// no WhiskyKit type leaks out.
import Foundation
import WhiskyKit

@MainActor
enum Kit {
    /// Runtime major version this WhiskyKit pin was tested against. The stable
    /// channel refuses newer majors until the pin is bumped (README).
    static let pinnedRuntimeMajor = 3

    static var bundleID: String { Bundle.whiskyBundleIdentifier }
    /// ~/Library/Application Support/<bundle id>
    static var appSupport: URL { WhiskyWineInstaller.applicationFolder }
    static var runtimeDir: URL { WhiskyWineInstaller.libraryFolder }
    static var wineBinary: URL { Wine.wineBinary }
    static var stableManifestURL: URL { URL(string: DistributionConfig.versionPlistURL)! }

    static func librariesURL(version: String) -> URL {
        URL(string: DistributionConfig.librariesURL(version: version))!
    }

    // MARK: Runtime

    struct RuntimeInfo {
        var version: String
        var dxmt: String?
        var dxvk: String?
        var sha256: String?
    }

    private static func info(_ wwv: WhiskyWineVersion) -> RuntimeInfo {
        RuntimeInfo(version: "\(wwv.version)", dxmt: wwv.dxmtVersion, dxvk: wwv.dxvkVersion, sha256: wwv.sha256)
    }

    static func installedRuntime() -> RuntimeInfo? {
        guard WhiskyWineInstaller.isWhiskyWineInstalled(), let wwv = WhiskyWineInstaller.whiskyWineInfo() else {
            return nil
        }
        return info(wwv)
    }

    static func parseManifest(_ data: Data) throws -> RuntimeInfo {
        info(try PropertyListDecoder().decode(WhiskyWineVersion.self, from: data))
    }

    static func sha256(of file: URL) -> String? { WhiskyWineInstaller.sha256(ofFileAt: file) }

    static func installRuntime(tarball: URL) throws { try WhiskyWineInstaller.install(from: tarball) }

    static var dxmtAvailable: Bool { WhiskyWineInstaller.isBackendAvailable(.dxmt) }
    static var d3dMetalInstalled: Bool { WhiskyWineInstaller.isD3DMetalInstalled() }

    // MARK: Bottles

    static let windowsVersions = WinVersion.allCases.map(\.rawValue)
    static let backends = GraphicsBackend.allCases.map(\.rawValue)

    struct BottleInfo {
        var name: String
        var url: URL
        var windowsVersion: String
        var backend: String
        var prefixCreated: Bool
    }

    static func isBottle(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "Metadata.plist").path(percentEncoded: false))
    }

    static func bottleInfo(_ url: URL) -> BottleInfo {
        let bottle = Bottle(bottleUrl: url, isAvailable: true)
        let sys32 = url.appending(path: "drive_c/windows/system32").path(percentEncoded: false)
        return BottleInfo(
            name: bottle.settings.name, url: url,
            windowsVersion: bottle.settings.windowsVersion.rawValue,
            backend: bottle.settings.graphicsBackend.rawValue,
            prefixCreated: FileManager.default.fileExists(atPath: sys32)
        )
    }

    /// Writes Metadata.plist only; the Wine prefix is created on first launch.
    static func createBottle(at url: URL, name: String, windowsVersion: String, backend: String) throws {
        guard let win = WinVersion(rawValue: windowsVersion) else { throw DecantError.badValue("windows version", windowsVersion) }
        guard let gfx = GraphicsBackend(rawValue: backend) else { throw DecantError.badValue("backend", backend) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bottle = Bottle(bottleUrl: url, inFlight: true)
        bottle.settings.name = name
        bottle.settings.windowsVersion = win
        bottle.settings.graphicsBackend = gfx
    }

    static func setBackend(_ backend: String, bottle url: URL) throws {
        guard let gfx = GraphicsBackend(rawValue: backend) else { throw DecantError.badValue("backend", backend) }
        Bottle(bottleUrl: url, isAvailable: true).settings.graphicsBackend = gfx
    }

    /// Records the version and, if the prefix exists already, applies it with winecfg.
    static func setWindowsVersion(_ version: String, bottle url: URL) async throws {
        guard let win = WinVersion(rawValue: version) else { throw DecantError.badValue("windows version", version) }
        let bottle = Bottle(bottleUrl: url, isAvailable: true)
        bottle.settings.windowsVersion = win
        if bottleInfo(url).prefixCreated {
            try await Wine.runWine(["winecfg", "-v", win.rawValue], bottle: bottle)
        }
    }

    // MARK: Launch

    /// Bootstraps the prefix if needed, deploys the backend DLLs (DXMT into
    /// system32 and syswow64), writes DLL overrides, and returns the shell
    /// command that starts the program. WhiskyKit's own launch() waits for the
    /// program to exit; we run this command detached instead.
    /// `extraEnv` (e.g. WINEDEBUG) applies to this launch only: it is injected
    /// as `env K=V` right before wine64, so it beats WhiskyKit's own values.
    static func prepareLaunch(
        exe: URL, args: [String], bottle url: URL, extraEnv: [String: String] = [:]
    ) async throws -> String {
        let bottle = Bottle(bottleUrl: url, isAvailable: true)
        let command = try await Program(url: exe, bottle: bottle).prepareTerminalCommand(args: args)
        guard !extraEnv.isEmpty else { return command }
        let wine = Wine.wineBinary.path(percentEncoded: false).esc
        guard let range = command.range(of: wine) else { throw DecantError.message("cannot inject env into: \(command)") }
        let assignments = extraEnv.map { "\($0.key)=\($0.value.esc)" }.sorted().joined(separator: " ")
        return command.replacingCharacters(in: range, with: "/usr/bin/env \(assignments) \(wine)")
    }

    /// The environment WhiskyKit gives Wine for this bottle (WINEPREFIX, overrides, fixes).
    static func wineEnvironment(bottle url: URL) -> [String: String] {
        Wine.constructWineEnvironment(for: Bottle(bottleUrl: url, isAvailable: true))
    }

    static func killBottle(_ url: URL) {
        Wine.killBottleAndWait(bottle: Bottle(bottleUrl: url, isAvailable: true))
    }
}
