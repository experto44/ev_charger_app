import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../l10n/app_strings.dart';
import '../services/purchase_service.dart';
import '../utils/responsive.dart';

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

/// Formats a store [ProductDetails] into "<amount> ₾" using the live `rawPrice`
/// (so it tracks any future price change in Play Console). Whole amounts drop
/// the decimals: 1.0 → "1 ₾", 9.99 → "9.99 ₾". Falls back to [fallback] when the
/// product hasn't loaded (null) or the store reports an unusable price (≤ 0 or
/// non-finite), so the paywall never shows "0 ₾".
String _storePrice(ProductDetails? p, String fallback) {
  if (p == null) return fallback;
  final v = p.rawPrice;
  if (v <= 0 || !v.isFinite) return fallback;
  final amount =
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  return '$amount ₾';
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
      if (product == null) _snack('მაღაზია მიუწვდომელია — სცადეთ მოგვიანებით');
      return;
    }
    setState(() => _busy = true);
    try {
      await _svc.buy(product);
    } catch (_) {
      _snack('შესყიდვა ვერ მოხერხდა');
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
        _snack('აქტიური გამოწერა ვერ მოიძებნა');
      }
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.notoSansGeorgian()),
      backgroundColor: _bgCard,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      // Force the Georgian face for the whole paywall (Georgian-only screen).
      body: DefaultTextStyle.merge(
        style: GoogleFonts.notoSansGeorgian(color: _textPri),
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

          // Georgian subtitle
          const Text(
            'უფასო 7 დღე, შემდეგ აირჩიე გეგმა',
            textAlign: TextAlign.center,
            style: TextStyle(color: _textSec, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 22),

          // Benefits
          const _Benefit('რეკლამების გარეშე'),
          const _Benefit('სრული წვდომა ყველა ფუნქციაზე'),
          const _Benefit('მხარდაჭერა გუნდისთვის'),
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
                    title: 'წლიური',
                    price: _storePrice(_svc.yearlyProduct, _kYearlyFallback),
                    period: '/წელი',
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
                    title: 'ყოველთვიური',
                    price: _storePrice(_svc.monthlyProduct, _kMonthlyFallback),
                    period: '/თვე',
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
            child: const Text(
              'გააგრძელე რეკლამებით უფასოდ',
              style: TextStyle(
                color: _textSec, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),

          // Restore purchases
          TextButton(
            onPressed: _restore,
            child: const Text(
              'შესყიდვების აღდგენა',
              style: TextStyle(color: _teal, fontSize: 13),
            ),
          ),
        ],
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
                    child: const Text('7 დღე უფასოდ',
                        style: TextStyle(
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
