// The only file that imports WhiskyKit; a pin bump should only break this file.
import Foundation
import WhiskyKit

@MainActor
enum Kit {
    static var bundleID: String { Bundle.whiskyBundleIdentifier }
    static var appSupport: URL { WhiskyWineInstaller.applicationFolder }
    static var runtimeIdentityURL: URL { WhiskyWineInstaller.libraryFolder.appending(path: "DecantRuntime.json") }

    static var paths: [String: String] {
        ["bundleID": bundleID, "support": appSupport.path,
         "bottles": appSupport.appending(path: "Bottles").path,
         "logs": FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/\(bundleID)").path]
    }

    struct RuntimeInfo {
        var version: String
        var dxmt: String?
        var sha256: String?
        var dxvk: String?
        var gptkCapable: Bool
    }

    private static func info(_ v: WhiskyWineVersion) -> RuntimeInfo {
        RuntimeInfo(version: "\(v.version)", dxmt: v.dxmtVersion, sha256: v.sha256, dxvk: v.dxvkVersion, gptkCapable: v.gptkCapable == true)
    }

    static func installedRuntime() -> RuntimeInfo? {
        guard WhiskyWineInstaller.isWhiskyWineInstalled(), let v = WhiskyWineInstaller.whiskyWineInfo() else { return nil }
        return info(v)
    }

    static func parseManifest(_ data: Data) throws -> RuntimeInfo {
        info(try PropertyListDecoder().decode(WhiskyWineVersion.self, from: data))
    }

    static func validateRuntimeInfo(_ info: RuntimeInfo, release: RuntimeRelease) throws {
        guard info.version == release.version, info.dxmt == release.dxmt, info.dxvk == release.dxvk,
              info.gptkCapable == release.gptkCapable else { throw DecantError("runtime plist incompatible with reviewed \(release.tag)") }
    }

    static func validateRuntimeArchive(_ archive: URL, release: RuntimeRelease) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["-xOf", archive.path, "Libraries/WhiskyWineVersion.plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DecantError("runtime archive has no readable version plist") }
        try validateRuntimeInfo(parseManifest(data), release: release)
    }

    static func sha256(of file: URL) -> String? { WhiskyWineInstaller.sha256(ofFileAt: file) }

    static func installRuntime(tarball: URL) throws {
        // The store is outside Libraries; the deployed copy was just wiped.
        try Runtime.installAndRestore(install: {
            try WhiskyWineInstaller.install(from: tarball)
            try stageCompatibilityShim()
        }, restore: redeployGPTK)
    }

    @discardableResult
    static func stageCompatibilityShim() throws -> Bool {
        // Referencing the public immutable policy makes an unpatched kit a compile error.
        guard GPTKImporter.interposerPayloadVersions == ["4.0b2", "4.0b3"] else {
            throw DecantError("kit compatibility policy mismatch")
        }
        let pins = try RuntimePins.load()
        let roots = [Bundle.main.executableURL?.deletingLastPathComponent(), Bundle.main.bundleURL].compactMap { $0 }
        let source = roots.compactMap { Bundle(url: $0.appending(path: "decant_decant.bundle")) }
            .compactMap { $0.url(forResource: pins.shim.file, withExtension: nil) }.first
        guard let source, sha256(of: source) == pins.shim.sha256,
              try Data(contentsOf: source).count == pins.shim.size else {
            throw DecantError("checked compatibility resource missing or damaged")
        }
        let destination = WhiskyWineInstaller.libraryFolder.appending(path: "Wine/lib/gptk-video").appending(path: pins.shim.file)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard sha256(of: destination) == pins.shim.sha256 else { throw DecantError("runtime compatibility overlay identity mismatch") }
            return false
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        return true
    }

    static func redeployGPTK() throws {
        guard GPTKImporter.isRuntimeGPTKCapable() else { return }
        try stageCompatibilityShim()
        // A damaged store must fail rather than be mistaken for no import.
        guard FileManager.default.fileExists(atPath: GPTKImporter.storeFolder.path) else { return }
        try GPTKImporter.deployStoredPayload()
        guard GPTKImporter.isDeployed() else { throw DecantError("GPTK deployment incomplete") }
    }

    static func importGPTK(_ source: URL) throws {
        try GPTKDiskImage.withPayload(at: source, locate: GPTKImporter.locatePayload(under:)) { root in
            try GPTKPayloadLayout.validate(root)
            let payload = try GPTKImporter.validatePayload(at: root)
            let record = try GPTKImporter.importPayload(payload)
            print("imported local Apple GPTK \(record.gptkVersion)")
            try redeployGPTK()
            print(GPTKImporter.isRuntimeGPTKCapable() ? "GPTK deployed" : "payload retained; installed runtime is not GPTK-capable")
        }
    }

    /// Read-only validation seam for opt-in tests against an original Apple DMG.
    static func validateGPTK(_ source: URL) throws -> String {
        try GPTKDiskImage.withPayload(at: source, locate: GPTKImporter.locatePayload(under:)) {
            try GPTKPayloadLayout.validate($0)
            return try GPTKImporter.validatePayload(at: $0).version
        }
    }

    static func localStatus() -> [String] {
        let record = GPTKImporter.storedRecord()
        let storeExists = FileManager.default.fileExists(atPath: GPTKImporter.storeFolder.path)
        return [
            "GPTK stored: " + (record?.gptkVersion ?? (storeExists ? "incomplete/unreadable" : "none")),
            "runtime GPTK-capable: \(GPTKImporter.isRuntimeGPTKCapable())",
            "GPTK deployed: \(GPTKImporter.isDeployed())",
            "available backends: " + GraphicsBackend.allCases.filter { backendAvailable($0) }.map(\.rawValue).joined(separator: ", ")
        ]
    }

    private static func backendAvailable(_ backend: GraphicsBackend) -> Bool {
        guard installedRuntime() != nil else { return false }
        if backend == .d3dMetal {
            let lib = WhiskyWineInstaller.libraryFolder.appending(path: "Wine/lib")
            let required = ["external/D3DMetal.framework", "external/libd3dshared.dylib", "wine/x86_64-unix/dxgi.so"]
                + ["d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"].map { "wine/x86_64-windows/\($0)" }
            return GPTKImporter.isRuntimeGPTKCapable() && required.allSatisfy {
                FileManager.default.fileExists(atPath: lib.appending(path: $0).path)
            }
        }
        return WhiskyWineInstaller.isBackendAvailable(backend)
    }

    static func validateBackend(_ backend: String) throws {
        guard let gfx = GraphicsBackend(rawValue: backend) else { throw DecantError("invalid backend: \(backend)") }
        guard backendAvailable(gfx) else {
            throw DecantError("backend \(backend) unavailable; check 'decant runtime status' (D3DMetal needs a GPTK-capable runtime and local import)")
        }
    }

    static func isBottle(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "Metadata.plist").path(percentEncoded: false))
    }

    static func isPrefixCreated(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "drive_c/windows/system32").path(percentEncoded: false))
    }

    static func describe(_ url: URL) -> String {
        let s = Bottle(bottleUrl: url, isAvailable: true).settings
        let requested = s.graphicsBackend
        let effective = requested == .recommended ? GraphicsBackendResolver.resolve() : requested
        return "\(s.name)\twindows=\(s.windowsVersion.rawValue)\trequested=\(requested.rawValue)\teffective=\(backendAvailable(effective) ? effective.rawValue : "unavailable")"
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
        try validateBackend(backend)
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
        let program = Program(url: exe, bottle: bottle)
        let requested = program.settings.overrides?.graphicsBackend ?? bottle.settings.graphicsBackend
        let effective = requested == .recommended ? GraphicsBackendResolver.resolve(for: LauncherType.detect(from: exe)) : requested
        try validateBackend(effective.rawValue)
        try BackendSafety.checkLegacyDXVK(backend: effective.rawValue,
            explicitProgramBackend: program.settings.overrides?.graphicsBackend != nil,
            legacyDXVK: program.settings.overrides?.dxvk)
        let usesDXVK = effective == .dxvk || (program.settings.overrides?.graphicsBackend == nil && program.settings.overrides?.dxvk == true)
            || (bottle.settings.autoEnableDXVK && bottle.settings.detectedLauncher?.requiresDXVK == true)
        guard !usesDXVK || effective == .dxvk else {
            throw DecantError("backend \(effective.rawValue) conflicts with a saved launcher/program DXVK override; use a separate bottle")
        }
        if effective == .dxmt { try protectDLLs(in: url, backend: "DXMT") }
        if usesDXVK { try protectDLLs(in: url, backend: "DXVK") }
        // Bottle-level D3DMetal/wined3d presets do not override leftover native
        // DXMT/DXVK files. Restore only byte-identical managed copies, never a
        // user's custom native DLL. DXMT also needs DXVK's d3d9 neutralized.
        if !usesDXVK {
            let names = effective == .dxmt ? ["d3d9.dll"] : ["d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]
            for (directory, arch, wineArch) in [("system32", "x64", "x86_64-windows"), ("syswow64", "x32", "i386-windows")] {
                for name in names {
                    let libraries = WhiskyWineInstaller.libraryFolder
                    try BackendSafety.restoreBuiltin(url.appending(path: "drive_c/windows/\(directory)/\(name)"),
                        from: libraries.appending(path: "Wine/lib/wine/\(wineArch)/\(name)"),
                        knownCopies: ["DXMT", "DXVK"].map { libraries.appending(path: "\($0)/\(arch)/\(name)") },
                        strippedBuiltin: name == "dxgi.dll" ? GPTKImporter.storeFolder.appending(path: "originals/dxgi.dll") : nil)
                }
            }
        }
        if effective == .d3dMetal {
            // Public upstream maintenance hook; placeholder copies below are
            // missing-only, matching upstream's policy for older prefixes.
            GPTKImporter.ensureVideoProcessorInstalled(bottles: [url])
            try BackendSafety.seedPlaceholders(
                system32: url.appending(path: "drive_c/windows/system32"),
                runtimePE: WhiskyWineInstaller.libraryFolder.appending(path: "Wine/lib/wine/x86_64-windows"))
        }
        let command = try await program.prepareTerminalCommand(args: args)
        guard !extraEnv.isEmpty else { return command }
        let wine = Wine.wineBinary.path(percentEncoded: false).esc
        guard let range = command.range(of: wine) else { throw DecantError("cannot inject env into: \(command)") }
        let assignments = extraEnv.map { "\($0.key)=\($0.value.esc)" }.joined(separator: " ")
        return command.replacingCharacters(in: range, with: "/usr/bin/env \(assignments) \(wine)")
    }

    private static func protectDLLs(in prefix: URL, backend: String) throws {
        let libraries = WhiskyWineInstaller.libraryFolder
        for (directory, arch) in [("system32", "x64"), ("syswow64", "x32")] {
            let payload = libraries.appending(path: "\(backend)/\(arch)")
            let files: [URL]
            if backend == "DXMT" {
                files = ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"].map { payload.appending(path: $0) }
            } else {
                let enumerator = FileManager.default.enumerator(at: payload, includingPropertiesForKeys: nil)
                files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "dll" }
            }
            let names = Set(files.map(\.lastPathComponent) + (backend == "DXVK" ? ["dxgi.dll"] : []))
            for name in names {
                let known = ["DXMT", "DXVK"].map { libraries.appending(path: "\($0)/\(arch)/\(name)") }
                    + files.filter { $0.lastPathComponent == name }
                try BackendSafety.checkReplacement(prefix.appending(path: "drive_c/windows/\(directory)/\(name)"), knownCopies: known,
                    strippedBuiltin: name == "dxgi.dll" ? GPTKImporter.storeFolder.appending(path: "originals/dxgi.dll") : nil)
            }
        }
    }
}
