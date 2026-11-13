// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0
import Flutter
import Foundation

final class SecretStorePlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.singlinklabs.singlinkvpn/secrets", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(SecretStorePlugin(), channel: channel)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any], let ref = args["reference"] as? String else {
      return result(FlutterError(code: "invalid-reference", message: "Invalid credential reference", details: nil))
    }
    do {
      switch call.method {
      case "read": result(try CredentialKeychain.read(ref))
      case "write":
        guard let value = args["value"] as? String else { throw CredentialStorageError.corrupt }
        try CredentialKeychain.write(ref, value: value); result(nil)
      case "delete": try CredentialKeychain.delete(ref); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    } catch let error as CredentialStorageError {
      result(FlutterError(code: error.code, message: "Protected credential operation failed", details: nil))
    } catch {
      result(FlutterError(code: "unavailable", message: "Protected credential operation failed", details: nil))
    }
  }
}
