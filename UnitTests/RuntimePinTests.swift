import Foundation
import XCTest
@testable import decant

final class RuntimePinTests: XCTestCase {
    private func pins() throws -> RuntimePins {
        try RuntimePins.load(from: Bundle.module.url(forResource: "RuntimePins", withExtension: "json"))
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "decant-pin-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    func testBundledPinsAndExactIdentity() throws {
        let pins = try pins()
        XCTAssertFalse(pins.stable.prerelease)
        XCTAssertTrue(pins.prerelease.prerelease)
        let installed = InstalledRuntime(kitCommit: pins.kitCommit, release: pins.prerelease)
        XCTAssertEqual(try RuntimeDecision.update(target: installed, installed: installed, version: pins.prerelease.version, force: false), .current)
        var anotherBeta = installed
        anotherBeta.release.tag += ".review-test"
        anotherBeta.release.sha256 = String(repeating: "a", count: 64)
        XCTAssertEqual(anotherBeta.release.version, installed.release.version)
        XCTAssertEqual(try RuntimeDecision.update(target: anotherBeta, installed: installed, version: installed.release.version, force: false), .install)
        let stable = InstalledRuntime(kitCommit: pins.kitCommit, release: pins.stable)
        XCTAssertEqual(try RuntimeDecision.update(target: stable, installed: installed, version: installed.release.version, force: false), .retainPrerelease)
        XCTAssertEqual(try RuntimeDecision.update(target: stable, installed: installed, version: installed.release.version, force: true), .install)
        XCTAssertThrowsError(try RuntimeDecision.update(target: installed, installed: installed, version: "0.0.0", force: false))
        XCTAssertThrowsError(try RuntimeDecision.update(target: installed, installed: nil, version: installed.release.version, force: false))
    }

    func testIdentityRoundTripAndBadRecord() throws {
        try fixture { root in
            let pins = try pins()
            let path = root.appending(path: "identity.json")
            let record = InstalledRuntime(kitCommit: pins.kitCommit, release: pins.stable)
            XCTAssertNil(try InstalledRuntime.read(at: path))
            try record.write(to: path)
            XCTAssertEqual(try InstalledRuntime.read(at: path), record)
            try Data("incomplete".utf8).write(to: path)
            XCTAssertThrowsError(try InstalledRuntime.read(at: path))
        }
    }

    @MainActor
    func testRelocatedCheckedResourcesAndNormalFailures() throws {
        let pins = try pins()
        try fixture { root in
            for layout in ["standalone", "App.app/Contents/Helpers"] {
                let executable = root.appending(path: layout).appending(path: "decant")
                let resources = layout == "standalone" ? executable.deletingLastPathComponent()
                    : root.appending(path: "App.app/Contents/Resources")
                let bundle = resources.appending(path: "decant_decant.bundle")
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                let pinURL = bundle.appending(path: "RuntimePins.json")
                try Data(contentsOf: Bundle.module.url(forResource: "RuntimePins", withExtension: "json")!).write(to: pinURL)
                let shim = bundle.appending(path: pins.shim.file)
                try Data(contentsOf: Bundle.module.url(forResource: pins.shim.file, withExtension: nil)!).write(to: shim)
                XCTAssertEqual(CheckedResources.bundle(executableURL: executable)?.bundleURL.path, bundle.path)
                XCTAssertEqual(try RuntimePins.load(from: pinURL).shim.sha256, pins.shim.sha256)
                XCTAssertEqual(try Kit.checkedCompatibilityShim(pins: pins, executableURL: executable), shim)
                try Data("damaged".utf8).write(to: shim)
                XCTAssertThrowsError(try Kit.checkedCompatibilityShim(pins: pins, executableURL: executable))
                try FileManager.default.removeItem(at: shim)
                XCTAssertThrowsError(try Kit.checkedCompatibilityShim(pins: pins, executableURL: executable))
                try Data("damaged".utf8).write(to: pinURL)
                XCTAssertThrowsError(try RuntimePins.load(from: pinURL))
                try FileManager.default.removeItem(at: bundle)
                // Foundation may cache a Bundle after removal; actual reads must fail.
                XCTAssertThrowsError(try RuntimePins.load(from: pinURL))
                XCTAssertThrowsError(try Kit.checkedCompatibilityShim(pins: pins, executableURL: executable))
            }
            XCTAssertNil(CheckedResources.bundle(executableURL: nil))
        }
    }

