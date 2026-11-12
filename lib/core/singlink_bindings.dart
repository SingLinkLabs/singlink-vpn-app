// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

// Raw Dart FFI bindings for the libsinglink C ABI (Go `-buildmode=c-shared`).
//
//   char* SingLinkVersion(void);
//   char* SingLinkParseLink(char* link);
//   char* SingLinkStart(char* configJSON);
//   char* SingLinkStop(void);
//   char* SingLinkStatus(void);
//   char* SingLinkProbe(char* url, int timeoutMs);
//   char* SingLinkExitIP(int timeoutMs);
//   void  SingLinkFree(char* p);
//   char* SingLinkTunStart(int fd, char* configJSON);   // app core only (mobile)
//   char* SingLinkTunStop(void);                        // app core only (mobile)
//
// Every char* returned is heap-allocated UTF-8 JSON owned by the core and must
// be released with SingLinkFree. Several calls block, so use these bindings
// from a background isolate (see singlink_service.dart), never from the UI.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _NoArgC = Pointer<Utf8> Function();
typedef _StrArgC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ProbeC = Pointer<Utf8> Function(Pointer<Utf8>, Int32);
typedef _ProbeDart = Pointer<Utf8> Function(Pointer<Utf8>, int);
typedef _IntArgC = Pointer<Utf8> Function(Int32);
typedef _IntArgDart = Pointer<Utf8> Function(int);
typedef _TunStartC = Pointer<Utf8> Function(Int32, Pointer<Utf8>);
typedef _TunStartDart = Pointer<Utf8> Function(int, Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class SingLinkBindings {
  /// Throws [ArgumentError] if any of the expected symbols is missing.
  SingLinkBindings(DynamicLibrary lib)
    : _version = lib.lookupFunction<_NoArgC, _NoArgC>('SingLinkVersion'),
      _parseLink = lib.lookupFunction<_StrArgC, _StrArgC>('SingLinkParseLink'),
      _start = lib.lookupFunction<_StrArgC, _StrArgC>('SingLinkStart'),
      _stop = lib.lookupFunction<_NoArgC, _NoArgC>('SingLinkStop'),
      _status = lib.lookupFunction<_NoArgC, _NoArgC>('SingLinkStatus'),
      _probe = lib.lookupFunction<_ProbeC, _ProbeDart>('SingLinkProbe'),
      _exitIP = lib.lookupFunction<_IntArgC, _IntArgDart>('SingLinkExitIP'),
      _free = lib.lookupFunction<_FreeC, _FreeDart>('SingLinkFree'),
      _tunStart = lib.providesSymbol('SingLinkTunStart')
          ? lib.lookupFunction<_TunStartC, _TunStartDart>('SingLinkTunStart')
          : null,
      _tunStop = lib.providesSymbol('SingLinkTunStop')
          ? lib.lookupFunction<_NoArgC, _NoArgC>('SingLinkTunStop')
          : null;

  /// Opens [path] (dlopen caches it, so re-opening per isolate is cheap).
  /// [processLibrary] means the core is statically linked into the app
  /// (iOS); a bare file name is resolved by the OS loader (Android).
  factory SingLinkBindings.open(String path) => SingLinkBindings(
    path == processLibrary
        ? DynamicLibrary.process()
        : DynamicLibrary.open(path),
  );

  final Pointer<Utf8> Function() _version;
  final Pointer<Utf8> Function(Pointer<Utf8>) _parseLink;
  final Pointer<Utf8> Function(Pointer<Utf8>) _start;
  final Pointer<Utf8> Function() _stop;
  final Pointer<Utf8> Function() _status;
  final Pointer<Utf8> Function(Pointer<Utf8>, int) _probe;
  final Pointer<Utf8> Function(int) _exitIP;
  final void Function(Pointer<Utf8>) _free;
  final Pointer<Utf8> Function(int, Pointer<Utf8>)? _tunStart;
  final Pointer<Utf8> Function()? _tunStop;

  /// Whether this build of the core supports device-wide VPN (TUN) mode.
  bool get hasTun => _tunStart != null && _tunStop != null;

  String version() => _take(_version());
  String status() => _take(_status());
  String stop() => _take(_stop());
  String parseLink(String link) => _withArg(link, _parseLink);
  String start(String configJson) => _withArg(configJson, _start);
  String exitIP(int timeoutMs) => _take(_exitIP(timeoutMs));

  String tunStart(int fd, String configJson) {
    final f = _tunStart;
    if (f == null) {
      return '{"ok":false,"error":"core built without TUN support"}';
    }
    return _withArg(configJson, (p) => f(fd, p));
  }

  String tunStop() {
    final f = _tunStop;
    if (f == null) {
      return '{"ok":false,"error":"core built without TUN support"}';
    }
    return _take(f());
  }

  String probe(String url, int timeoutMs) =>
      _withArg(url, (p) => _probe(p, timeoutMs));

  String _withArg(String s, Pointer<Utf8> Function(Pointer<Utf8>) fn) {
    final arg = s.toNativeUtf8();
    try {
      return _take(fn(arg));
    } finally {
      malloc.free(arg);
    }
  }

  /// Copies the core-owned string into Dart and frees it with SingLinkFree.
  String _take(Pointer<Utf8> p) {
    if (p == nullptr) return '{"ok":false,"error":"core returned NULL"}';
    try {
      return p.toDartString();
    } finally {
      _free(p);
    }
  }
}

/// Outcome of searching for and opening libsinglink.
class SingLinkLibLocation {
  const SingLinkLibLocation({
    required this.path,
    required this.searched,
    required this.errors,
  });

  /// Path that opened successfully, or null if none did.
  final String? path;

  /// Every candidate path tried, in order.
  final List<String> searched;

  /// dlopen / symbol errors for candidates that existed but failed to load.
  final List<String> errors;

  bool get found => path != null;

  /// The canonical place the packaged app expects the library.
  String get expectedPath => searched.isEmpty ? libFileName : searched.first;
}

/// Marker path for a core linked into the app binary itself (iOS).
const processLibrary = '<process>';

String get libFileName {
  if (Platform.isMacOS || Platform.isIOS) return 'libsinglink.dylib';
  if (Platform.isWindows) return 'singlink.dll';
  return 'libsinglink.so';
}

/// Candidate locations, in priority order (desktop). On Android the library
/// ships in the APK and is opened by name; on iOS it is linked statically.
///
/// Desktop order:
/// 1. the app bundle: `<App>.app/Contents/Frameworks/libsinglink.dylib`
/// 2. the `SINGLINK_LIB` environment variable (full path to the library)
/// 3. dev fallbacks: `../singlink-protocol/build/libsinglink.dylib` relative
///    to the working directory (the app project when using `flutter run`),
///    and `singlink-protocol/build/libsinglink.dylib` under every ancestor of
///    the executable (finds the sibling protocol repo from the build tree).
List<String> singLinkLibCandidates({
  String? executable,
  Map<String, String>? environment,
  String? workingDirectory,
}) {
  final sep = Platform.pathSeparator;
  final exe = File(executable ?? Platform.resolvedExecutable).absolute;
  final env = environment ?? Platform.environment;
  final cwd = workingDirectory ?? Directory.current.path;
  if (Platform.isAndroid) return [libFileName];
  if (Platform.isIOS) return [processLibrary];
  final name = libFileName;
  // The app's own core build (with TUN support) first, then the protocol
  // repo's plain build.
  final platformDir = Platform.isWindows ? 'windows' : 'macos';
  final appRel = 'core${sep}build$sep$platformDir$sep$name';
  final rel = 'singlink-protocol${sep}build$sep$name';
  final out = <String>[];

  void add(String p) {
    final norm = File(p).absolute.uri.normalizePath().toFilePath();
    if (!out.contains(norm)) out.add(norm);
  }

  // .../X.app/Contents/MacOS/exe -> .../X.app/Contents/Frameworks/lib
  if (Platform.isMacOS) {
    add('${exe.parent.parent.path}${sep}Frameworks$sep$name');
  } else {
    add('${exe.parent.path}$sep$name');
  }

  final fromEnv = env['SINGLINK_LIB'];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) add(fromEnv.trim());

  add('$cwd$sep$appRel');
  add('$cwd$sep..$sep$rel');

  var dir = exe.parent;
  for (var i = 0; i < 12; i++) {
    add('${dir.path}${sep}singlink-vpn-app$sep$appRel');
    add('${dir.path}$sep$rel');
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return out;
}

/// Tries each candidate until one opens and exposes every SingLink symbol.
/// Never throws.
SingLinkLibLocation locateSingLinkLib({List<String>? candidates}) {
  final searched = candidates ?? singLinkLibCandidates();
  final errors = <String>[];
  for (final p in searched) {
    final byName = p == processLibrary || !p.contains(Platform.pathSeparator);
    if (!byName && !File(p).existsSync()) continue;
    try {
      SingLinkBindings.open(p);
      return SingLinkLibLocation(path: p, searched: searched, errors: errors);
    } catch (e) {
      errors.add('$p: $e');
    }
  }
  return SingLinkLibLocation(path: null, searched: searched, errors: errors);
}
