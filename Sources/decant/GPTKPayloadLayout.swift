import Foundation

/// Supplement the kit's signed external/ validation with the bounded layout
/// of Apple's unsigned PE forwarders and unix bridge aliases. No extra payload
/// trees are imported; framework links remain the upstream validator's job.
enum GPTKPayloadLayout {
    static func validate(_ root: URL) throws {
        let fm = FileManager.default
        func type(_ url: URL) throws -> FileAttributeType? {
            try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        }
        func entries(_ directory: URL, allowed: Set<String>) throws -> [URL] {
            guard try type(directory) == .typeDirectory else { throw DecantError("GPTK requires a regular directory: \(directory.lastPathComponent)") }
            let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for child in children {
                if child.lastPathComponent == ".DS_Store", try type(child) == .typeRegular { continue }
                guard allowed.contains(child.lastPathComponent) else { throw DecantError("unexpected GPTK payload component: \(child.lastPathComponent)") }
            }
            return children.filter { $0.lastPathComponent != ".DS_Store" }
        }
        _ = try entries(root, allowed: ["external", "wine"])
        let wine = root.appending(path: "wine")
        _ = try entries(wine, allowed: ["x86_64-windows", "x86_64-unix"])
        // d3d12core is also present in Apple's official 4.0 beta 3 image.
        let names: Set<String> = ["d3d10", "d3d11", "d3d12", "d3d12core", "dxgi", "nvapi64", "nvngx-on-metalfx"]
        for pe in try entries(wine.appending(path: "x86_64-windows"), allowed: Set(names.map { $0 + ".dll" })) {
            guard try type(pe) == .typeRegular else { throw DecantError("GPTK PE must be a regular file: \(pe.lastPathComponent)") }
        }
        let shared = root.appending(path: "external/libd3dshared.dylib")
        for bridge in try entries(wine.appending(path: "x86_64-unix"), allowed: Set(names.map { $0 + ".so" })) {
            if try type(bridge) == .typeSymbolicLink {
                guard try fm.destinationOfSymbolicLink(atPath: bridge.path) == "../../external/libd3dshared.dylib" else {
                    throw DecantError("GPTK bridge must link to its in-payload shared library: \(bridge.lastPathComponent)")
                }
            } else {
                guard try type(bridge) == .typeRegular, try Data(contentsOf: bridge) == Data(contentsOf: shared) else {
                    throw DecantError("GPTK bridge must match its shared library: \(bridge.lastPathComponent)")
                }
            }
        }
    }
}
