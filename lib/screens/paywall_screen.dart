import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_strings.dart';
import '../services/purchase_service.dart';
import '../utils/responsive.dart';

// Apple's standard auto-renewable subscription EULA (used as Terms of Use) and
// the app's privacy policy — both must be reachable from the paywall.
const _kTermsUrl   = 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/';
const _kPrivacyUrl = 'https://experto44.github.io/ev_charger_app/privacy-policy.html';

// ── Palette ───────────────────────────────────────────────────────────────────
const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _teal      = Color(0xFF1DE9B6);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);

/// Hardcoded fallback prices, used whenever the live store price is unavailable
/// (product not loaded, offline, or the store returns 0 / an invalid amount).
/// These are amount-only; the plan card appends the period, so the rendered
/// fallback reads "1 ₾/თვე" (monthly) and "9.99 ₾/წელი" (yearly).
const _kMonthlyFallback = '1 ₾';
const _kYearlyFallback  = '9.99 ₾';

/// Returns the store's own localized, correctly-formatted price string for the
/// user's storefront — e.g. "₾1.00" on the Georgian Play Store, "$0.49" on the
/// iOS App Store (Georgia is billed in USD). Using the store string instead of a
/// hand-built "₾"-suffixed number keeps the currency symbol right on every
/// platform and territory. Falls back to [fallback] only when the product hasn't
/// loaded (null) or the store reports an unusable price (≤ 0 / non-finite).
String _storePrice(ProductDetails? p, String fallback) {
  if (p == null) return fallback;
  final s = p.price.trim(); // localized, e.g. "$0.49" or "₾1.00"
  if (s.isEmpty || p.rawPrice <= 0 || !p.rawPrice.isFinite) return fallback;
  return s;
}

