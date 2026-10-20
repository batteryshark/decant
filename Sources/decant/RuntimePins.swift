import Foundation

struct RuntimeRelease: Codable, Equatable {
    var tag: String
    var version: String // The artifact's plist version, not its release identity.
    var sha256: String
    var prerelease: Bool
    var gptkCapable: Bool
    var dxmt: String
    var dxvk: String

    var url: URL { URL(string: "https://github.com/frankea/Whisky/releases/download/\(tag)/Libraries.tar.gz")! }
    var metadataURL: URL { URL(string: "https://api.github.com/repos/frankea/Whisky/releases/tags/\(tag)")! }

    func validate() throws {
        guard tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              !dxmt.isEmpty, !dxvk.isEmpty else { throw DecantError("invalid runtime pin") }
    }

    func checkMetadata(_ data: Data) throws {
        struct Asset: Decodable { let name: String; let digest: String?; let browser_download_url: URL; let state: String }
        struct Release: Decodable { let tag_name: String; let prerelease: Bool; let draft: Bool; let assets: [Asset] }
        let metadata = try JSONDecoder().decode(Release.self, from: data)
        let assets = metadata.assets.filter { $0.name == "Libraries.tar.gz" }
        guard metadata.tag_name == tag, metadata.prerelease == prerelease, !metadata.draft,
              assets.count == 1, let asset = assets.first, asset.state == "uploaded",
              asset.digest == "sha256:\(sha256)", asset.browser_download_url == url else {
            throw DecantError("public release metadata does not match reviewed pin \(tag)")
        }
    }
}

struct RuntimePins: Codable {
    var kitCommit: String
    var stable: RuntimeRelease
    var prerelease: RuntimeRelease

    static func load(from explicitURL: URL? = nil) throws -> RuntimePins {
        // Look next to a standalone CLI or at the app bundle root. Avoid the
        // generated accessor's fatalError/development-path fallback if a
        // packaged bundle is missing: no pins means no install.
        let roots = [Bundle.main.executableURL?.deletingLastPathComponent(), Bundle.main.bundleURL].compactMap { $0 }
        let bundled = roots.compactMap { Bundle(url: $0.appending(path: "decant_decant.bundle")) }
            .compactMap { $0.url(forResource: "RuntimePins", withExtension: "json") }.first
        guard let url = explicitURL ?? bundled else {
            throw DecantError("bundled runtime pins missing")
        }
        let pins = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try pins.validate()
        return pins
    }

    func validate() throws {
        try stable.validate(); try prerelease.validate()
        guard kitCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              !stable.prerelease, prerelease.prerelease, stable != prerelease else {
            throw DecantError("invalid paired pins")
        }
    }
}

/// Only written after digest, artifact metadata, install and redeploy succeed.
/// The tag and digest distinguish beta assets with the same plist version.
struct InstalledRuntime: Codable, Equatable {
    var kitCommit: String
    var release: RuntimeRelease

    static func read(at url: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try record.release.validate()
        guard record.kitCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw DecantError("invalid installed kit identity")
        }
        return record
    }

    func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

enum RuntimeDecision: Equatable {
    case install, current, retainPrerelease

    static func update(target: InstalledRuntime, installed: InstalledRuntime?, version: String?, force: Bool) throws -> Self {
        if force { return .install }
        if let installed {
            guard version == installed.release.version else { throw DecantError("installed runtime identity/plist mismatch; use --force to replace") }
            if installed == target { return .current }
            if installed.release.prerelease && !target.release.prerelease { return .retainPrerelease }
            return .install // Different tags/digests, even with identical core versions.
        }
        guard version == nil else { throw DecantError("installed release identity unknown; use --force to replace with a reviewed pin") }
        return .install
    }

    static func launchRelease(pins: RuntimePins, installed: InstalledRuntime?, version: String) throws -> RuntimeRelease {
        if let installed {
            guard installed.kitCommit == pins.kitCommit,
                  [pins.stable, pins.prerelease].contains(installed.release), version == installed.release.version else {
                throw DecantError("installed release is not a reviewed pair for this build; run the paired check/update flow")
            }
            return installed.release
        }
        guard version == pins.stable.version else {
            throw DecantError("untracked runtime; explicitly reinstall a reviewed pin with runtime update --force")
        }
        return pins.stable // Established legacy stable only; no guessed beta identity.
    }
}
