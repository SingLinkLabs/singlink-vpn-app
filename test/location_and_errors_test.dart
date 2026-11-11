import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/error_messages.dart';
import 'package:singlink_vpn/models/location.dart';
import 'package:singlink_vpn/ui/format.dart';

void main() {
  group('location from profile name', () {
    void expectLoc(String name, String flag, String city) {
      final l = locationFor(name);
      expect('${l.flag} ${l.city}', '$flag $city', reason: name);
    }

    test('common names', () {
      expectLoc('香港 01', '🇭🇰', '香港');
      expectLoc('Hong Kong 2', '🇭🇰', '香港');
      expectLoc('HK01', '🇭🇰', '香港');
      expectLoc('日本 03', '🇯🇵', '日本');
      expectLoc('東京', '🇯🇵', '東京');
      expectLoc('Tokyo-2', '🇯🇵', '東京');
      expectLoc('新加坡', '🇸🇬', '新加坡');
      expectLoc('Singapore 1', '🇸🇬', '新加坡');
      expectLoc('台灣 家寬', '🇹🇼', '台灣');
      expectLoc('台北 1', '🇹🇼', '台北');
      expectLoc('美國 洛杉磯', '🇺🇸', '洛杉磯');
      expectLoc('US 1', '🇺🇸', '美國');
      expectLoc('Los Angeles', '🇺🇸', '洛杉磯');
      expectLoc('英國', '🇬🇧', '英國');
      expectLoc('London 01', '🇬🇧', '倫敦');
      expectLoc('德國 法蘭克福', '🇩🇪', '法蘭克福');
      expectLoc('Germany', '🇩🇪', '德國');
      expectLoc('韓國', '🇰🇷', '韓國');
      expectLoc('首爾 02', '🇰🇷', '首爾');
      expectLoc('Seoul', '🇰🇷', '首爾');
    });

    test('unknown falls back to globe and raw name', () {
      final l = locationFor('SingLink 本機示範節點');
      expect(l.flag, '🌐');
      expect(l.city, 'SingLink 本機示範節點');
      expect(l.known, isFalse);
      // Short codes only match whole words.
      expect(locationFor('demo node').known, isFalse);
      expect(locationFor('Atlanta').known, isFalse);
      expect(locationFor('  ').city, '未命名伺服器');
    });

    test('flagEmoji', () {
      expect(flagEmoji('hk'), '🇭🇰');
      expect(flagEmoji('XYZ'), '🌐');
    });
  });

  group('friendly errors', () {
    test('core error strings map to Chinese messages', () {
      expect(friendlyError('singlink: token expired').message, msgExpired);
      expect(friendlyError('singlink: token revoked').message, msgRevoked);
      expect(
        friendlyError('singlink: capability not granted by token').message,
        msgCapDenied,
      );
      expect(
        friendlyError('singlink: too many concurrent connections').message,
        msgTooManyConns,
      );
      expect(
        friendlyError(
          'cannot reach node: dial tcp 1.2.3.4:443: connect: connection refused',
        ).message,
        msgUnreachable,
      );
      expect(
        friendlyError(
          'singlink: server closed the connection during handshake (rejected or not an SingLink server)',
        ).message,
        msgRejected,
      );
      expect(friendlyError('token not yet valid').message, msgNotYetValid);
      expect(
        friendlyError(
          'listen tcp 127.0.0.1:1080: bind: address already in use',
        ).message,
        msgPortInUse,
      );
      expect(friendlyError('core unavailable').message, msgCoreMissing);
    });

    test('most specific wins and detail is kept', () {
      final f = friendlyError('cannot reach node: singlink: token expired');
      expect(f.message, msgExpired);
      expect(f.detail, 'cannot reach node: singlink: token expired');
    });

    test('unknown error', () {
      expect(friendlyError('weird').message, msgGeneric);
      expect(friendlyLinkError('bad signature').message, msgBadLink);
      expect(
        systemProxyFailedMessage(1080),
        '無法設定系統代理，請在系統設定手動設定 SOCKS 127.0.0.1:1080',
      );
    });
  });

  group('formatting', () {
    test('timer is HH:MM:SS', () {
      expect(formatTimer(Duration.zero), '00:00:00');
      expect(formatTimer(const Duration(seconds: 65)), '00:01:05');
      expect(
        formatTimer(const Duration(hours: 1, minutes: 23, seconds: 45)),
        '01:23:45',
      );
      expect(formatTimer(const Duration(hours: 123, seconds: 1)), '123:00:01');
      expect(formatTimer(const Duration(seconds: -5)), '00:00:00');
    });

    test('bytes and speed', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1536), '1.50 KB');
      expect(formatBytes(15 * 1024 * 1024), '15.0 MB');
      expect(formatBytes(300 * 1024 * 1024), '300 MB');
      expect(formatRate(2048), '2.00 KB/s');
      expect(formatRateParts(1.25 * 1024 * 1024), ('1.25', 'MB/s'));
      expect(formatRateParts(512), ('512', 'B/s'));
      expect(formatRateParts(double.nan), ('0', 'B/s'));
    });
  });
}
