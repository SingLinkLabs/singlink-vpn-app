/// Maps a server's profile name (e.g. "Hong Kong 01", "Tokyo-2", "US LA 3") to
/// a country flag and an English display city, the way consumer VPN apps list locations.
library;

class ServerLocation {
  const ServerLocation({
    required this.flag,
    required this.city,
    required this.countryCode,
  });

  /// Emoji flag, or 🌐 when the name is not recognised.
  final String flag;

  /// English display name, or the raw profile name (server data).
  final String city;

  /// ISO 3166 alpha-2 code, empty when unknown.
  final String countryCode;

  bool get known => countryCode.isNotEmpty;

  @override
  String toString() => '$flag $city';
}

class _Rule {
  const _Rule(this.code, this.city, this.cjk, this.latin);
  final String code;
  final String city;

  /// Matched as substrings: Chinese node names from server links (Traditional
  /// and Simplified). Input data only, never shown in the UI.
  final List<String> cjk;

  /// Matched case-insensitively as whole words ("hk01" counts, "hkg" not).
  final List<String> latin;
}

// More specific entries (cities) come before their country.
// Chinese strings below are match keys only (server node names may be in
// Chinese); every displayed name is English.
const _rules = <_Rule>[
  _Rule('HK', 'Hong Kong', ['香港'], ['hong kong', 'hongkong', 'hk']),
  _Rule('JP', 'Tokyo', ['東京', '东京'], ['tokyo']),
  _Rule('JP', 'Osaka', ['大阪'], ['osaka']),
  _Rule('JP', 'Japan', ['日本'], ['japan', 'jp']),
  _Rule('SG', 'Singapore', ['新加坡', '獅城', '狮城'], ['singapore', 'sg']),
  _Rule('TW', 'Taipei', ['台北', '臺北'], ['taipei']),
  _Rule('TW', 'Taiwan', ['台灣', '臺灣', '台湾'], ['taiwan', 'tw']),
  _Rule('US', 'Los Angeles', ['洛杉磯', '洛杉矶'], ['los angeles', 'la']),
  _Rule('US', 'New York', ['紐約', '纽约'], ['new york', 'nyc']),
  _Rule('US', 'United States', ['美國', '美国'], ['united states', 'usa', 'us']),
  _Rule('GB', 'London', ['倫敦', '伦敦'], ['london']),
  _Rule('GB', 'United Kingdom', ['英國', '英国'], ['united kingdom', 'uk', 'gb']),
  _Rule('DE', 'Frankfurt', ['法蘭克福', '法兰克福'], ['frankfurt']),
  _Rule('DE', 'Germany', ['德國', '德国'], ['germany', 'de']),
  _Rule('KR', 'Seoul', ['首爾', '首尔', '漢城'], ['seoul']),
  _Rule('KR', 'South Korea', ['韓國', '韩国', '南韓'], ['korea', 'kr']),
];

final _latinPatterns = {
  for (final r in _rules)
    r: [
      for (final k in r.latin)
        RegExp(
          '(?<![a-z])${k.replaceAll(' ', r'[\s_-]*')}(?![a-z])',
          caseSensitive: false,
        ),
    ],
};

/// Regional-indicator flag for a two-letter country code.
String flagEmoji(String countryCode) {
  final cc = countryCode.toUpperCase();
  if (cc.length != 2) return '🌐';
  final a = cc.codeUnitAt(0), b = cc.codeUnitAt(1);
  if (a < 65 || a > 90 || b < 65 || b > 90) return '🌐';
  return String.fromCharCodes([0x1F1E6 + a - 65, 0x1F1E6 + b - 65]);
}

ServerLocation locationFor(String name) {
  final raw = name.trim();
  for (final r in _rules) {
    final hit =
        r.cjk.any(raw.contains) ||
        _latinPatterns[r]!.any((re) => re.hasMatch(raw));
    if (hit) {
      return ServerLocation(
        flag: flagEmoji(r.code),
        city: r.city,
        countryCode: r.code,
      );
    }
  }
  return ServerLocation(
    flag: '🌐',
    city: raw.isEmpty ? 'Unnamed server' : raw,
    countryCode: '',
  );
}
