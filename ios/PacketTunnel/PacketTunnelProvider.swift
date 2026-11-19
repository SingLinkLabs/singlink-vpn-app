// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// SingLinkVPN packet tunnel: the device-wide VPN on iOS.
//
// The system creates a utun interface for this extension; every IP packet
// routed into it is relayed through the SingLink node by the Go core
// (SingLinkTunStart in Singlink.xcframework, built by `make -C core ios`).
//
// The app (ios/Runner/SingLinkVpnPlugin.swift) configures the tunnel with
// providerConfiguration = ["secretRef": "opaque reference"] and talks to it with
// sendProviderMessage: {"cmd":"status"|"probe"|"exitip", ...} -> core JSON.

import Foundation
import NetworkExtension
import os.log

private let appGroup = "group.com.singlinklabs.singlinkvpn"
private let log = OSLog(subsystem: "com.singlinklabs.singlinkvpn.tunnel", category: "tunnel")

/// Soft memory limit for the Go runtime. Packet tunnel extensions are killed
/// by the system at about 50 MB.
private let goMemoryLimit: Int64 = 30 << 20

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let coreQueue = DispatchQueue(label: "com.singlinklabs.singlinkvpn.tunnel.core")
  private var watchdog: DispatchSourceTimer?
  private var stopping = false
  private let lifecycleLock = NSLock()
  private var generation: UInt64 = 0

  private func beginSession(stopping: Bool) -> UInt64 {
    lifecycleLock.lock(); defer { lifecycleLock.unlock() }
    generation &+= 1
    self.stopping = stopping
    return generation
  }
  private func isCurrent(_ operation: UInt64) -> Bool {
    lifecycleLock.lock(); defer { lifecycleLock.unlock() }
    return !stopping && generation == operation
  }
  private func ownsGeneration(_ operation: UInt64) -> Bool {
    lifecycleLock.lock(); defer { lifecycleLock.unlock() }
    return generation == operation
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    SharedState.setLastError(nil)
    let operation = beginSession(stopping: false)
    let fail = { (message: String) in
      // Only a fixed category is public; the core's text can name the
      // server, so it stays private (redacted in the unified log).
      os_log("start failed (%{public}@): %{private}@", log: log, type: .error,
             Self.errorCategory(message), message)
      SharedState.setLastError(message)
      completionHandler(TunnelError(message))
    }

    guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
      let reference = proto.providerConfiguration?["secretRef"] as? String,
      let stored = try? CredentialKeychain.read(reference),
      let bytes = stored.data(using: .utf8),
      let credential = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      credential["version"] as? Int == 1,
      let link = credential["link"] as? String, link.hasPrefix("singlink://"),
      let acknowledged = credential["acknowledgedWarnings"] as? [String]
    else { return fail("protected credentials unavailable; open the app to migrate or re-import") }
    // OS Settings can start this extension without the Dart UI. Apply the same
    // consent check against the exact protected credential here as well.
    let parsed = Core.decode(Core.withCString(link) { Core.take(SingLinkParseLink($0)) })
    let warnings: [String]
    if parsed["warnings"] == nil || parsed["warnings"] is NSNull { warnings = [] }
    else if let known = parsed["warnings"] as? [String] { warnings = known }
    else { return fail("unknown profile security warning") }
    guard parsed["ok"] as? Bool == true, warnings == acknowledged
    else { return fail("profile security warnings require review in the app") }

    _ = Core.setMemoryLimit(goMemoryLimit)

    let host = Core.serverHost(link: link) ?? proto.serverAddress ?? ""
    let remote = Self.resolve(host: host) ?? "127.0.0.1"
    setTunnelNetworkSettings(Self.networkSettings(remote: remote)) { [weak self] error in
      guard let self else { return }
      guard self.isCurrent(operation) else {
        return completionHandler(TunnelError("connection cancelled"))
      }
      if let error {
        return fail("cannot apply tunnel settings: \(error.localizedDescription)")
      }
      guard let fd = Self.tunnelFileDescriptor() else {
        return fail("cannot find the utun file descriptor")
      }
      self.coreQueue.async {
        guard self.isCurrent(operation) else {
          return completionHandler(TunnelError("connection cancelled"))
        }
        let reply = Core.tunStart(fd: fd, config: [
          "link": link,
          "mtu": 1500,
          "dns": "1.1.1.1:53",
          "appleHeader": true,
        ])
        guard self.isCurrent(operation) else {
          // New core starts use this same queue, so this cleanup cannot stop a
          // later session which has not acquired the core yet.
          _ = Core.tunStop()
          return completionHandler(TunnelError("connection cancelled"))
        }
        if reply["ok"] as? Bool == true {
          os_log("tunnel started on fd %d", log: log, type: .info, fd)
          self.startWatchdog(operation: operation)
          completionHandler(nil)
        } else {
          fail(reply["error"] as? String ?? "core failed to start")
        }
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    os_log("stop, reason %ld", log: log, type: .info, reason.rawValue)
    let operation = beginSession(stopping: true)
    watchdog?.cancel()
    watchdog = nil
    coreQueue.async {
      if self.ownsGeneration(operation) { _ = Core.tunStop() }
      completionHandler()
    }
  }

  /// Commands from the app: `status`, `probe`, `exitip`, as plain text or
  /// JSON `{"cmd":"probe","url":"https://...","timeoutMs":8000}`. Replies
  /// with the core's JSON (UTF-8).
  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    var cmd = String(data: messageData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var args: [String: Any] = [:]
    if let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
      args = obj
      cmd = obj["cmd"] as? String ?? ""
    }
    let timeoutMs = Int32(clamping: (args["timeoutMs"] as? Int) ?? 8000)
    // Probe and exit IP block for up to timeoutMs; keep them off coreQueue
    // so a stop is never queued behind them.
    DispatchQueue.global(qos: .userInitiated).async {
      let reply: String
      switch cmd.lowercased() {
      case "status":
        reply = Core.statusRaw()
      case "probe":
        let url = args["url"] as? String ?? "https://www.gstatic.com/generate_204"
        reply = Core.probeRaw(url: url, timeoutMs: timeoutMs)
      case "exitip":
        reply = Core.exitIPRaw(timeoutMs: timeoutMs)
      default:
        reply = Core.encode(["ok": false, "error": "unknown command: \(cmd)"])
      }
      completionHandler?(reply.data(using: .utf8))
    }
  }

  // MARK: - Watchdog

  /// If the core stops by itself (node gone, token expired, utun closed),
  /// tear the VPN down so iOS does not show a connected VPN that relays
  /// nothing. The app reads the reason from the app group.
  private func startWatchdog(operation: UInt64) {
    let timer = DispatchSource.makeTimerSource(queue: coreQueue)
    timer.schedule(deadline: .now() + 5, repeating: 5)
    timer.setEventHandler { [weak self] in
      guard let self, self.isCurrent(operation) else { return }
      let status = Core.decode(Core.statusRaw())
      if status["running"] as? Bool == false {
        let reason = (status["lastError"] as? String).flatMap { $0.isEmpty ? nil : $0 }
          ?? "the tunnel stopped"
        os_log("core stopped (%{public}@): %{private}@", log: log, type: .error,
               Self.errorCategory(reason), reason)
        SharedState.setLastError(reason)
        self.watchdog?.cancel()
        self.watchdog = nil
        self.cancelTunnelWithError(TunnelError(reason))
      }
    }
    watchdog?.cancel()
    watchdog = timer
    timer.resume()
  }

  /// A fixed, non-identifying label for an error text, safe to log publicly.
  /// The text itself (which may contain a host, address or token detail) is
  /// only ever logged as private.
  static func errorCategory(_ message: String) -> String {
    let m = message.lowercased()
    if m.contains("cancel") { return "cancelled" }
    if m.contains("protected credential") { return "credentials-unavailable" }
    if m.contains("security warning") { return "warning-review-required" }
    if m.contains("tunnel settings") { return "network-settings" }
    if m.contains("utun") || m.contains("tun descriptor") { return "tun-descriptor" }
    if m.contains("expired") || m.contains("token") { return "token" }
    if m.contains("reject") || m.contains("handshake") || m.contains("key mismatch") { return "handshake" }
    if m.contains("reach node") || m.contains("dial") || m.contains("timeout") || m.contains("refused") {
      return "node-unreachable"
    }
    if m.contains("tunnel stopped") { return "tunnel-stopped" }
    return "core-error"
  }

  // MARK: - Network settings

  static func networkSettings(remote: String) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remote)

    let v4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
    v4.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = v4

    let v6 = NEIPv6Settings(addresses: ["fd66:6c69:6e6b::1"], networkPrefixLengths: [126])
    v6.includedRoutes = [NEIPv6Route.default()]
    settings.ipv6Settings = v6

    // The core answers DNS on port 53 of any address (over TCP through the
    // node), so the resolver only has to be inside the tunnel.
    let dns = NEDNSSettings(servers: ["172.19.0.2"])
    dns.matchDomains = [""]
    settings.dnsSettings = dns

    settings.mtu = 1500
    return settings
  }

  /// tunnelRemoteAddress must be an IP address; the link may name a host.
  static func resolve(host: String) -> String? {
    if host.isEmpty { return nil }
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
    defer { freeaddrinfo(res) }
    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buf,
                      socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
    return String(cString: buf)
  }

  /// The utun socket NetworkExtension opened for this provider. Scans the
  /// descriptor table for a kernel-control socket whose interface name
  /// starts with "utun" (the approach of WireGuard for iOS).
  static func tunnelFileDescriptor() -> Int32? {
    var name = [CChar](repeating: 0, count: Int(SINGLINK_IFNAMSIZ))
    for fd: Int32 in 0...1024 {
      var len = socklen_t(name.count)
      if getsockopt(fd, SINGLINK_SYSPROTO_CONTROL, SINGLINK_UTUN_OPT_IFNAME, &name, &len) == 0,
         String(cString: name).hasPrefix("utun") {
        return fd
      }
    }
    return nil
  }
}

