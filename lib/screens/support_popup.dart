import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import 'paywall_screen.dart';

// Map-screen theme palette (mirrors main.dart so the popup matches the app).
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);

/// Friendly, localized daily Support/Premium prompt for free-tier users.
///
/// The primary button opens the subscription (paywall) screen; the secondary
/// button just dismisses. Eligibility (non-premium) and the once-per-24h
/// frequency gating live at the call site (see `_maybeShowSupportPopup` in
/// MapScreen) — this widget is purely presentational.
Future<void> showSupportPopup(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (_) => const _SupportPopup(),
  );
}

class _SupportPopup extends StatelessWidget {
  const _SupportPopup();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Container(
        decoration: BoxDecoration(
          color: _bgCard,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _bgSurface),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 10)),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Lightning badge
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: _emerald.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                border: Border.all(color: _emerald, width: 2),
              ),
              child: const Icon(Icons.bolt_rounded, color: _emerald, size: 38),
            ),
            const SizedBox(height: 18),

            // Title
            Text(
              AppStrings.supportTitle,
              textAlign: TextAlign.center,
              style: AppStrings.font(const TextStyle(
                color: _textPri, fontSize: 19, fontWeight: FontWeight.w800, height: 1.3)),
            ),
            const SizedBox(height: 12),

            // Body
            Text(
              AppStrings.supportBody,
              textAlign: TextAlign.center,
              style: AppStrings.font(const TextStyle(
                color: _textSec, fontSize: 13.5, height: 1.5)),
            ),
            const SizedBox(height: 22),

            // Primary — Go Ad-Free → subscription (paywall) screen.
            GestureDetector(
              onTap: () {
                // Capture the navigator before popping so the push runs on a
                // still-valid NavigatorState (the dialog context deactivates on pop).
                final nav = Navigator.of(context);
                nav.pop();
                nav.push(MaterialPageRoute(builder: (_) => const PaywallScreen()));
              },
              child: Container(
                width: double.infinity,
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _emerald,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 4)),
                  ],
                ),
                child: Text(
                  AppStrings.supportGoAdFree,
                  textAlign: TextAlign.center,
                  style: AppStrings.font(const TextStyle(
                    color: Colors.black, fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
            const SizedBox(height: 6),

            // Secondary — dismiss (keep watching ads).
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                AppStrings.supportWatchAds,
                textAlign: TextAlign.center,
                style: AppStrings.font(const TextStyle(
                  color: _textSec, fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
