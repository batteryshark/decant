import Foundation
import XCTest
@testable import decant

final class ImportTests: XCTestCase {
    @MainActor
    func testInstallRedeployOrderingAndFailure() throws {
        var events: [String] = []
        try Runtime.installAndRestore(install: { events.append("install") }, restore: { events.append("restore") })
        XCTAssertEqual(events, ["install", "restore"])
        events = []
        XCTAssertThrowsError(try Runtime.installAndRestore(install: { throw DecantError("install failed") }, restore: { events.append("restore") }))
        XCTAssertTrue(events.isEmpty)
        XCTAssertThrowsError(try Runtime.installAndRestore(install: {}, restore: { throw DecantError("restore failed") })) { error in
            XCTAssertTrue(String(describing: error).contains("runtime installed, but GPTK redeployment failed"))
        }
    }

    @MainActor
    func testOriginalApplePayloadReadOnly() throws {
        guard let path = ProcessInfo.processInfo.environment["DECANT_TEST_GPTK_PATH"] else {
            throw XCTSkip("set DECANT_TEST_GPTK_PATH for read-only Apple payload validation")
        }
        let version = try Kit.validateGPTK(URL(filePath: path))
        print("Apple-signature validated GPTK version: \(version)")
        XCTAssertFalse(version.isEmpty)
    }

