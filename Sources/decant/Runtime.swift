// Only reviewed exact pairs are installable. No floating release discovery.
import Foundation

@MainActor
enum Runtime {
    /// Keep the install/redeploy ordering testable without a shared runtime.
    static func installAndRestore(install: () throws -> Void, restore: () throws -> Void) throws {
        try install()
        do { try restore() }
        catch { throw DecantError("runtime installed, but GPTK redeployment failed (payload retained): \(error)") }
    }

    static func status(prerelease: Bool, check: Bool) async throws {
        let pins = try RuntimePins.load()
        let cur = Kit.installedRuntime()
        print("installed: " + (cur.map { "\($0.version) (DXMT \($0.dxmt ?? "none"))" } ?? "none"))
        do {
            let record = try InstalledRuntime.read(at: Kit.runtimeIdentityURL)
            print("checked release: " + (record.map { "\($0.release.tag) sha256=\($0.release.sha256) kit=\($0.kitCommit)\(cur?.version == $0.release.version ? "" : " (plist mismatch)")" } ?? "unknown (legacy/untracked)"))
        } catch { print("checked release: unreadable (\(error))") }
        print("reviewed stable: \(pins.stable.tag); prerelease: \(pins.prerelease.tag); kit: \(pins.kitCommit)")
        print("reviewed compatibility: kit-patch=\(pins.kitPatch.sha256) shim=\(pins.shim.sha256)")
        Kit.localStatus().forEach { print($0) }
        guard check else { return }
        let rel = prerelease ? pins.prerelease : pins.stable
        try rel.checkMetadata(try await fetch(rel.metadataURL))
        print("public metadata matches reviewed \(rel.tag)")
    }

    static func update(prerelease: Bool, force: Bool) async throws {
        let pins = try RuntimePins.load()
        let rel = prerelease ? pins.prerelease : pins.stable
        let target = InstalledRuntime(kitCommit: pins.kitCommit, release: rel,
            kitPatchSHA256: pins.kitPatch.sha256, shimSHA256: pins.shim.sha256)
        let installed = force ? nil : try InstalledRuntime.read(at: Kit.runtimeIdentityURL)
        let cur = Kit.installedRuntime()
        if let installed, let cur { try Kit.validateRuntimeInfo(cur, release: installed.release) }
        if let installed, cur?.version == installed.release.version,
           installed.release == rel || (installed.release.prerelease && !rel.prerelease) {
            try reconcile(installed, pins: pins)
            print(installed.release == rel ? "reviewed runtime \(rel.tag) is already installed; compatibility checked" : "retaining checked prerelease; compatibility checked")
            return
        }
        switch try RuntimeDecision.update(target: target, installed: installed, version: cur?.version, force: force) {
        case .current: print("reviewed runtime \(rel.tag) is already installed"); return
        case .retainPrerelease: print("retaining checked prerelease; use --force for an explicit stable replacement"); return
        case .install: break
        }
        try rel.checkMetadata(try await fetch(rel.metadataURL))
        print("downloading \(rel.url.absoluteString)")
        let (tarball, response) = try await URLSession.shared.download(from: rel.url)
        defer { try? FileManager.default.removeItem(at: tarball) }
        try checkStatus(response, rel.url)
        let actual = Kit.sha256(of: tarball) ?? "unreadable"
        guard actual.caseInsensitiveCompare(rel.sha256) == .orderedSame else {
            throw DecantError("sha256 mismatch: expected \(rel.sha256), got \(actual)")
        }
        print("sha256 ok: \(actual)")
        // Read the archive's plist before touching the shared runtime.
        try Kit.validateRuntimeArchive(tarball, release: rel)
        try Kit.installRuntime(tarball: tarball)
        guard let cur = Kit.installedRuntime() else { throw DecantError("runtime missing after install") }
        try Kit.validateRuntimeInfo(cur, release: rel)
        try target.write(to: Kit.runtimeIdentityURL)
        print("installed checked runtime \(rel.tag) (plist \(cur.version), DXMT \(cur.dxmt ?? "none"))")
    }

    static func ensureInstalled() async throws {
        let pins = try RuntimePins.load()
        guard let cur = Kit.installedRuntime() else {
            try await update(prerelease: false, force: false)
            return
        }
        let release = try RuntimeDecision.launchRelease(pins: pins,
            installed: InstalledRuntime.read(at: Kit.runtimeIdentityURL), version: cur.version)
        try Kit.validateRuntimeInfo(cur, release: release)
        try reconcile(try InstalledRuntime.read(at: Kit.runtimeIdentityURL)
            ?? InstalledRuntime(kitCommit: pins.kitCommit, release: release), pins: pins)
    }

    private static func reconcile(_ installed: InstalledRuntime, pins: RuntimePins) throws {
        try reconcile(installed, pins: pins, identityURL: Kit.runtimeIdentityURL,
            stage: Kit.stageCompatibilityShim, redeploy: { try Kit.redeployGPTK() })
    }

    /// The production reconciliation path, with filesystem/effect seams for owned fixtures.
    static func reconcile(_ installed: InstalledRuntime, pins: RuntimePins, identityURL: URL,
                          stage: () throws -> Bool, redeploy: () throws -> Void) throws {
        guard [pins.stable, pins.prerelease].contains(installed.release) else {
            throw DecantError("installed runtime is not a reviewed pair")
        }
        // Keep exact release provenance while marking compatibility incomplete BEFORE
        // any staging/deploy effects. A throw or interruption must remain retryable.
        var pending = installed
        pending.kitPatchSHA256 = nil
        pending.shimSHA256 = nil
        try pending.write(to: identityURL)
        let changed = try stage()
        if changed || installed.kitCommit != pins.kitCommit || installed.kitPatchSHA256 != pins.kitPatch.sha256
                || installed.shimSHA256 != pins.shim.sha256 {
            try redeploy()
        }
        var checked = installed
        checked.kitCommit = pins.kitCommit
        checked.kitPatchSHA256 = pins.kitPatch.sha256
        checked.shimSHA256 = pins.shim.sha256
        try checked.write(to: identityURL)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkStatus(response, url)
        return data
    }

    private static func checkStatus(_ response: URLResponse, _ url: URL) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw DecantError("GET \(url.absoluteString): HTTP \(code)") }
    }
}
