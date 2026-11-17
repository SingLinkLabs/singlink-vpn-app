// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// MethodChannel `com.singlinklabs.singlinkvpn/vpn`: the Dart IosTunnelCore
// (lib/platform/ios.dart) drives the packet tunnel extension
// (ios/PacketTunnel, bundle id com.singlinklabs.singlinkvpn.tunnel) through
// NETunnelProviderManager.
//
// Every method answers a JSON string in the core's format:
//   start {reference}   -> {"ok":true} | {"ok":false,"error":".."}
//   stop                   -> {"ok":true}
//   status                 -> SingLinkStatus JSON (+ "state"); running=false
//                             once iOS reports the VPN as disconnected
//   probe {url, timeoutMs} -> SingLinkProbe JSON (from the extension)
//   exitIP {timeoutMs}     -> SingLinkExitIP JSON (from the extension)
// and NEVPNStatusDidChange is pushed to Dart as `onStatus`
// {"state":"connected","running":true}.
//
// Error texts start with fixed English prefixes ("vpn permission denied",
// "vpn unsupported") that lib/core/error_messages.dart maps to plain English.

import Flutter
import NetworkExtension
import UIKit

final class SingLinkVpnPlugin: NSObject, FlutterPlugin {
  static let channelName = "com.singlinklabs.singlinkvpn/vpn"
  static let tunnelBundleId = "com.singlinklabs.singlinkvpn.tunnel"
  static let appGroup = "group.com.singlinklabs.singlinkvpn"
  static let startTimeout: TimeInterval = 45
  static let stopTimeout: TimeInterval = 10

