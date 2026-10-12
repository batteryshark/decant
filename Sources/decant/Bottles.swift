// A bottle is a folder with a Metadata.plist under <app support>/Bottles. WhiskyKit's
// BottleData registry is not used: it lives under ~/Library/Containers.
import Foundation

@MainActor
enum Bottles {
    static var root: URL { Kit.appSupport.appending(path: "Bottles") }

    static func url(for name: String) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { throw DecantError("invalid bottle name: \(name)") }
        return root.appending(path: name, directoryHint: .isDirectory)
    }

    static func open(_ name: String, create: Bool) throws -> URL {
        let url = try url(for: name)
        if Kit.isBottle(url) { return url }
        guard create else { throw DecantError("no bottle named '\(name)'") }
        try Kit.createBottle(at: url, name: name)
        return url
    }

    static func list() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in dirs.filter(Kit.isBottle).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            print("\(Kit.describe(url))\t\(url.path)")
        }
    }
}