class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  final _svc = PurchaseService.I;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Refresh product details if the paywall is opened before they loaded.
    if (_svc.products.isEmpty) {
      _svc.loadProducts();
    }
    // Close automatically the moment premium is granted.
    _svc.isPremium.addListener(_onPremiumChanged);
  }

  @override
  void dispose() {
    _svc.isPremium.removeListener(_onPremiumChanged);
    super.dispose();
  }

  void _onPremiumChanged() {
    if (_svc.isPremium.value && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _buy(ProductDetails? product) async {
    if (product == null || _busy) {
      if (product == null) _snack(AppStrings.storeUnavailable);
      return;
    }
    setState(() => _busy = true);
    try {
      await _svc.buy(product);
    } catch (_) {
      _snack(AppStrings.purchaseFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _svc.restorePurchases();
    if (mounted) {
      setState(() => _busy = false);
      if (!_svc.isPremium.value) {
        _snack(AppStrings.noActiveSubscription);
      }
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: AppStrings.font()),
      backgroundColor: _bgCard,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      // Respect the app language: Noto Sans Georgian face when Georgian is
      // active, the default face otherwise. The white default colour is kept in
      // both cases so descendant Text without an explicit colour stays readable.
      body: DefaultTextStyle.merge(
        style: AppStrings.font(const TextStyle(color: _textPri)),
        child: SafeArea(
          child: CenteredConstrained(
            maxWidth: 500,
            child: Stack(
              children: [
                _content(),
                if (_busy)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x99000000),
                      child: Center(
                        child: CircularProgressIndicator(color: _teal),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Close button
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: _textSec, size: 24),
              onPressed: () => Navigator.of(context).pop(false),
            ),
          ),
          const SizedBox(height: 4),

          // Crown badge
          Center(
            child: Container(
              width: 76, height: 76,
              decoration: BoxDecoration(
                color: _bgCard,
                shape: BoxShape.circle,
                border: Border.all(color: _teal, width: 2),
                boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 14)],
              ),
              child: const Icon(Icons.workspace_premium_rounded,
                  color: _teal, size: 40),
            ),
          ),
          const SizedBox(height: 18),

          // Title
          const Text(
            'GeoCharge Premium',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _textPri, fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),

          // Subtitle
          Text(
            AppStrings.paywallSubtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _textSec, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 22),

          // Benefits
          _Benefit(AppStrings.benefitNoAds),
          _Benefit(AppStrings.benefitFullAccess),
          _Benefit(AppStrings.benefitSupport),
          const SizedBox(height: 22),

          // Plan cards — rebuild as store prices arrive.
          ValueListenableBuilder<bool>(
            valueListenable: _svc.loadingProducts,
            builder: (context, loading, __) {
              if (loading && _svc.products.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator(color: _teal)),
                );
              }
              return Column(
                children: [
                  _PlanCard(
                    title: AppStrings.planYearly,
                    price: _storePrice(_svc.yearlyProduct, _kYearlyFallback),
                    period: AppStrings.perYear,
                    // Both plans use the same neutral/dark style: tapping either
                    // opens the Play purchase sheet immediately, so a "selected"
                    // highlight on yearly would be misleading. The -17% ribbon
                    // stays — it's a value cue, not a selection indicator.
                    highlighted: false,
                    ribbon: '-17%',
                    onTap: () => _buy(_svc.yearlyProduct),
                  ),
                  const SizedBox(height: 14),
                  _PlanCard(
                    title: AppStrings.planMonthly,
                    price: _storePrice(_svc.monthlyProduct, _kMonthlyFallback),
                    period: AppStrings.perMonth,
                    highlighted: false,
                    onTap: () => _buy(_svc.monthlyProduct),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 22),

          // Continue free (with ads) — just dismiss.
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              AppStrings.continueFree,
              style: const TextStyle(
                color: _textSec, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),

          // Restore purchases
          TextButton(
            onPressed: _restore,
            child: Text(
              AppStrings.restorePurchases,
              style: const TextStyle(color: _teal, fontSize: 13),
            ),
          ),

          const SizedBox(height: 8),
          // Auto-renewable subscription disclosure + legal links (Guideline 3.1.2).
          Text(
            AppStrings.autoRenewDisclosure,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _textSec, fontSize: 11, height: 1.45),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _LegalLink(label: 'termsOfUse', url: _kTermsUrl),
              Text('   ·   ',
                  style: TextStyle(
                      color: _textSec.withValues(alpha: 0.6), fontSize: 11)),
              const _LegalLink(label: 'privacyPolicy', url: _kPrivacyUrl),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Legal link (Terms of Use / Privacy Policy) ────────────────────────────────
class _LegalLink extends StatelessWidget {
  const _LegalLink({required this.label, required this.url});
  final String label; // 'termsOfUse' | 'privacyPolicy'
  final String url;

  @override
  Widget build(BuildContext context) {
    final text =
        label == 'termsOfUse' ? AppStrings.termsOfUse : AppStrings.privacyPolicy;
    return GestureDetector(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Text(
        text,
        style: const TextStyle(
          color: _textSec,
          fontSize: 11,
          decoration: TextDecoration.underline,
          decorationColor: _textSec,
        ),
      ),
    );
  }
}

/// Reusable upgrade entry point for Settings / Profile. Shows a tappable
/// "Get Premium" row that opens the paywall, or a non-tappable "Premium ✓"
/// row once the user is subscribed. Hides nothing itself — it always renders
/// the correct state and rebuilds when [PurchaseService.isPremium] changes.
class PremiumEntryTile extends StatelessWidget {
  const PremiumEntryTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PurchaseService.I.isPremium,
      builder: (context, premium, __) {
        return GestureDetector(
          onTap: premium
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PaywallScreen()),
                  ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: _bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: _teal.withValues(alpha: premium ? 0.9 : 0.5)),
            ),
            child: Row(children: [
              Icon(
                premium
                    ? Icons.workspace_premium_rounded
                    : Icons.workspace_premium_outlined,
                color: _teal, size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      premium
                          ? AppStrings.premiumActive
                          : AppStrings.getPremium,
                      style: AppStrings.font(const TextStyle(
                          color: _textPri,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                    ),
                    if (!premium) ...[
                      const SizedBox(height: 2),
                      Text(
                        AppStrings.premiumSubtitle,
                        style: AppStrings.font(const TextStyle(
                            color: _textSec, fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ),
              if (!premium)
                const Icon(Icons.chevron_right_rounded,
                    color: _textSec, size: 22),
            ]),
          ),
        );
      },
    );
  }
}

// ── Benefit row ─────────────────────────────────────────────────────────────
class _Benefit extends StatelessWidget {
  const _Benefit(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        const Icon(Icons.check_circle_rounded, color: _teal, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: _textPri, fontSize: 14)),
        ),
      ]),
    );
  }
}

// ── Plan card ─────────────────────────────────────────────────────────────────
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.title,
    required this.price,
    required this.period,
    required this.highlighted,
    required this.onTap,
    this.ribbon,
  });

  final String  title;
  final String  price;
  final String  period;
  final bool    highlighted;
  final String? ribbon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: highlighted ? _teal.withValues(alpha: 0.10) : _bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: highlighted ? _teal : _bgSurface,
            width: highlighted ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(title,
                        style: const TextStyle(
                            color: _textPri,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    if (ribbon != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: _teal,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(ribbon!,
                            style: const TextStyle(
                                color: Colors.black,
                                fontSize: 11,
                                fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 6),
                  // 7-day free trial badge
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _teal.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(AppStrings.freeTrialBadge,
                        style: const TextStyle(
                            color: _teal,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Price
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(price,
                    style: const TextStyle(
                        color: _textPri,
                        fontSize: 20,
                        fontWeight: FontWeight.w800)),
                Text(period,
                    style: const TextStyle(color: _textSec, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
