import 'package:flutter/material.dart';

/// Brand palette.
class Brand {
  static const primary = Color(0xFF10B981); // emerald-500
  static const accent = Color(0xFF14B8A6); // teal-500
  static const deep = Color(0xFF047857); // emerald-700, readable on light bg
  static const danger = Color(0xFFE5484D);

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, accent],
  );
}

/// Colours for the three protection states, per brightness.
class StatusPalette {
  const StatusPalette._(this.unprotected, this.connecting, this.protected);

  final Color unprotected;
  final Color connecting;
  final Color protected;

  static StatusPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  static const _light = StatusPalette._(
    Color(0xFFD14343),
    Color(0xFF0D9488),
    Color(0xFF059669),
  );
  static const _dark = StatusPalette._(
    Color(0xFFF07A7A),
    Color(0xFF2DD4BF),
    Color(0xFF34D399),
  );
}

/// Used for CJK text and flag emoji when the primary font lacks the glyphs.
/// On macOS these name the system fonts; tests load stand-ins under the same
/// names.
const fontFallback = ['PingFang HK', 'Apple Color Emoji'];

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: Brand.primary,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      ).copyWith(
        primary: dark ? Brand.primary : Brand.deep,
        secondary: Brand.accent,
        error: Brand.danger,
        surface: dark ? const Color(0xFF0A1210) : const Color(0xFFF3F6F5),
        onSurface: dark ? const Color(0xFFE6EFEC) : const Color(0xFF0F1A17),
        onSurfaceVariant: dark
            ? const Color(0xFF8FA39C)
            : const Color(0xFF5B6B66),
        surfaceContainerLow: dark ? const Color(0xFF121C19) : Colors.white,
        surfaceContainer: dark
            ? const Color(0xFF17231F)
            : const Color(0xFFEAF0EE),
        surfaceContainerHigh: dark
            ? const Color(0xFF1C2925)
            : const Color(0xFFE2E9E6),
        outlineVariant: dark
            ? const Color(0xFF22302C)
            : const Color(0xFFDCE4E1),
      );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    fontFamilyFallback: fontFallback,
  );

  return base.copyWith(
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: true,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
  );
}