  private let channel: FlutterMethodChannel
  private var manager: NETunnelProviderManager?
  private var statusObserver: NSObjectProtocol?
  /// Set by stop(): the next disconnect is not reported as an error.
  private var userStopped = false
  private var startedAt = Date.distantPast
  private var generation: UInt64 = 0
  private var migratingProviderConfiguration = true

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  deinit {
    if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    let instance = SingLinkVpnPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.migrateLegacyProviderConfiguration()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reply: (String) -> Void = { s in DispatchQueue.main.async { result(s) } }
    let timeoutMs = args["timeoutMs"] as? Int ?? 8000
    switch call.method {
    case "start":
      start(reference: args["reference"] as? String ?? "", reply)
    case "stop":
      stop(reply)
    case "status":
      status(reply)
    case "probe":
      let url = args["url"] as? String ?? "https://www.gstatic.com/generate_204"
      providerCommand(["cmd": "probe", "url": url, "timeoutMs": timeoutMs], reply)
    case "exitIP":
      providerCommand(["cmd": "exitip", "timeoutMs": timeoutMs], reply)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Commands

  private func start(reference: String, _ reply: @escaping (String) -> Void) {
    guard !migratingProviderConfiguration else {
      return reply(Self.json(["ok": false, "error": "protected credential migration is still running; retry shortly"]))
    }
    generation &+= 1
    let operation = generation
    #if targetEnvironment(simulator)
    reply(Self.json([
      "ok": false,
      "error": "vpn unsupported: the iOS Simulator cannot run a Network Extension packet tunnel",
    ]))
    #else
    guard CredentialKeychain.valid(reference),
      let stored = try? CredentialKeychain.read(reference),
      let bytes = stored.data(using: .utf8),
      let record = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      record["version"] as? Int == 1,
      let link = record["link"] as? String, link.hasPrefix("singlink://")
    else { return reply(Self.json(["ok": false, "error": "protected credentials unavailable"])) }
    loadManager { existing, error in
      guard operation == self.generation else { return reply(Self.cancelled) }
      if let error { return reply(Self.fail(error)) }
      let m = existing ?? NETunnelProviderManager()
      // A reference created by the one-time legacy migration below is owned
      // by this plugin, not by the Dart profile store. Remove it once the
      // configuration points at a profile-owned reference instead.
      let previous = m.protocolConfiguration as? NETunnelProviderProtocol
      let migratedOrphan = (previous?.providerConfiguration?["migratedLegacy"] as? Bool == true)
        ? previous?.providerConfiguration?["secretRef"] as? String : nil
      let proto = NETunnelProviderProtocol()
      proto.providerBundleIdentifier = Self.tunnelBundleId
      proto.serverAddress = "SingLinkVPN"
      proto.providerConfiguration = ["secretRef": reference]
      proto.disconnectOnSleep = false
      m.protocolConfiguration = proto
      m.localizedDescription = "SingLinkVPN"
      m.isEnabled = true
      // The first save shows iOS's '"SingLinkVPN" Would Like to Add VPN
      // Configurations' prompt.
      m.saveToPreferences { error in
        guard operation == self.generation else { return reply(Self.cancelled) }
        if let error { return reply(Self.fail(error)) }
        if let orphan = migratedOrphan, orphan != reference {
          try? CredentialKeychain.delete(orphan)
        }
        // Reload, or the first start after a save fails with
        // "configuration is stale".
        m.loadFromPreferences { error in
          guard operation == self.generation else { return reply(Self.cancelled) }
          if let error { return reply(Self.fail(error)) }
          self.adopt(m)
          self.stopIfActive(m) { stopError in
            guard operation == self.generation else { return reply(Self.cancelled) }
            // Never start over a session that has not actually gone down.
            if let stopError { return reply(Self.json(["ok": false, "error": stopError])) }
            self.startTunnel(m, operation: operation, reply)
          }
        }
      }
    }
    #endif
  }

  private func startTunnel(_ m: NETunnelProviderManager, operation: UInt64, _ reply: @escaping (String) -> Void) {
    guard operation == generation else { return reply(Self.cancelled) }
    userStopped = false
    startedAt = Date()
    Self.sharedDefaults?.removeObject(forKey: "lastError")
    do {
      try m.connection.startVPNTunnel()
    } catch {
      return reply(Self.fail(error))
    }
    var sawConnecting = false
    waitForStatus(m.connection, timeout: Self.startTimeout, until: { status, elapsed in
      if operation != self.generation { return true }
      switch status {
      case .connecting, .reasserting:
        sawConnecting = true
        return false
      case .connected:
        return true
      case .disconnected, .invalid:
        // Right after startVPNTunnel the status can still read disconnected.
        return sawConnecting || elapsed > 3
      default:
        return false
      }
    }) { status in
      guard operation == self.generation else { return reply(Self.cancelled) }
      switch status {
      case .connected?:
        reply(Self.json(["ok": true]))
      case nil:
        m.connection.stopVPNTunnel()
        reply(Self.json(["ok": false, "error": "timeout while starting the VPN"]))
      default:
        self.disconnectReason(m) { reason in
          reply(Self.json(["ok": false, "error": reason ?? "vpn tunnel stopped while connecting"]))
        }
      }
    }
  }

  /// What stopIfActive does for a connection in [status].
  enum StopAction: Equatable {
    /// Already down: nothing to wait for.
    case none
    /// Ask iOS to stop, then wait until it reports the tunnel down.
    case requestStop
    /// iOS is already disconnecting: only wait until it is down.
    case waitOnly
  }

  static func stopAction(for status: NEVPNStatus) -> StopAction {
    switch status {
    case .connected, .connecting, .reasserting: return .requestStop
    case .disconnecting: return .waitOnly
    case .disconnected, .invalid: return .none
    @unknown default: return .requestStop
    }
  }

  /// Only an observed disconnected/invalid status counts as stopped.
  static func isStopped(_ status: NEVPNStatus) -> Bool {
    status == .disconnected || status == .invalid
  }

  /// nil when [final] (the last status seen, nil on timeout) shows the
  /// tunnel down, else the error to report.
  static func stopError(final: NEVPNStatus?) -> String? {
    guard let final else { return "timeout while stopping the VPN" }
    return isStopped(final) ? nil : "the VPN did not stop (\(name(final)))"
  }

  /// Stops [m]'s tunnel and calls [then] with nil only once iOS reports it
  /// disconnected (or invalid); a timeout is reported, never treated as
  /// success (A-H06).
  private func stopIfActive(_ m: NETunnelProviderManager, _ then: @escaping (String?) -> Void) {
    switch Self.stopAction(for: m.connection.status) {
    case .none:
      then(nil)
    case .requestStop, .waitOnly:
      userStopped = true
      if Self.stopAction(for: m.connection.status) == .requestStop {
        m.connection.stopVPNTunnel()
      }
      waitForStatus(m.connection, timeout: Self.stopTimeout, until: { s, _ in
        Self.isStopped(s)
      }) { final in then(Self.stopError(final: final)) }
    }
  }

  private func stop(_ reply: @escaping (String) -> Void) {
    generation &+= 1
    let operation = generation
    loadManager { m, error in
      guard operation == self.generation else { return reply(Self.cancelled) }
      // A manager that could not be loaded may still be running a tunnel:
      // report the failure instead of claiming it stopped.
      if let error { return reply(Self.fail(error)) }
      guard let m else { return reply(Self.json(["ok": true])) }
      self.stopIfActive(m) { stopError in
        if let stopError { return reply(Self.json(["ok": false, "error": stopError])) }
        reply(Self.json(["ok": true]))
      }
    }
  }

  private func status(_ reply: @escaping (String) -> Void) {
    loadManager { m, _ in
      guard let m else { return reply(Self.idleStatus(lastError: "", state: "invalid")) }
      let state = Self.name(m.connection.status)
      switch m.connection.status {
      case .connected, .reasserting:
        self.send(m, ["cmd": "status"], timeout: 3) { raw in
          // The extension is busy or restarting: still connected as far as
          // iOS is concerned, so do not report a disconnect.
          guard let raw, var obj = Self.decode(raw) else {
            return reply(Self.json(["running": true, "state": state, "listen": "tun"]))
          }
          obj["state"] = state
          reply(Self.json(obj))
        }
      case .connecting:
        reply(Self.json(["running": true, "state": state, "listen": "tun"]))
      default:
        if self.userStopped {
          return reply(Self.idleStatus(lastError: "", state: state))
        }
        self.disconnectReason(m) { reason in
          reply(Self.idleStatus(lastError: reason ?? "", state: state))
        }
      }
    }
  }

  /// probe / exitip, answered by the core inside the extension.
  private func providerCommand(_ msg: [String: Any], _ reply: @escaping (String) -> Void) {
    loadManager { m, _ in
      guard let m, m.connection.status == .connected || m.connection.status == .reasserting else {
        return reply(Self.json(["ok": false, "error": "not running"]))
      }
      let timeoutMs = msg["timeoutMs"] as? Int ?? 8000
      self.send(m, msg, timeout: Double(timeoutMs) / 1000 + 5) { raw in
        reply(raw ?? Self.json(["ok": false, "error": "timeout: the VPN extension did not answer"]))
      }
    }
  }

  /// Upgrade the app-owned legacy provider dictionary without copying its
  /// credential to any ordinary file/log. A locked Keychain leaves the old
  /// configuration untouched; the extension refuses legacy plaintext fallback.
  private func migrateLegacyProviderConfiguration() {
    // Not tied to the start/stop generation: start() is refused until this
    // finishes, and a stop must not leave the legacy link in OS preferences.
    loadManager { manager, _ in
      guard let manager, let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
        let legacy = proto.providerConfiguration?["link"] as? String else {
          self.migratingProviderConfiguration = false; return
        }
      do {
        let reference = try CredentialKeychain.newReference()
        let record = Self.json(["version": 1, "link": legacy, "acknowledgedWarnings": [String]()])
        try CredentialKeychain.write(reference, value: record)
        guard (try? CredentialKeychain.read(reference)) == record else {
          try? CredentialKeychain.delete(reference)
          self.migratingProviderConfiguration = false; return
        }
        proto.providerConfiguration = ["secretRef": reference, "migratedLegacy": true]
        proto.serverAddress = "SingLinkVPN"
        manager.protocolConfiguration = proto
        manager.saveToPreferences { error in
          // Not committed: drop the staged item; the saved configuration keeps
          // the legacy value, which the extension refuses to use.
          if error != nil { try? CredentialKeychain.delete(reference) }
          self.migratingProviderConfiguration = false
        }
      } catch { self.migratingProviderConfiguration = false /* User must unlock/re-import; never downgrade. */ }
    }
  }

  private static let cancelled = #"{"ok":false,"error":"connection cancelled"}"#

  // MARK: - Manager

  private func loadManager(_ done: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    if let manager { return done(manager, nil) }
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        if let error { return done(nil, error) }
        let m = managers?.first {
          ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
            == Self.tunnelBundleId
        }
        if let m { self.adopt(m) }
        done(m, nil)
      }
    }
  }

