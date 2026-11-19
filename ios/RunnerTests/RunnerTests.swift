// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
import Flutter
import NetworkExtension
import UIKit
import XCTest
@testable import Runner

/// Run only on a fresh isolated Simulator created for this test run. Values and
/// references are generated here; no existing profile or Keychain item is read.
final class RunnerTests: XCTestCase {
  // A-H06: stop reports success only after iOS shows the tunnel down.
  func testStopActionForEveryStatus() {
    XCTAssertEqual(SingLinkVpnPlugin.stopAction(for: .connected), .requestStop)
    XCTAssertEqual(SingLinkVpnPlugin.stopAction(for: .connecting), .requestStop)
    XCTAssertEqual(SingLinkVpnPlugin.stopAction(for: .reasserting), .requestStop)
    XCTAssertEqual(SingLinkVpnPlugin.stopAction(for: .disconnecting), .waitOnly)
    XCTAssertEqual(SingLinkVpnPlugin.stopAction(for: .disconnected), .none)
    XCTAssertEqual(SingLinkVpnPlugin.stopAction(for: .invalid), .none)
  }

  func testStopTimeoutOrLiveStatusIsAnError() {
    XCTAssertEqual(SingLinkVpnPlugin.stopError(final: nil), "timeout while stopping the VPN")
    XCTAssertNotNil(SingLinkVpnPlugin.stopError(final: .disconnecting))
    XCTAssertNotNil(SingLinkVpnPlugin.stopError(final: .connected))
    XCTAssertNil(SingLinkVpnPlugin.stopError(final: .disconnected))
    XCTAssertNil(SingLinkVpnPlugin.stopError(final: .invalid))
  }

  // App F-04: "Block traffic outside the VPN" maps to includeAllNetworks
  // with the local network kept reachable; off by default.
  func testRoutingPolicy() {
    let proto = NETunnelProviderProtocol()
    SingLinkVpnPlugin.applyRoutingPolicy(proto, blockOutsideTunnel: false)
    XCTAssertFalse(proto.includeAllNetworks)
    XCTAssertFalse(proto.enforceRoutes)
    SingLinkVpnPlugin.applyRoutingPolicy(proto, blockOutsideTunnel: true)
    XCTAssertTrue(proto.includeAllNetworks)
    XCTAssertTrue(proto.excludeLocalNetworks)
    XCTAssertFalse(proto.enforceRoutes)
    SingLinkVpnPlugin.applyRoutingPolicy(proto, blockOutsideTunnel: false)
    XCTAssertFalse(proto.includeAllNetworks)
  }

  // App F-07: the settings folder is excluded from device backups.
  func testAppDataIsExcludedFromBackup() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("synthetic-backup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    XCTAssertTrue(AppDelegate.excludeAppDataFromBackup(base: base))
    let dir = base.appendingPathComponent("com.singlinklabs.singlinkvpn", isDirectory: true)
    let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  func testInvalidReferenceFailsBeforeKeychainAccess() throws {
    XCTAssertFalse(CredentialKeychain.valid("../invalid"))
    XCTAssertThrowsError(try CredentialKeychain.read("../invalid"))
  }

  func testSyntheticKeychainRoundTripAndImmutableReference() throws {
    let reference = try CredentialKeychain.newReference()
    let payload = "synthetic-fixture-" + UUID().uuidString
    do {
      try CredentialKeychain.write(reference, value: payload)
    } catch CredentialStorageError.permission {
      throw XCTSkip("Simulator does not have the required shared Keychain entitlement; shared-item runtime verification is still required.")
    } catch CredentialStorageError.unavailable {
      throw XCTSkip("Test runner does not have a build-expanded access group; shared-item runtime verification is still required.")
    }
    defer { try? CredentialKeychain.delete(reference) }
    XCTAssertEqual(try CredentialKeychain.read(reference), payload)
    XCTAssertThrowsError(try CredentialKeychain.write(reference, value: payload + "changed"))
    try CredentialKeychain.write(reference, value: payload)
    try CredentialKeychain.delete(reference)
    XCTAssertNil(try CredentialKeychain.read(reference))
  }
}
