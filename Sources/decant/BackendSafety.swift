import Foundation

enum BackendSafety {
    // Upstream applies legacy dxvk=false after the bottle preset, resetting
    // its DLLs to builtin. Do not report DXVK while preparing that conflict.
    static func checkLegacyDXVK(backend: String, explicitProgramBackend: Bool, legacyDXVK: Bool?) throws {
        if ["dxvk", "dxmt"].contains(backend), !explicitProgramBackend, legacyDXVK == false {
            throw DecantError("requested \(backend) conflicts with saved program dxvk=false; use a separate bottle or remove that override")
        }
    }

    static let marker = Data("Wine builtin DLL".utf8)

    static func restoreBuiltin(_ destination: URL, from source: URL, knownCopies: [URL], strippedBuiltin: URL? = nil) throws {
        guard (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil else { return }
        try checkReplacement(destination, knownCopies: knownCopies, strippedBuiltin: strippedBuiltin)
        let data = try Data(contentsOf: destination)
        if data.count >= 0x50, data[0x40..<0x50] == marker { return }
        let builtin = try Data(contentsOf: source)
        guard builtin.count >= 0x50, builtin[0x40..<0x50] == marker else {
            throw DecantError("missing builtin DLL for backend switch: \(source.path)")
        }
        try builtin.write(to: destination, options: .atomic)
    }

    /// Upstream replaces backend DLLs, and DXVK removes native dxgi. Refuse
    /// unknown files before handing it a prefix; never delete custom DLLs here.
    static func checkReplacement(_ destination: URL, knownCopies: [URL], strippedBuiltin: URL? = nil) throws {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: destination.path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DecantError("refusing to replace non-regular DLL: \(destination.path)")
        }
        let data = try Data(contentsOf: destination)
        if data.count >= 0x50, data[0x40..<0x50] == marker { return }
        if knownCopies.contains(where: { (try? Data(contentsOf: $0)) == data }) { return }
        if let original = strippedBuiltin, let bytes = try? Data(contentsOf: original),
           bytes.count == data.count, data.count >= 0x50,
           bytes[..<0x40] == data[..<0x40], bytes[0x50...] == data[0x50...] { return }
        throw DecantError("custom or unrecognized DLL would be replaced: \(destination.path); use a separate bottle")
    }

    /// Older prefixes need the interposers' renamed builtin placeholders.
    /// Copy only missing regular files; existing customizations stay untouched.
    static func seedPlaceholders(system32: URL, runtimePE: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: system32.path) else { return }
        for name in ["d3dmt.dll", "dxgm.dll"] {
            let source = runtimePE.appending(path: name)
            let target = system32.appending(path: name)
            guard (try? fm.attributesOfItem(atPath: target.path)) == nil,
                  let data = try? Data(contentsOf: source), data.count >= 0x50,
                  data[0x40..<0x50] == marker else { continue }
            try fm.copyItem(at: source, to: target)
        }
    }
}