  /// Keeps [m] and forwards its status changes to Dart.
  private func adopt(_ m: NETunnelProviderManager) {
    if manager === m && statusObserver != nil { return }
    if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    manager = m
    statusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: m.connection, queue: .main
    ) { [weak self] _ in
      guard let self, let m = self.manager else { return }
      let s = m.connection.status
      self.channel.invokeMethod("onStatus", arguments: Self.json([
        "state": Self.name(s),
        "running": s == .connected || s == .connecting || s == .reasserting,
      ]))
    }
  }

  private func send(
    _ m: NETunnelProviderManager,
    _ msg: [String: Any],
    timeout: TimeInterval,
    _ done: @escaping (String?) -> Void
  ) {
    var finished = false
    let finish: (String?) -> Void = { s in
      DispatchQueue.main.async {
        if finished { return }
        finished = true
        done(s)
      }
    }
    guard let session = m.connection as? NETunnelProviderSession,
          let data = try? JSONSerialization.data(withJSONObject: msg)
    else { return finish(nil) }
    do {
      try session.sendProviderMessage(data) { response in
        finish(response.flatMap { String(data: $0, encoding: .utf8) })
      }
    } catch {
      return finish(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
  }

  /// Polls [conn] on the main queue until [until] says stop (passes the
  /// final status) or [timeout] passes (passes nil).
  private func waitForStatus(
    _ conn: NEVPNConnection,
    timeout: TimeInterval,
    until: @escaping (NEVPNStatus, TimeInterval) -> Bool,
    done: @escaping (NEVPNStatus?) -> Void
  ) {
    let begin = Date()
    func tick() {
      let elapsed = Date().timeIntervalSince(begin)
      let s = conn.status
      if until(s, elapsed) { return done(s) }
      if elapsed >= timeout { return done(nil) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: tick)
    }
    DispatchQueue.main.async(execute: tick)
  }

  /// Why the tunnel went down: the core's error written by the extension
  /// to the app group, else iOS's last disconnect error (iOS 16+).
  private func disconnectReason(_ m: NETunnelProviderManager, _ done: @escaping (String?) -> Void) {
    if let d = Self.sharedDefaults, let msg = d.string(forKey: "lastError"), !msg.isEmpty,
       d.double(forKey: "lastErrorAt") >= startedAt.timeIntervalSince1970 - 1 {
      return done(msg)
    }
    if #available(iOS 16.0, *) {
      m.connection.fetchLastDisconnectError { error in
        DispatchQueue.main.async { done(error.map { Self.describe($0) }) }
      }
    } else {
      done(nil)
    }
  }

  // MARK: - Helpers

  static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

  static func describe(_ error: Error) -> String {
    let ns = error as NSError
    let text = ns.localizedDescription
    if text.lowercased().contains("permission denied") {
      return "vpn permission denied: \(text)"
    }
    if ns.domain == NEVPNErrorDomain, let code = NEVPNError.Code(rawValue: ns.code) {
      switch code {
      case .configurationReadWriteFailed:
        return "vpn permission denied: \(text)"
      case .configurationInvalid, .configurationDisabled, .configurationStale:
        return "vpn configuration invalid: \(text)"
      default:
        break
      }
    }
    return text
  }

  static func fail(_ error: Error) -> String {
    json(["ok": false, "error": describe(error)])
  }

  static func idleStatus(lastError: String, state: String) -> String {
    json([
      "running": false, "listen": "", "up": 0, "down": 0, "conns": 0, "since": 0,
      "lastError": lastError, "state": state,
    ])
  }

  static func name(_ s: NEVPNStatus) -> String {
    switch s {
    case .invalid: return "invalid"
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .reasserting: return "reasserting"
    case .disconnecting: return "disconnecting"
    @unknown default: return "unknown"
    }
  }

  static func decode(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func json(_ obj: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: data, encoding: .utf8)
    else { return #"{"ok":false,"error":"encoding error"}"# }
    return s
  }
}
