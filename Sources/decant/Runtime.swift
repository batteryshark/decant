// Stable runtimes come from frankea's WhiskyWineVersion.plist; pre-releases from
// the GitHub releases API, with the sha256 from the asset digest.
import Foundation

struct RuntimeRelease {
    var version: String
    var url: URL
    var sha256: String
}

@MainActor
enum Runtime {
    /// Keep the install/redeploy ordering testable without a shared runtime.
    static func installAndRestore(install: () throws -> Void, restore: () throws -> Void) throws {
        try install()
        do { try restore() }
        catch { throw DecantError("runtime installed, but GPTK redeployment failed (payload retained): \(error)") }
    }

    static func latest(prerelease: Bool) async throws -> RuntimeRelease {
        if !prerelease {
            let info = try Kit.parseManifest(try await fetch(Kit.stableManifestURL))
            guard let sha = info.sha256 else { throw DecantError("stable manifest has no sha256") }
            return RuntimeRelease(version: info.version, url: Kit.librariesURL(version: info.version), sha256: sha)
        }
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Release: Decodable { let tag_name: String; let prerelease: Bool; let assets: [Asset] }
        let api = URL(string: "https://api.github.com/repos/frankea/Whisky/releases?per_page=30")!
        for rel in try JSONDecoder().decode([Release].self, from: try await fetch(api)) where rel.prerelease && rel.tag_name.hasPrefix("v") {
            if let asset = rel.assets.first(where: { $0.name == "Libraries.tar.gz" }),
               let digest = asset.digest, digest.hasPrefix("sha256:") {
                return RuntimeRelease(version: String(rel.tag_name.dropFirst()), url: asset.browser_download_url,
                                      sha256: String(digest.dropFirst("sha256:".count)))
            }
        }
        throw DecantError("no pre-release runtime with a sha256 digest found")
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        installed.compare(candidate, options: .numeric) == .orderedAscending
    }

    static func status(prerelease: Bool, check: Bool) async throws {
        let cur = Kit.installedRuntime()
        print("installed: " + (cur.map { "\($0.version) (DXMT \($0.dxmt ?? "none"))" } ?? "none"))
        Kit.localStatus().forEach { print($0) }
        guard check || prerelease else { return }
        let rel = try await latest(prerelease: prerelease)
        let newer = cur.map { isNewer(rel.version, than: $0.version) } ?? true
        print("latest \(prerelease ? "pre-release" : "stable"): \(rel.version)\(newer ? " (update available)" : "")")
    }

    static func update(prerelease: Bool, force: Bool) async throws {
        let rel = try await latest(prerelease: prerelease)
        if !prerelease, Int(rel.version.prefix { $0.isNumber }) ?? 0 > Kit.pinnedRuntimeMajor {
            throw DecantError("runtime \(rel.version) is newer than this WhiskyKit pin supports; bump the pin first (README)")
        }
        if let cur = Kit.installedRuntime(), !force, !isNewer(rel.version, than: cur.version) {
            print("runtime \(cur.version) is up to date")
            return
        }
        print("downloading \(rel.url.absoluteString)")
        let (tarball, response) = try await URLSession.shared.download(from: rel.url)
        defer { try? FileManager.default.removeItem(at: tarball) }
        try checkStatus(response, rel.url)
        let actual = Kit.sha256(of: tarball) ?? "unreadable"
        guard actual.caseInsensitiveCompare(rel.sha256) == .orderedSame else {
            throw DecantError("sha256 mismatch: expected \(rel.sha256), got \(actual)")
        }
        print("sha256 ok: \(actual)")
        try Kit.installRuntime(tarball: tarball)
        guard let cur = Kit.installedRuntime() else { throw DecantError("runtime missing after install") }
        print("installed runtime \(cur.version) (DXMT \(cur.dxmt ?? "none"))")
    }

    static func ensureInstalled() async throws {
        if Kit.installedRuntime() == nil { try await update(prerelease: false, force: true) }
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
