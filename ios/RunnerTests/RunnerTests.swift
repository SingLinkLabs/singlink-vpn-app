// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
import Flutter
import UIKit
import XCTest
@testable import Runner

/// Run only on a fresh isolated Simulator created for this test run. Values and
/// references are generated here; no existing profile or Keychain item is read.
final class RunnerTests: XCTestCase {
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
