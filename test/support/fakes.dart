import 'dart:io';

import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/singlink_bindings.dart';
import 'package:singlink_vpn/core/singlink_service.dart';
import 'package:singlink_vpn/core/system_proxy.dart';
import 'package:singlink_vpn/models/core_status.dart';
import 'package:singlink_vpn/models/profile.dart';

/// In-memory stand-in for the protocol core.
class FakeCore implements VpnCore {
  FakeCore({this.available = true});

  @override
  final bool available;

  @override
  SingLinkLibLocation get location => SingLinkLibLocation(
    path: available ? '/fake/libsinglink.dylib' : null,
    searched: const [
      '/Applications/SingLinkVPN.app/Contents/Frameworks/libsinglink.dylib',
    ],
    errors: const [],
  );

  String? startError;
  bool running = false;
  int up = 0;
  int down = 0;
  String lastError = '';
  String exitIp = '203.0.113.7';
  int latency = 42;
  final calls = <String>[];

  @override
  Future<CoreVersion> version() async =>
      const CoreVersion('1.0.0-draft', 'SingLink/1');

  @override
  Future<ParseLinkResult> parseLink(String link) async {
    calls.add('parse');
    if (!link.startsWith('singlink://')) {
      return ParseLinkResult.failure('not a singlink link');
    }
    final name = link.split('#').last;
    return ParseLinkResult.fromJson(link, {
      'ok': true,
      'profile': {
        'name': name,
        'server': 'node.example.com:443',
        'transport': 'tls',
        'plan': 1,
        'expiresAt': 0,
        'caps': ['tcp'],
      },
    });
  }

  @override
  Future<OpResult> start({required String link, required String listen}) async {
    calls.add('start $listen');
    if (startError != null) return OpResult(false, startError!);
    running = true;
    return const OpResult(true);
  }

  @override
  Future<OpResult> stop() async {
    calls.add('stop');
    running = false;
    return const OpResult(true);
  }

  @override
  Future<CoreStatus> status() async => CoreStatus(
    running: running,
    listen: running ? '127.0.0.1:1080' : '',
    up: up,
    down: down,
    conns: running ? 3 : 0,
    since: null,
    lastError: lastError,
  );

  @override
  Future<ProbeResult> probe(String url, {int timeoutMs = 8000}) async =>
      ProbeResult(ok: true, status: 204, latencyMs: latency);

  @override
  Future<ExitIpResult> exitIP({int timeoutMs = 8000}) async =>
      ExitIpResult(ok: true, ip: exitIp);
}

/// Records networksetup invocations and answers from a scripted table.
/// Never runs a real process.
class FakeRunner implements ProcessRunner {
  FakeRunner({
    this.services =
        'An asterisk (*) denotes that a network service is disabled.\n'
        'Thunderbolt Bridge\nWi-Fi\n*Bluetooth PAN\nUSB 10/100/1000 LAN\n',
    Map<String, String>? socks,
  }) : socks = socks ?? {};

  String services;

  /// Service -> current `-getsocksfirewallproxy` output.
  final Map<String, String> socks;

  /// Commands (joined args) that should fail.
  final Set<String> failing = {};

  final List<List<String>> calls = [];

  static String socksOut(bool on, String server, int port, {int auth = 0}) =>
      'Enabled: ${on ? 'Yes' : 'No'}\nServer: $server\nPort: $port\n'
      'Authenticated Proxy Enabled: $auth\n';

  @override
  Future<RunResult> run(String executable, List<String> args) async {
    calls.add(args);
    if (executable != networksetup) return const RunResult(127, '', 'bad exe');
    final key = args.join(' ');
    if (failing.any(key.startsWith)) {
      return const RunResult(14, '', 'requires admin privileges');
    }
    switch (args.first) {
      case '-listallnetworkservices':
        return RunResult(0, services);
      case '-getsocksfirewallproxy':
        return RunResult(0, socks[args[1]] ?? socksOut(false, '', 0));
      case '-setsocksfirewallproxy':
        final prev = socks[args[1]] ?? socksOut(false, '', 0);
        final auth = prev.contains('Authenticated Proxy Enabled: 1') ? 1 : 0;
        socks[args[1]] = socksOut(
          true,
          args[2],
          int.parse(args[3]),
          auth: auth,
        );
        return const RunResult(0);
      case '-setsocksfirewallproxystate':
        final cur = SocksSetting.parse(
          socks[args[1]] ?? socksOut(false, '', 0),
        )!;
        socks[args[1]] = socksOut(
          args[2] == 'on',
          cur.server,
          cur.port,
          auth: cur.authenticated ? 1 : 0,
        );
        return const RunResult(0);
    }
    return const RunResult(1, '', 'unknown');
  }

  /// Only the commands that change something.
  List<String> get writes => [
    for (final c in calls)
      if (c.first.startsWith('-set')) c.join(' '),
  ];
}

/// AppStore without disk IO (file IO never completes inside testWidgets'
/// fake-async zone).
class MemoryStore extends AppStore {
  MemoryStore() : super(File('/nonexistent/state.json'));
  Map<String, dynamic>? saved;

  @override
  Future<AppState> load() async =>
      saved == null ? AppState() : AppState.fromJson(saved!);

  @override
  Future<void> save(AppState state) async => saved = state.toJson();
}
