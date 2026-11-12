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
      expectLoc('香港 01', '🇭🇰', 'Hong Kong');
      expectLoc('Hong Kong 2', '🇭🇰', 'Hong Kong');
      expectLoc('HK01', '🇭🇰', 'Hong Kong');
      expectLoc('日本 03', '🇯🇵', 'Japan');
      expectLoc('東京', '🇯🇵', 'Tokyo');
      expectLoc('日本 東京 02', '🇯🇵', 'Tokyo');
      expectLoc('Tokyo-2', '🇯🇵', 'Tokyo');
      expectLoc('新加坡', '🇸🇬', 'Singapore');
      expectLoc('Singapore 1', '🇸🇬', 'Singapore');
      expectLoc('台灣 家寬', '🇹🇼', 'Taiwan');
      expectLoc('台北 1', '🇹🇼', 'Taipei');
      expectLoc('美國 洛杉磯', '🇺🇸', 'Los Angeles');
      expectLoc('US 1', '🇺🇸', 'United States');
      expectLoc('Los Angeles', '🇺🇸', 'Los Angeles');
      expectLoc('英國', '🇬🇧', 'United Kingdom');
      expectLoc('London 01', '🇬🇧', 'London');
      expectLoc('德國 法蘭克福', '🇩🇪', 'Frankfurt');
      expectLoc('Germany', '🇩🇪', 'Germany');
      expectLoc('韓國', '🇰🇷', 'South Korea');
      expectLoc('首爾 02', '🇰🇷', 'Seoul');
      expectLoc('Seoul', '🇰🇷', 'Seoul');
    });

    test('unknown falls back to globe and raw name', () {
      final l = locationFor('SingLink local demo node');
      expect(l.flag, '🌐');
      expect(l.city, 'SingLink local demo node');
      expect(l.known, isFalse);
      // Short codes only match whole words.
      expect(locationFor('demo node').known, isFalse);
      expect(locationFor('Atlanta').known, isFalse);
      expect(locationFor('  ').city, 'Unnamed server');
    });

    test('flagEmoji', () {
      expect(flagEmoji('hk'), '🇭🇰');
      expect(flagEmoji('XYZ'), '🌐');
    });
  });

  group('friendly errors', () {
    test('core error strings map to friendly messages', () {
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
      expect(
        friendlyError(
          'cannot reach node: singlink: node rejected the credentials (check the device clock, then renew the link)',
        ).message,
        msgRejected,
      );
      expect(
        friendlyError('singlink: bad server key in link').message,
        msgBadLink,
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
        "Couldn't set the system proxy. Set SOCKS 127.0.0.1:1080 manually in System Settings.",
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