struct TunnelError: LocalizedError {
  init(_ message: String) { self.message = message }
  let message: String
  var errorDescription: String? { message }
}

/// Last error of the tunnel, shared with the app through the app group.
enum SharedState {
  static func setLastError(_ message: String?) {
    guard let defaults = UserDefaults(suiteName: appGroup) else { return }
    if let message {
      defaults.set(message, forKey: "lastError")
      defaults.set(Date().timeIntervalSince1970, forKey: "lastErrorAt")
    } else {
      defaults.removeObject(forKey: "lastError")
      defaults.removeObject(forKey: "lastErrorAt")
    }
  }
}

/// Thin Swift layer over the C ABI of libsinglink. Every call returns a
/// malloc'd JSON string that must be released with SingLinkFree.
enum Core {
  static func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
    guard let p else { return #"{"ok":false,"error":"core returned NULL"}"# }
    defer { SingLinkFree(p) }
    return String(cString: p)
  }

  static func withCString<T>(_ s: String, _ body: (UnsafeMutablePointer<CChar>) -> T) -> T {
    let c = strdup(s)!
    defer { free(c) }
    return body(c)
  }

  static func decode(_ raw: String) -> [String: Any] {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return ["ok": false, "error": "malformed core reply"] }
    return obj
  }

  static func encode(_ obj: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: data, encoding: .utf8)
    else { return #"{"ok":false,"error":"encoding error"}"# }
    return s
  }

  static func setMemoryLimit(_ bytes: Int64) -> [String: Any] {
    decode(take(SingLinkSetMemoryLimit(bytes)))
  }

  /// Host part of the link's server ("host:port", "[v6]:port").
  static func serverHost(link: String) -> String? {
    let reply = decode(withCString(link) { take(SingLinkParseLink($0)) })
    guard let profile = reply["profile"] as? [String: Any],
          let server = profile["server"] as? String, !server.isEmpty
    else { return nil }
    if server.hasPrefix("["), let end = server.firstIndex(of: "]") {
      return String(server[server.index(after: server.startIndex)..<end])
    }
    if let colon = server.lastIndex(of: ":"), server.firstIndex(of: ":") == colon {
      return String(server[..<colon])
    }
    return server
  }

  static func tunStart(fd: Int32, config: [String: Any]) -> [String: Any] {
    decode(withCString(encode(config)) { take(SingLinkTunStart(fd, $0)) })
  }

  static func tunStop() -> [String: Any] { decode(take(SingLinkTunStop())) }

  static func statusRaw() -> String { take(SingLinkStatus()) }

  static func probeRaw(url: String, timeoutMs: Int32) -> String {
    withCString(url) { take(SingLinkProbe($0, timeoutMs)) }
  }

  static func exitIPRaw(timeoutMs: Int32) -> String { take(SingLinkExitIP(timeoutMs)) }
}
