import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

// Map-screen theme palette (mirrors main.dart so the popup matches the app).
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);

/// Confirmation dialog shown right after the user arms a "Notify me!" charger
/// alert. Explains that the push may arrive with a small delay. Purely
/// presentational — the caller shows an interstitial ad once this closes.
Future<void> showChargerAlertPopup(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (_) => const _ChargerAlertPopup(),
  );
}

class _ChargerAlertPopup extends StatelessWidget {
  const _ChargerAlertPopup();

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
            // Bell badge
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: _emerald.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                border: Border.all(color: _emerald, width: 2),
              ),
              child: const Icon(Icons.notifications_active_rounded,
                  color: _emerald, size: 34),
            ),
            const SizedBox(height: 18),

            Text(
              AppStrings.alertPopupTitle,
              textAlign: TextAlign.center,
              style: AppStrings.font(const TextStyle(
                  color: _textPri, fontSize: 19, fontWeight: FontWeight.w800, height: 1.3)),
            ),
            const SizedBox(height: 12),

            Text(
              AppStrings.alertPopupBody,
              textAlign: TextAlign.center,
              style: AppStrings.font(const TextStyle(
                  color: _textSec, fontSize: 13.5, height: 1.5)),
            ),
            const SizedBox(height: 22),

            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
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
                  AppStrings.alertGotIt,
                  style: AppStrings.font(const TextStyle(
                      color: Colors.black, fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
