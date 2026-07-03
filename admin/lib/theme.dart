import 'package:flutter/material.dart';

/// GeoCharge brand accent (same emerald as the mobile app).
const Color kEmerald = Color(0xFF00C896);
const Color kBgDark = Color(0xFF1A1A1A);
const Color kBgCard = Color(0xFF252525);
const Color kBgSurface = Color(0xFF2E2E2E);
const Color kTextSec = Color(0xFF9E9E9E);

ThemeData buildAdminTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: kBgDark,
    colorScheme: const ColorScheme.dark(
      primary: kEmerald,
      surface: kBgCard,
      secondary: kEmerald,
    ),
    cardTheme: const CardThemeData(
      color: kBgCard,
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kBgSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      isDense: true,
    ),
    dividerColor: kBgSurface,
  );
}
