import "package:flutter/material.dart";

import "tokens.dart";

class RecorderTheme {
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: RecorderLightColors.accent0,
      brightness: Brightness.light,
    ).copyWith(
      primary: RecorderLightColors.accent0,
      onPrimary: Colors.white,
      primaryContainer: RecorderLightColors.accentContainer,
      onPrimaryContainer: RecorderLightColors.text0,
      secondary: RecorderLightColors.accent0,
      onSecondary: Colors.white,
      error: RecorderLightColors.danger,
      onError: Colors.white,
      errorContainer: RecorderLightColors.errorContainer,
      onErrorContainer: RecorderLightColors.text0,
      surface: RecorderLightColors.surface0,
      onSurface: RecorderLightColors.text0,
      surfaceVariant: RecorderLightColors.surface1,
      onSurfaceVariant: RecorderLightColors.text1,
      outline: RecorderLightColors.border0,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: RecorderLightColors.bg1,
      textTheme: _textTheme(isDark: false),
      cardTheme: CardThemeData(
        color: RecorderLightColors.surface0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          side: BorderSide(color: RecorderLightColors.border0),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: RecorderLightColors.surface1,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          borderSide: BorderSide(color: RecorderLightColors.border0),
        ),
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: RecorderDarkColors.accent0,
      brightness: Brightness.dark,
    ).copyWith(
      primary: RecorderDarkColors.accent0,
      onPrimary: Colors.white,
      primaryContainer: RecorderDarkColors.accentContainer,
      onPrimaryContainer: RecorderDarkColors.text0,
      secondary: RecorderDarkColors.accent0,
      onSecondary: Colors.white,
      error: RecorderDarkColors.danger,
      onError: Colors.white,
      errorContainer: RecorderDarkColors.errorContainer,
      onErrorContainer: RecorderDarkColors.text0,
      surface: RecorderDarkColors.surface0,
      onSurface: RecorderDarkColors.text0,
      surfaceVariant: RecorderDarkColors.surface1,
      onSurfaceVariant: RecorderDarkColors.text1,
      outline: RecorderDarkColors.border0,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: RecorderDarkColors.bg1,
      textTheme: _textTheme(isDark: true),
      cardTheme: CardThemeData(
        color: RecorderDarkColors.surface0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          side: BorderSide(color: RecorderDarkColors.border0),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: RecorderDarkColors.surface1,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          borderSide: BorderSide(color: RecorderDarkColors.border0),
        ),
      ),
    );
  }

  static TextTheme _textTheme({required bool isDark}) {
    final c0 = isDark ? RecorderDarkColors.text0 : RecorderLightColors.text0;
    final c1 = isDark ? RecorderDarkColors.text1 : RecorderLightColors.text1;
    return TextTheme(
      titleLarge: TextStyle(
        fontSize: 22,
        height: 28 / 22,
        fontWeight: FontWeight.w600,
        color: c0,
      ),
      titleMedium: TextStyle(
        fontSize: 18,
        height: 24 / 18,
        fontWeight: FontWeight.w600,
        color: c0,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        height: 22 / 15,
        color: c0,
      ),
      bodyMedium: TextStyle(
        fontSize: 15,
        height: 22 / 15,
        color: c1,
      ),
      labelMedium: TextStyle(
        fontSize: 13,
        height: 18 / 13,
        color: c1,
      ),
    );
  }
}
