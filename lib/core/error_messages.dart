/// Turns the core's technical error strings into short, plain English
/// messages for people who do not know what a "handshake" is. The raw text is
/// kept as [FriendlyError.detail] for support.
library;

class FriendlyError {
  const FriendlyError(this.message, [this.detail = '']);

  /// What the user sees.
  final String message;

  /// The core's original error (may be empty).
  final String detail;

  @override
  String toString() => message;
}

const msgExpired = 'Your plan has expired. Renew it or update the server.';
const msgRevoked =
    'Your account has been suspended. Contact support or update the server.';
const msgNotYetValid =
    "Your device's clock is wrong. Correct the system time and try again.";
const msgCapDenied =
    "Your plan doesn't include this connection type. Upgrade your plan or update the server.";
const msgTooManyConns =
    'Too many devices are connected at once. Disconnect on another device first.';
const msgUnreachable = "Can't reach the server. Try another location.";
const msgRejected =
    'The server refused the connection. Check that your device time is correct, or update the server.';
const msgTimeout =
    'The connection timed out. Check your network or try another location.';
const msgPortInUse =
    'The local port is in use by another app. Change it in Settings → Advanced.';
const msgCoreMissing =
    "SingLinkVPN's core component is missing. Reinstall the app.";
const msgBadLink =
    "This server link isn't recognized. Make sure you copied all of it.";
const msgDropped = 'The connection dropped. Connect again.';
const msgGeneric =
    'Connection failed. Try again later or choose another location.';
const msgVpnPermission =
    'SingLinkVPN needs permission to add a VPN. Tap Connect again and choose Allow.';
const msgVpnUnsupported =
    "This device can't create a VPN (the simulator isn't supported). Use a real iPhone.";

/// Android name for the same message.
const msgVpnDenied = msgVpnPermission;

// Order matters: the core may wrap one error in another
// ("cannot reach node: ... token expired"), so the most specific wins.
const _table = <(String, String)>[
  // Device-wide VPN (Android VpnService, iOS Network Extension): fixed
  // prefixes from the platform code.
  ('vpn permission denied', msgVpnPermission),
  ('vpn unsupported', msgVpnUnsupported),
  ('token expired', msgExpired),
  ('token revoked', msgRevoked),
  ('token not yet valid', msgNotYetValid),
  ('capability not granted', msgCapDenied),
  ('too many concurrent connections', msgTooManyConns),
  ('node rejected the credentials', msgRejected),
  ('server closed the connection during handshake', msgRejected),
  ('malformed link', msgBadLink),
  ('in link', msgBadLink),
  ('cannot reach node', msgUnreachable),
  ('address already in use', msgPortInUse),
  ('core unavailable', msgCoreMissing),
  ('i/o timeout', msgTimeout),
  ('deadline exceeded', msgTimeout),
  ('timeout', msgTimeout),
  ('connection refused', msgUnreachable),
  ('no such host', msgUnreachable),
  ('network is unreachable', msgUnreachable),
];

FriendlyError friendlyError(String raw) {
  final detail = raw.trim();
  final lower = detail.toLowerCase();
  for (final (needle, message) in _table) {
    if (lower.contains(needle)) return FriendlyError(message, detail);
  }
  return FriendlyError(msgGeneric, detail);
}

/// For link import in Settings.
FriendlyError friendlyLinkError(String raw) {
  final f = friendlyError(raw);
  if (f.message != msgGeneric) return f;
  return FriendlyError(msgBadLink, raw.trim());
}

/// Shown when networksetup could not apply the system proxy.
String systemProxyFailedMessage(int port) =>
    "Couldn't set the system proxy. Set SOCKS 127.0.0.1:$port manually in System Settings.";
