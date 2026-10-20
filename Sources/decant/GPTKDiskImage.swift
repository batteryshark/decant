import Foundation
import Darwin

/// Bounded equivalent of upstream's app-only GPTKDiskImage. No recursive search.
enum GPTKDiskImage {
    typealias Runner = ([String]) throws -> (Int32, Data)

    static func run(_ arguments: [String]) throws -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/hdiutil")
        p.arguments = arguments
        let output = Pipe()
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Only detach unique mount points we requested, never mount points returned
    /// for an image the user had already mounted. Cleanup also runs on failure.
    static func withPayload<T>(at source: URL, locate: (URL) -> URL?,
                               runner: Runner = run, body: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        // Compare canonical paths below: hdiutil can report /private/var for /var.
        let scratch = fm.temporaryDirectory.resolvingSymlinksInPath().appending(path: "decant-gptk-\(UUID().uuidString)")
        var owned: [URL] = []
        defer {
            for mount in owned.reversed() {
                do {
                    let (status, _) = try runner(["detach", mount.path])
                    if status != 0 { warn("could not detach \(mount.path); detach it manually") }
                } catch { warn("could not detach \(mount.path): \(error)") }
            }
            // Do not recursively remove a mount that failed to detach.
            for mount in owned { _ = rmdir(mount.path) }
            _ = rmdir(scratch.path)
        }
        func attach(_ image: URL) throws -> URL {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let mount = scratch.appending(path: "mount-\(owned.count)")
            try fm.createDirectory(at: mount, withIntermediateDirectories: false)
            owned.append(mount)
            let (status, data) = try runner([
                "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist",
                "-mountpoint", mount.path, image.path
            ])
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let entities = plist?["system-entities"] as? [[String: Any]] ?? []
            guard status == 0, entities.contains(where: {
                guard let path = $0["mount-point"] as? String else { return false }
                return URL(filePath: path).resolvingSymlinksInPath().path == mount.resolvingSymlinksInPath().path
            }) else {
                throw DecantError("cannot mount GPTK image at private mount point: \(image.lastPathComponent) (exit \(status), requested \(mount.path), returned \(entities.compactMap { $0["mount-point"] as? String }))")
            }
            return mount
        }
        let root = source.pathExtension.lowercased() == "dmg" ? try attach(source) : source
        if let lib = locate(root) { return try body(lib) }
        // Apple's outer toolkit carries a top-level evaluation-environment DMG.
        // Exactly one candidate, no nested recursion, no symlinks escaping it.
        let candidates = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return name.hasSuffix(".dmg") && name.contains("evaluation") && name.contains("environment")
                    && values?.isRegularFile == true && values?.isSymbolicLink != true
            }
        guard candidates.count == 1, let lib = locate(try attach(candidates[0])) else {
            throw DecantError("GPTK payload not found; select the evaluation-environment DMG or its redist/lib directory")
        }
        return try body(lib)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("decant: \(message)\n".utf8))
    }
}
