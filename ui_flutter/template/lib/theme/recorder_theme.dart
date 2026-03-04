import "package:flutter/foundation.dart";
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
      surfaceContainerHighest: RecorderLightColors.surface1,
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          borderSide: BorderSide(color: RecorderLightColors.border0),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          ),
          side: BorderSide(color: RecorderLightColors.border0),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
        ),
        side: BorderSide(color: RecorderLightColors.border0),
        backgroundColor: RecorderLightColors.surface0,
        selectedColor: RecorderLightColors.accentContainer,
        labelStyle: TextStyle(color: RecorderLightColors.text1),
        secondaryLabelStyle: TextStyle(color: RecorderLightColors.text0),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        minVerticalPadding: 8,
      ),
      dividerTheme: DividerThemeData(
        color: RecorderLightColors.border0,
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: RecorderLightColors.accentContainer,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        indicatorColor: RecorderLightColors.accentContainer,
        selectedIconTheme: IconThemeData(color: RecorderLightColors.accent1),
      ),
      tooltipTheme: TooltipThemeData(
        excludeFromSemantics: defaultTargetPlatform == TargetPlatform.windows,
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
      surfaceContainerHighest: RecorderDarkColors.surface1,
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          borderSide: BorderSide(color: RecorderDarkColors.border0),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
          ),
          side: BorderSide(color: RecorderDarkColors.border0),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RecorderTokens.radiusM),
        ),
        side: BorderSide(color: RecorderDarkColors.border0),
        backgroundColor: RecorderDarkColors.surface0,
        selectedColor: RecorderDarkColors.accentContainer,
        labelStyle: TextStyle(color: RecorderDarkColors.text1),
        secondaryLabelStyle: TextStyle(color: RecorderDarkColors.text0),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        minVerticalPadding: 8,
      ),
      dividerTheme: DividerThemeData(
        color: RecorderDarkColors.border0,
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: RecorderDarkColors.accentContainer,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        indicatorColor: RecorderDarkColors.accentContainer,
        selectedIconTheme: IconThemeData(color: RecorderDarkColors.accent0),
      ),
      tooltipTheme: TooltipThemeData(
        excludeFromSemantics: defaultTargetPlatform == TargetPlatform.windows,
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
