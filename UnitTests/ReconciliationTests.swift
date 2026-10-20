import Foundation
import XCTest
@testable import decant

@MainActor
final class ReconciliationTests: XCTestCase {
    private func fixture(_ body: (URL, RuntimePins, InstalledRuntime) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "decant-reconcile-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pins = try RuntimePins.load(from: Bundle.module.url(forResource: "RuntimePins", withExtension: "json"))
        let installed = InstalledRuntime(kitCommit: pins.kitCommit, release: pins.prerelease,
            kitPatchSHA256: pins.kitPatch.sha256, shimSHA256: pins.shim.sha256)
        try body(root, pins, installed)
    }

    func testHandPlacedPayloadSurvivesAutomaticRepairButExplicitImportReplaces() throws {
        try fixture { root, pins, installed in
            let library = root.appending(path: "Libraries"), store = root.appending(path: "store")
            let bridge = library.appending(path: "Wine/lib/wine/x86_64-unix/dxgi.so")
            let payload = library.appending(path: "Wine/lib/external/libd3dshared.dylib")
            for file in [bridge, payload] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("hand placed".utf8).write(to: file)
            }
            let identity = root.appending(path: "identity.json")
            var verifies = 0, deploys = 0
            @MainActor func redeploy(explicit: Bool) throws {
                try Kit.redeployGPTK(store: store, library: library, replaceHandPlaced: explicit,
                    verify: { verifies += 1 }, deploy: {
                        deploys += 1
                        try Data("stored payload".utf8).write(to: payload)
                    })
            }
            try Runtime.reconcile(installed, pins: pins, identityURL: identity,
                stage: { true }, redeploy: { try redeploy(explicit: false) })
            XCTAssertEqual(try Data(contentsOf: payload), Data("hand placed".utf8))
            XCTAssertEqual(verifies, 1); XCTAssertEqual(deploys, 0)
            try redeploy(explicit: true) // The explicit import path's replacement policy.
            XCTAssertEqual(try Data(contentsOf: payload), Data("stored payload".utf8))
            XCTAssertEqual(deploys, 1)
            XCTAssertThrowsError(try Runtime.reconcile(installed, pins: pins, identityURL: identity,
                stage: { true }, redeploy: {
                    try Kit.redeployGPTK(store: store, library: library,
                        verify: { throw DecantError("damaged store") }, deploy: { XCTFail("must not deploy") })
                }))
            XCTAssertNil(try InstalledRuntime.read(at: identity)?.shimSHA256)
        }
    }

    func testMissingOverlayDeployFailureRetriesWithReleaseProvenance() throws {
        try fixture { root, pins, installed in
            let identity = root.appending(path: "identity.json"), overlay = root.appending(path: "overlay.dll")
            try installed.write(to: identity)
            var deploys = 0
            func stage() throws -> Bool {
                if FileManager.default.fileExists(atPath: overlay.path) { return false }
                try Data("overlay".utf8).write(to: overlay); return true
            }
            XCTAssertThrowsError(try Runtime.reconcile(installed, pins: pins, identityURL: identity,
                stage: stage, redeploy: { deploys += 1; throw DecantError("injected deploy failure") }))
            let pending = try XCTUnwrap(InstalledRuntime.read(at: identity))
            XCTAssertEqual(pending.release, installed.release)
            XCTAssertTrue(pending.release.prerelease)
            XCTAssertNil(pending.kitPatchSHA256); XCTAssertNil(pending.shimSHA256)
            try Runtime.reconcile(pending, pins: pins, identityURL: identity,
                stage: stage, redeploy: { deploys += 1 })
            XCTAssertEqual(deploys, 2)
            XCTAssertEqual(try InstalledRuntime.read(at: identity), installed)
            try Runtime.reconcile(installed, pins: pins, identityURL: identity,
                stage: stage, redeploy: { XCTFail("matching pair must not redeploy") })
            XCTAssertThrowsError(try Runtime.reconcile(installed, pins: pins, identityURL: identity,
                stage: { throw DecantError("interrupted stage") }, redeploy: { XCTFail() }))
            let interrupted = try XCTUnwrap(InstalledRuntime.read(at: identity))
            XCTAssertEqual(interrupted.release, installed.release)
            XCTAssertNil(interrupted.shimSHA256)
            try Runtime.reconcile(interrupted, pins: pins, identityURL: identity,
                stage: stage, redeploy: { deploys += 1 })
            XCTAssertEqual(deploys, 3)
            XCTAssertEqual(try InstalledRuntime.read(at: identity), installed)
        }
    }
}
