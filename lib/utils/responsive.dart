import 'package:flutter/material.dart';

/// Centralised breakpoint logic so every screen (current and future) reacts to
/// width/orientation the same way. Use these helpers instead of hardcoding
/// pixel checks inline.
///
/// Breakpoints:
///  • Phone portrait            → narrow, single-column (unchanged layout)
///  • Phone landscape / <600dp  → same content, scaled, no overflow
///  • Tablet (shortestSide≥600) → two-panel layouts where it makes sense
class Responsive {
  Responsive._();

  /// True on tablets (and larger). Uses shortestSide so a tablet stays a
  /// "tablet" in both orientations.
  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.shortestSide >= 600;

  static bool isLandscape(BuildContext context) =>
      MediaQuery.of(context).orientation == Orientation.landscape;

  /// "Wide" = anything that benefits from a side-by-side / two-panel layout:
  /// every tablet, plus phones turned to landscape.
  static bool isWide(BuildContext context) =>
      isTablet(context) || isLandscape(context);

  /// Width for a horizontal station card in the bottom carousel.
  static double cardWidth(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (isTablet(context)) return width * 0.45;
    if (isLandscape(context)) return width * 0.35;
    return width * 0.72;
  }

  static int gridColumns(BuildContext context) {
    if (isTablet(context)) return 2;
    return 1;
  }

  /// Width of the left list/content panel in the two-panel map layout.
  /// Adapts to the screen so a narrow landscape phone never starves the map.
  static double sidePanelWidth(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return (width * 0.4).clamp(300.0, 380.0);
  }

  /// Max readable width for centred content (auth, settings, profile).
  /// 400 for narrow form screens, 600 for list/content screens.
  static double maxContentWidth(BuildContext context, {double cap = 600}) =>
      cap;

  /// Horizontal page padding that grows a little on wider screens so content
  /// isn't glued to the edges, without changing the phone-portrait look.
  static EdgeInsets pagePadding(
    BuildContext context, {
    double vertical = 0,
  }) {
    final width = MediaQuery.of(context).size.width;
    final h = width >= 600 ? 28.0 : 20.0;
    return EdgeInsets.symmetric(horizontal: h, vertical: vertical);
  }
}

/// Centres [child] and constrains it to [maxWidth] on wide screens, while
/// leaving phone-portrait untouched (the constraint simply never bites when the
/// screen is narrower than [maxWidth]). Drop this around the scrolling body of
/// any form/list screen to make it tablet-friendly in one line.
class CenteredConstrained extends StatelessWidget {
  const CenteredConstrained({
    super.key,
    required this.child,
    this.maxWidth = 600,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
