// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

enum CredentialStorageError: Error {
  case invalid, locked, permission, corrupt, unavailable
  var code: String {
    switch self {
    case .invalid: return "invalid-reference"
    case .locked: return "locked"
    case .permission: return "permission"
    case .corrupt: return "corrupt"
    case .unavailable: return "unavailable"
    }
  }
}

/// Both iOS targets use the same build-expanded access group. No team ID or
/// credential is part of source control. macOS uses the app's login Keychain.
enum CredentialKeychain {
  static let service = "com.singlinklabs.singlinkvpn.credentials"
  static func valid(_ ref: String) -> Bool {
    ref.range(of: "^slk_v1_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
  }
  static func newReference() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CredentialStorageError.unavailable
    }
    return "slk_v1_" + Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  private static func query(_ ref: String) throws -> [String: Any] {
    guard valid(ref) else { throw CredentialStorageError.invalid }
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: ref,
      kSecAttrSynchronizable as String: false]
    #if os(iOS)
    guard let group = Bundle.main.object(forInfoDictionaryKey: "CredentialAccessGroup") as? String,
      !group.isEmpty, !group.contains("$(") else { throw CredentialStorageError.unavailable }
    q[kSecAttrAccessGroup as String] = group
    #endif
    return q
  }
  private static func checked(_ status: OSStatus) throws {
    switch status {
    case errSecSuccess: return
    case errSecInteractionNotAllowed, errSecNotAvailable: throw CredentialStorageError.locked
    case errSecAuthFailed, errSecMissingEntitlement: throw CredentialStorageError.permission
    default: throw CredentialStorageError.unavailable
    }
  }
  static func read(_ ref: String) throws -> String? {
    var q = try query(ref)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    try checked(status)
    guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
      throw CredentialStorageError.corrupt
    }
    return text
  }
  static func write(_ ref: String, value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 65536 else {
      throw CredentialStorageError.corrupt
    }
    var q = try query(ref)
    q[kSecValueData as String] = Data(value.utf8)
    #if os(iOS)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    #endif
    // References are immutable. A duplicate must already contain the same value.
    let status = SecItemAdd(q as CFDictionary, nil)
    if status == errSecDuplicateItem {
      guard try read(ref) == value else { throw CredentialStorageError.corrupt }
      return
    }
    try checked(status)
  }
  static func delete(_ ref: String) throws {
    let status = SecItemDelete(try query(ref) as CFDictionary)
    if status != errSecItemNotFound { try checked(status) }
  }
}
