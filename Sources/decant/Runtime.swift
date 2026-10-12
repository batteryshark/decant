// Fetch, verify and install the Whisky runtime (Libraries.tar.gz).
// Stable: frankea's WhiskyWineVersion.plist manifest (version + sha256).
// Pre-release (D3DMetal-capable 4.x): GitHub releases API, sha256 from the asset digest.
import Foundation

struct RuntimeRelease {
    var version: String
    var url: URL
    var sha256: String
    var channel: String
}

@MainActor
enum Runtime {
    static let releasesAPI = URL(string: "https://api.github.com/repos/frankea/Whisky/releases?per_page=30")!

    static func latest(prerelease: Bool) async throws -> RuntimeRelease {
        prerelease ? try await latestPrerelease() : try await latestStable()
    }

    static func latestStable() async throws -> RuntimeRelease {
        let data = try await fetch(Kit.stableManifestURL)
        let info = try Kit.parseManifest(data)
        guard let sha = info.sha256 else { throw DecantError.message("stable manifest has no sha256; refusing to install") }
        return RuntimeRelease(version: info.version, url: Kit.librariesURL(version: info.version), sha256: sha, channel: "stable")
    }

    static func latestPrerelease() async throws -> RuntimeRelease {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Release: Decodable { let tag_name: String; let prerelease: Bool; let assets: [Asset] }
        let releases = try JSONDecoder().decode([Release].self, from: try await fetch(releasesAPI))
        for rel in releases where rel.prerelease && rel.tag_name.hasPrefix("v") {
            guard let asset = rel.assets.first(where: { $0.name == "Libraries.tar.gz" }),
                  let digest = asset.digest, digest.hasPrefix("sha256:") else { continue }
            return RuntimeRelease(version: String(rel.tag_name.dropFirst()), url: asset.browser_download_url,
                                  sha256: String(digest.dropFirst("sha256:".count)), channel: "pre-release")
        }
        throw DecantError.message("no pre-release runtime with a sha256 digest found")
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        installed.compare(candidate, options: .numeric) == .orderedAscending
    }

    static func major(_ version: String) -> Int { Int(version.prefix { $0.isNumber }) ?? 0 }

    static func status(prerelease: Bool) async {
        print("bundle id:   \(Kit.bundleID)")
        print("runtime dir: \(Kit.runtimeDir.path)")
        if let cur = Kit.installedRuntime() {
            print("installed:   \(cur.version) (DXMT \(cur.dxmt ?? "none"), DXVK \(cur.dxvk ?? "none"), " +
                  "D3DMetal \(Kit.d3dMetalInstalled ? "yes" : "no"), DXMT usable \(Kit.dxmtAvailable ? "yes" : "no"))")
        } else {
            print("installed:   none")
        }
        do {
            let latest = try await latest(prerelease: prerelease)
            var line = "latest \(latest.channel): \(latest.version)"
            if let cur = Kit.installedRuntime(), isNewer(latest.version, than: cur.version) { line += "  (update available)" }
            if !prerelease, major(latest.version) > Kit.pinnedRuntimeMajor { line += "  (newer than WhiskyKit pin supports)" }
            print(line)
        } catch {
            print("latest:      unknown (\(error.localizedDescription))")
        }
    }

    /// Installs or upgrades. Without `force`, does nothing when already current.
    static func update(prerelease: Bool, force: Bool) async throws {
        let rel = try await latest(prerelease: prerelease)
        if !prerelease, major(rel.version) > Kit.pinnedRuntimeMajor {
            throw DecantError.message("stable runtime \(rel.version) is newer than this WhiskyKit pin supports " +
                                      "(major \(Kit.pinnedRuntimeMajor)); bump the pin first (see README)")
        }
        if prerelease {
            print("warning: pre-release runtime \(rel.version) is not what WhiskyKit pin was tested with")
        }
        if let cur = Kit.installedRuntime(), !force, !isNewer(rel.version, than: cur.version) {
            print("runtime \(cur.version) is up to date (\(rel.channel) latest: \(rel.version))")
            return
        }
        try await install(rel)
    }

    static func ensureInstalled() async throws {
        if Kit.installedRuntime() == nil {
            print("runtime not installed; installing stable runtime")
            try await update(prerelease: false, force: true)
        }
    }

    static func install(_ rel: RuntimeRelease) async throws {
        let dlDir = Kit.appSupport.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        let tarball = dlDir.appending(path: "Libraries-\(rel.version).tar.gz")
        print("downloading \(rel.url.absoluteString)")
        let (tmp, response) = try await URLSession.shared.download(from: rel.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DecantError.message("download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        try? FileManager.default.removeItem(at: tarball)
        try FileManager.default.moveItem(at: tmp, to: tarball)
        defer { try? FileManager.default.removeItem(at: tarball) }

        let actual = Kit.sha256(of: tarball) ?? "unreadable"
        guard actual.caseInsensitiveCompare(rel.sha256) == .orderedSame else {
            throw DecantError.message("sha256 mismatch: expected \(rel.sha256), got \(actual)")
        }
        print("sha256 ok: \(actual)")
        print("installing into \(Kit.runtimeDir.path)")
        try Kit.installRuntime(tarball: tarball)
        guard let cur = Kit.installedRuntime() else { throw DecantError.message("runtime missing after install") }
        print("installed runtime \(cur.version) (DXMT \(cur.dxmt ?? "none"), DXVK \(cur.dxvk ?? "none"))")
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DecantError.message("GET \(url.absoluteString) failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }
}
