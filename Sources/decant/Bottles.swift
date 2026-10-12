// Bottles live in ~/Library/Application Support/<bundle id>/Bottles/<name>.
// We don't use WhiskyKit's BottleData registry (it lives under ~/Library/Containers);
// a folder with a Metadata.plist is a bottle.
import Foundation

@MainActor
enum Bottles {
    static let defaultName = "Default"
    static let defaultWindows = "win10"

    static var root: URL { Kit.appSupport.appending(path: "Bottles") }

    static func url(for name: String) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { throw DecantError.badValue("bottle name", name) }
        return root.appending(path: name, directoryHint: .isDirectory)
    }

    static func all() -> [Kit.BottleInfo] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter(Kit.isBottle).sorted { $0.lastPathComponent < $1.lastPathComponent }.map(Kit.bottleInfo)
    }

    /// DXMT for D3D10/11 (D3D9 and older stay on Wine's builtin wined3d), when the runtime ships it.
    static var defaultBackend: String { Kit.dxmtAvailable ? "dxmt" : "recommended" }

    static func create(_ name: String, windows: String? = nil, backend: String? = nil) throws -> URL {
        let url = try url(for: name)
        guard !Kit.isBottle(url) else { throw DecantError.message("bottle '\(name)' already exists") }
        try Kit.createBottle(at: url, name: name, windowsVersion: windows ?? defaultWindows, backend: backend ?? defaultBackend)
        return url
    }

    static func open(_ name: String, createIfMissing: Bool) throws -> URL {
        let url = try url(for: name)
        if Kit.isBottle(url) { return url }
        guard createIfMissing else { throw DecantError.message("no bottle named '\(name)'") }
        print("creating bottle '\(name)'")
        return try create(name)
    }

    static func printList() {
        let bottles = all()
        if bottles.isEmpty { print("no bottles in \(root.path)"); return }
        for b in bottles {
            print("\(b.name)\twindows=\(b.windowsVersion)\tbackend=\(b.backend)\tprefix=\(b.prefixCreated ? "yes" : "not yet")\t\(b.url.path)")
        }
    }
}
