import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const _seed = Color(0xFF6B7B3A); // Olive cuisine

  static ThemeData _buildTheme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: const CardThemeData(
        elevation: 1,
        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
      ),
    );
  }

  static ThemeData get light => _buildTheme(Brightness.light);
  static ThemeData get dark => _buildTheme(Brightness.dark);
}
