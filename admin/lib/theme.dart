import 'package:flutter/material.dart';

/// GeoCharge brand accent (same emerald as the mobile app).
const Color kEmerald = Color(0xFF00C896);
const Color kBgDark = Color(0xFF141414);
const Color kBgCard = Color(0xFF1E1E1E);
const Color kBgSurface = Color(0xFF2A2A2A);
const Color kTextSec = Color(0xFF9E9E9E);

/// Hairline used for card and table borders — keeps the dark UI legible without
/// heavy elevation.
const Color kBorder = Color(0xFF303030);

/// Secondary accents used by the KPI strip / status chips.
const Color kBlue = Color(0xFF3B82F6);
const Color kAmber = Color(0xFFF59E0B);

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
      shape: RoundedRectangleBorder(
        side: BorderSide(color: kBorder),
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
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
    dividerColor: kBorder,
  );
}