    func testCompatibilityIdentityIsPartOfExactPair() throws {
        let pins = try pins()
        let old = InstalledRuntime(kitCommit: pins.kitCommit, release: pins.prerelease)
        let checked = InstalledRuntime(kitCommit: pins.kitCommit, release: pins.prerelease,
            kitPatchSHA256: pins.kitPatch.sha256, shimSHA256: pins.shim.sha256)
        XCTAssertNotEqual(old, checked)
        XCTAssertEqual(try RuntimeDecision.update(target: checked, installed: old,
            version: old.release.version, force: false), .install)
        XCTAssertEqual(try RuntimeDecision.update(target: checked, installed: checked,
            version: checked.release.version, force: false), .current)
        try fixture { root in
            let path = root.appending(path: "checked.json")
            try checked.write(to: path)
            XCTAssertEqual(try InstalledRuntime.read(at: path), checked)
        }
    }

    func testLaunchRetainsCheckedPrereleaseAndLegacyStableOnly() throws {
        let pins = try pins()
        let installed = InstalledRuntime(kitCommit: pins.kitCommit, release: pins.prerelease)
        XCTAssertEqual(try RuntimeDecision.launchRelease(pins: pins, installed: installed, version: installed.release.version), pins.prerelease)
        XCTAssertEqual(try RuntimeDecision.launchRelease(pins: pins, installed: nil, version: pins.stable.version), pins.stable)
        XCTAssertThrowsError(try RuntimeDecision.launchRelease(pins: pins, installed: nil, version: pins.prerelease.version))
        XCTAssertThrowsError(try RuntimePins.load(from: URL(filePath: "/nonexistent-decant-pins.json")))
    }

    @MainActor
    func testRuntimeCapabilitiesMustMatchPair() throws {
        let pin = try pins().prerelease
        let info = Kit.RuntimeInfo(version: pin.version, dxmt: pin.dxmt, sha256: nil, dxvk: pin.dxvk, gptkCapable: pin.gptkCapable)
        XCTAssertNoThrow(try Kit.validateRuntimeInfo(info, release: pin))
        var incompatible = info
        incompatible.gptkCapable = !pin.gptkCapable
        XCTAssertThrowsError(try Kit.validateRuntimeInfo(incompatible, release: pin))
    }

    func testMetadataMustMatchTagChannelDigestAndURL() throws {
        let pin = try pins().prerelease
        var metadata: [String: Any] = ["tag_name": pin.tag, "prerelease": true, "draft": false,
            "assets": [["name": "Libraries.tar.gz", "digest": "sha256:" + pin.sha256,
                        "browser_download_url": pin.url.absoluteString, "state": "uploaded"]]]
        func data() throws -> Data { try JSONSerialization.data(withJSONObject: metadata) }
        XCTAssertNoThrow(try pin.checkMetadata(data()))
        metadata["tag_name"] = "v0.0.0"
        XCTAssertThrowsError(try pin.checkMetadata(data()))
        metadata["tag_name"] = pin.tag
        metadata["assets"] = [["name": "Libraries.tar.gz", "digest": "sha256:" + String(repeating: "0", count: 64),
                                "browser_download_url": pin.url.absoluteString, "state": "uploaded"]]
        XCTAssertThrowsError(try pin.checkMetadata(data()))
    }

    func testLegacyDXVKFalseConflict() throws {
        XCTAssertThrowsError(try BackendSafety.checkLegacyDXVK(backend: "dxvk", explicitProgramBackend: false, legacyDXVK: false))
        XCTAssertThrowsError(try BackendSafety.checkLegacyDXVK(backend: "dxmt", explicitProgramBackend: false, legacyDXVK: false))
        XCTAssertNoThrow(try BackendSafety.checkLegacyDXVK(backend: "dxvk", explicitProgramBackend: true, legacyDXVK: false))
        XCTAssertNoThrow(try BackendSafety.checkLegacyDXVK(backend: "dxvk", explicitProgramBackend: false, legacyDXVK: nil))
    }

    func testExpectedPayloadComponentsAndLegitimateBridgeLinks() throws {
        try fixture { root in
            let fm = FileManager.default
            for directory in ["external", "wine/x86_64-windows", "wine/x86_64-unix"] {
                try fm.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true)
            }
            let shared = Data("shared fixture".utf8)
            try shared.write(to: root.appending(path: "external/libd3dshared.dylib"))
            try Data("PE fixture".utf8).write(to: root.appending(path: "wine/x86_64-windows/dxgi.dll"))
            try fm.createSymbolicLink(atPath: root.appending(path: "wine/x86_64-unix/dxgi.so").path,
                                      withDestinationPath: "../../external/libd3dshared.dylib")
            XCTAssertNoThrow(try GPTKPayloadLayout.validate(root))
            try Data("extra note".utf8).write(to: root.appending(path: "wine/x86_64-windows/notes.txt"))
            XCTAssertThrowsError(try GPTKPayloadLayout.validate(root))
        }
    }
}