    func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "decant-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testCustomDLLProtection() throws {
        try fixture { root in
            let dll = root.appending(path: "dxgi.dll")
            let known = root.appending(path: "known.dll")
            try Data(repeating: 1, count: 128).write(to: dll)
            XCTAssertThrowsError(try BackendSafety.checkReplacement(dll, knownCopies: []))
            try FileManager.default.copyItem(at: dll, to: known)
            XCTAssertNoThrow(try BackendSafety.checkReplacement(dll, knownCopies: [known]))
            var builtin = Data(repeating: 0, count: 128)
            builtin.replaceSubrange(0x40..<0x50, with: BackendSafety.marker)
            try builtin.write(to: dll)
            XCTAssertNoThrow(try BackendSafety.checkReplacement(dll, knownCopies: []))
            try FileManager.default.removeItem(at: dll)
            try FileManager.default.createSymbolicLink(at: dll, withDestinationURL: known)
            XCTAssertThrowsError(try BackendSafety.checkReplacement(dll, knownCopies: [known]))
        }
    }

    func testPlaceholdersNeverOverwrite() throws {
        try fixture { root in
            let source = root.appending(path: "runtime")
            let target = root.appending(path: "system32")
            for dir in [source, target] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false) }
            var builtin = Data(repeating: 0, count: 128)
            builtin.replaceSubrange(0x40..<0x50, with: BackendSafety.marker)
            for name in ["d3dmt.dll", "dxgm.dll"] { try builtin.write(to: source.appending(path: name)) }
            let custom = Data("custom".utf8)
            try custom.write(to: target.appending(path: "dxgm.dll"))
            try BackendSafety.seedPlaceholders(system32: target, runtimePE: source)
            XCTAssertEqual(try Data(contentsOf: target.appending(path: "d3dmt.dll")), builtin)
            XCTAssertEqual(try Data(contentsOf: target.appending(path: "dxgm.dll")), custom)
        }
    }

    func testSwitchRestoresOnlyKnownNativeDLLs() throws {
        try fixture { root in
            let target = root.appending(path: "d3d11.dll")
            let native = root.appending(path: "native.dll")
            let source = root.appending(path: "builtin.dll")
            let bytes = Data(repeating: 1, count: 128)
            var builtin = Data(repeating: 0, count: 128)
            builtin.replaceSubrange(0x40..<0x50, with: BackendSafety.marker)
            try bytes.write(to: native); try bytes.write(to: target); try builtin.write(to: source)
            try BackendSafety.restoreBuiltin(target, from: source, knownCopies: [native])
            XCTAssertEqual(try Data(contentsOf: target), builtin)
            let custom = Data("custom".utf8)
            try custom.write(to: target)
            XCTAssertThrowsError(try BackendSafety.restoreBuiltin(target, from: source, knownCopies: [native]))
            XCTAssertEqual(try Data(contentsOf: target), custom)
        }
    }

    func testStrippedDXGIRemainsRecognizable() throws {
        try fixture { root in
            let target = root.appending(path: "dxgi.dll")
            let original = root.appending(path: "original.dll")
            var builtin = Data(repeating: 2, count: 128)
            builtin.replaceSubrange(0x40..<0x50, with: BackendSafety.marker)
            try builtin.write(to: original)
            builtin.replaceSubrange(0x40..<0x50, with: Data(repeating: 0, count: 16))
            try builtin.write(to: target)
            XCTAssertNoThrow(try BackendSafety.checkReplacement(target, knownCopies: [], strippedBuiltin: original))
            builtin[0x51] = 3
            try builtin.write(to: target)
            XCTAssertThrowsError(try BackendSafety.checkReplacement(target, knownCopies: [], strippedBuiltin: original))
        }
    }

    func testNoRecursiveOrArbitraryDMGSearch() throws {
        try fixture { root in
            try Data().write(to: root.appending(path: "unrelated.dmg"))
            let sub = root.appending(path: "subfolder")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            try Data().write(to: sub.appending(path: "Evaluation environment.dmg"))
            XCTAssertThrowsError(try GPTKDiskImage.withPayload(at: root, locate: { _ in nil }, runner: { _ in
                XCTFail("must not attach arbitrary or recursively discovered images"); return (1, Data())
            }) { _ in })
        }
    }

    func testDirectDirectoryNeverDetaches() throws {
        try fixture { root in
            let result = try GPTKDiskImage.withPayload(at: root, locate: { $0 }, runner: { _ in XCTFail("hdiutil unexpected"); return (1, Data()) }) { $0 }
            XCTAssertEqual(result, root)
        }
    }

    func testNestedMountsCleanUpInReverseOnImportFailure() throws {
        var calls: [[String]] = []
        var mounts: [URL] = []
        let runner: GPTKDiskImage.Runner = { args in
            calls.append(args)
            if args.first == "detach" { return (0, Data()) }
            XCTAssertTrue(args.contains("-readonly")); XCTAssertTrue(args.contains("-nobrowse"))
            let mount = URL(filePath: args[args.firstIndex(of: "-mountpoint")! + 1])
            mounts.append(mount)
            if mounts.count == 1 {
                try Data().write(to: mount.appending(path: "Evaluation environment for Windows games.dmg"))
            }
            return (0, try PropertyListSerialization.data(fromPropertyList: ["system-entities": [["mount-point": mount.path]]], format: .xml, options: 0))
        }
        XCTAssertThrowsError(try GPTKDiskImage.withPayload(at: URL(filePath: "/fixture.dmg"), locate: { root in
            mounts.count == 2 ? root : nil
        }, runner: runner) { _ in throw DecantError("import failed") })
        XCTAssertEqual(calls.filter { $0.first == "detach" }.map { $0[1] }, mounts.reversed().map(\.path))
        // Fake detach does not clear our fake image contents.
        for mount in mounts { try? FileManager.default.removeItem(at: mount.deletingLastPathComponent()) }
    }

    func testAttachFailureNeverDetachesReturnedForeignMount() throws {
        var calls: [[String]] = []
        XCTAssertThrowsError(try GPTKDiskImage.withPayload(at: URL(filePath: "/fixture.dmg"), locate: { _ in nil }, runner: { args in
            calls.append(args)
            return (0, try PropertyListSerialization.data(fromPropertyList: ["system-entities": [["mount-point": "/Volumes/UserMount"]]], format: .xml, options: 0))
        }) { _ in })
        let detached = calls.filter { $0.first == "detach" }
        XCTAssertEqual(detached.count, 1)
        XCTAssertFalse(detached[0].contains("/Volumes/UserMount"))
    }

    func testParsingDoesNotTreatProgramArgumentsAsLauncherOptions() throws {
        let parsed = try parse(["--bottle", "Test", "game.exe", "--backend", "custom"], valued: ["--bottle"], stopAtPositional: true)
        XCTAssertEqual(parsed.rest, ["game.exe", "--backend", "custom"])
        XCTAssertThrowsError(try parse(["--backend"], valued: ["--backend"]))
    }
}
