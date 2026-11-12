/// Turns the core's English error strings into short Traditional Chinese
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

const msgExpired = '帳號已到期，請續費或更新伺服器';
const msgRevoked = '帳號已被停用，請聯絡客服或更新伺服器';
const msgNotYetValid = '裝置時間不正確，請校正系統時間後再試';
const msgCapDenied = '你的方案不支援此連線方式，請升級方案或更新伺服器';
const msgTooManyConns = '同時使用的裝置過多，請先在其他裝置中斷連線';
const msgUnreachable = '無法連線到伺服器，請換一個地區再試';
const msgRejected = '伺服器拒絕連線，請確認裝置時間正確或更新伺服器';
const msgTimeout = '連線逾時，請檢查網絡或換一個地區再試';
const msgPortInUse = '本機埠已被其他程式佔用，請在「設定 → 進階」更換埠號';
const msgCoreMissing = '找不到星連VPN 核心元件，請重新安裝 App';
const msgBadLink = '無法辨識此伺服器連結，請確認已完整複製';
const msgDropped = '連線已中斷，請重新連線';
const msgGeneric = '連線失敗，請稍後再試或換一個地區';
const msgVpnPermission = '需要允許新增 VPN 設定';
const msgVpnUnsupported = '此裝置無法建立 VPN（模擬器不支援），請在 iPhone 上使用';

// Order matters: the core may wrap one error in another
// ("cannot reach node: ... token expired"), so the most specific wins.
const _table = <(String, String)>[
  // Device-wide VPN (iOS Network Extension): fixed prefixes from the app.
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
    '無法設定系統代理，請在系統設定手動設定 SOCKS 127.0.0.1:$port';
