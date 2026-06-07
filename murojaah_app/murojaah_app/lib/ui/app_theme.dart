import 'package:flutter/material.dart';

class AppColors {
  static const bg0 = Color(0xFF0B1410);
  static const bg1 = Color(0xFF0E1A14);
  static const bgTop = Color(0xFF12241B);
  static const ink = Color(0xFFECE6D6);
  static const muted = Color(0xFF8B958A);
  static const line = Color(0x1FE7D6B0);
  static const emerald = Color(0xFF2AA873);
  static const emeraldDeep = Color(0xFF0F7048);
  static const emeraldSoft = Color(0xFF3FC78C);
  static const gold = Color(0xFFC8A456);
  static const goldSoft = Color(0xFFE7CD8F);
  static const parch = Color(0xFFF4ECD8);
  static const parch2 = Color(0xFFEADFC4);
  static const parchInk = Color(0xFF2C2417);
  static const correct = Color(0xFF1C7A44);
  static const wrong = Color(0xFFB23A3A);
  static const wrongSoft = Color(0xFFE86A6A);
  static const waiting = Color(0xFFB3A684);
}

/// Set fontFamily names; if the .ttf assets aren't bundled (see pubspec),
/// Flutter falls back to the system font and Arabic still renders.
const String kArabicFont = 'Amiri';

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg0,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.emerald,
      secondary: AppColors.gold,
      surface: AppColors.bg1,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.bg1,
      contentTextStyle: TextStyle(color: AppColors.ink),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
