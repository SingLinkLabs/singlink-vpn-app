/// Display formatting helpers (pure functions, unit-tested).
library;

const _units = ['B', 'KB', 'MB', 'GB', 'TB'];

(String, String) _scale(num bytes) {
  var v = bytes.toDouble();
  if (v.isNaN || v < 0) v = 0;
  var i = 0;
  while (v >= 1024 && i < _units.length - 1) {
    v /= 1024;
    i++;
  }
  final digits = i == 0 || v >= 100 ? 0 : (v >= 10 ? 1 : 2);
  return (v.toStringAsFixed(digits), _units[i]);
}

/// `0 B`, `1.50 KB`, `15.0 MB`.
String formatBytes(num bytes) {
  final (v, u) = _scale(bytes);
  return '$v $u';
}

String formatRate(num bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

/// Value and unit separately, for the big speed figures: `('1.25', 'MB/s')`.
(String, String) formatRateParts(num bytesPerSecond) {
  final (v, u) = _scale(bytesPerSecond);
  return (v, '$u/s');
}

/// Connection timer, always `HH:MM:SS` (hours keep growing past 99).
String formatTimer(Duration d) {
  if (d.isNegative) d = Duration.zero;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:'
      '${two(d.inSeconds.remainder(60))}';
}

/// `2026-11-12`.
String formatDate(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

/// `14:03:22`.
String formatClock(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
