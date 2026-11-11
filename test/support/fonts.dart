import 'dart:io';

import 'package:flutter/services.dart';

/// flutter_test renders every glyph as a box. For goldens the owner can read,
/// load real fonts: Roboto + Material Icons from the Flutter SDK cache, a CJK
/// font and the colour emoji font from macOS, under the family names the
/// theme uses (see `fontFallback` in lib/ui/theme.dart). Missing files are
/// skipped silently (the golden then just shows boxes).
Future<void> loadGoldenFonts() async {
  final sdk = _flutterRoot();
  final material = sdk == null
      ? null
      : '$sdk/bin/cache/artifacts/material_fonts';

  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var any = false;
    for (final p in paths) {
      final f = File(p);
      if (!f.existsSync()) continue;
      final bytes = f.readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      any = true;
    }
    if (any) await loader.load();
  }

  if (material != null) {
    await load('Roboto', [
      '$material/Roboto-Regular.ttf',
      '$material/Roboto-Medium.ttf',
      '$material/Roboto-Bold.ttf',
      '$material/Roboto-Black.ttf',
    ]);
    await load('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  }
  await load('PingFang HK', [
    _firstExisting([
      '/System/Library/Fonts/STHeiti Medium.ttc',
      '/System/Library/Fonts/Hiragino Sans GB.ttc',
      '/Library/Fonts/Arial Unicode.ttf',
    ]),
  ]);
  await load('Apple Color Emoji', [
    '/System/Library/Fonts/Apple Color Emoji.ttc',
  ]);
  await load('Menlo', ['/System/Library/Fonts/Menlo.ttc']);
}

String _firstExisting(List<String> paths) =>
    paths.firstWhere((p) => File(p).existsSync(), orElse: () => paths.first);

String? _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && Directory(env).existsSync()) return env;
  // flutter_tester lives in <root>/bin/cache/artifacts/engine/<platform>/.
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/bin/flutter').existsSync()) return dir.path;
    dir = dir.parent;
  }
  return null;
}
