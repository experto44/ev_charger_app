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
/// Reserved for the "premium is active" state, and nothing else. Kept warm
/// rather than yellow so it reads as metal against the dark card.
const _gold      = Color(0xFFE0B44C);

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

  Future<void> _buy(String productId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Resolve the product at tap time and retry the store once when it isn't
      // there. The card is built from whatever loaded at startup, and a startup
      // that failed to reach the store used to stay failed for the whole
      // session — so the card showed a fallback price and the tap could only
      // ever report an error, never open the purchase sheet.
      var product = _svc.productById(productId);
      if (product == null) {
        await _svc.loadProducts();
        product = _svc.productById(productId);
      }
      if (product == null) {
        _snack(AppStrings.storeUnavailable);
        return;
      }
      await _svc.buy(product);
    } catch (_) {
      _snack(AppStrings.purchaseFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Hidden store diagnostics (long-press the paywall title). Selectable so the
  /// text can be copied straight into a support reply.
  void _showDiagnostics() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _bgCard,
        title: const Text('Store diagnostics',
            style: TextStyle(color: _textPri, fontSize: 16)),
        content: SingleChildScrollView(
          child: SelectableText(
            _svc.diagnostics(),
            style: const TextStyle(
                color: _textPri, fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close', style: TextStyle(color: _teal)),
          ),
        ],
      ),
    );
  }

  /// User-triggered re-query after the store failed to answer.
  Future<void> _retryStore() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _svc.loadProducts();
    if (!mounted) return;
    setState(() => _busy = false);
    if (_svc.products.isEmpty) _snack(AppStrings.storeUnavailable);
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

          // Title. Long-press is a hidden diagnostics readout: it prints what
          // the store was asked for against what it actually returned. Invisible
          // to users, and it turns "the buy button does nothing" from a
          // guessing game into one screenshot.
          GestureDetector(
            onLongPress: _showDiagnostics,
            child: const Text(
              'GeoCharge Premium',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _textPri, fontSize: 24, fontWeight: FontWeight.w800),
            ),
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
              // Render ONLY the plans the store actually returned. A plan the
              // store doesn't know cannot be bought, so advertising it — with a
              // fallback price in the wrong currency, and a tap that can only
              // fail — is worse than not offering it. This is exactly how the
              // iOS yearly plan behaved: App Store Connect has no
              // `geocharge_premium_yearly`, so the card showed the Android GEL
              // list price and every tap dead-ended.
              final yearly  = _svc.yearlyProduct;
              final monthly = _svc.monthlyProduct;
              return Column(
                children: [
                  if (yearly != null)
                    _PlanCard(
                      title: AppStrings.planYearly,
                      price: _storePrice(yearly, _kYearlyFallback),
                      period: AppStrings.perYear,
                      // Both plans use the same neutral/dark style: tapping
                      // either opens the purchase sheet immediately, so a
                      // "selected" highlight on yearly would be misleading. The
                      // -17% ribbon stays — it's a value cue, not a selection
                      // indicator.
                      highlighted: false,
                      ribbon: '-17%',
                      onTap: () => _buy(PurchaseService.yearlyId),
                    ),
                  if (yearly != null && monthly != null)
                    const SizedBox(height: 14),
                  if (monthly != null)
                    _PlanCard(
                      title: AppStrings.planMonthly,
                      price: _storePrice(monthly, _kMonthlyFallback),
                      period: AppStrings.perMonth,
                      highlighted: false,
                      onTap: () => _buy(PurchaseService.monthlyId),
                    ),
                  // Nothing is for sale at all — say so and offer a retry rather
                  // than showing a paywall with no plans on it. When only some
                  // plans are missing the user simply sees the ones that work;
                  // the gap is for us to fix in the store, not for them to read
                  // about.
                  if (_svc.products.isEmpty) _StoreNotice(onRetry: _retryStore),
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

// ── Store-unavailable notice ──────────────────────────────────────────────────
/// Shown under the plan cards when the store returned no products. Without it
/// the paywall is indistinguishable from a working one — it renders the
/// hardcoded fallback prices and the free-trial badge over a store that cannot
/// sell anything.
class _StoreNotice extends StatelessWidget {
  const _StoreNotice({required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline_rounded, color: _textSec, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AppStrings.priceLoadFailed,
                  style: const TextStyle(
                      color: _textSec, fontSize: 12, height: 1.45),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onRetry,
              child: Text(
                AppStrings.tryAgain,
                style: const TextStyle(
                    color: _teal, fontSize: 13, fontWeight: FontWeight.w700),
              ),
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
              // Paid-for premium gets gold and a soft glow: it is the one tile
              // on the screen that should feel like something was bought. The
              // upsell state keeps the app's own teal so it reads as a link
              // rather than as a badge already earned.
              gradient: premium
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF2E2718), Color(0xFF1F1B12)],
                    )
                  : null,
              color: premium ? null : _bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: premium ? _gold : _teal.withValues(alpha: 0.5),
                width: premium ? 1.4 : 1,
              ),
              boxShadow: premium
                  ? [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.18),
                        blurRadius: 14,
                        spreadRadius: -2,
                      ),
                    ]
                  : null,
            ),
            child: Row(children: [
              Icon(
                premium
                    ? Icons.workspace_premium_rounded
                    : Icons.workspace_premium_outlined,
                color: premium ? _gold : _teal,
                size: premium ? 26 : 22,
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
                      style: AppStrings.font(TextStyle(
                          color: premium ? _gold : _textPri,
                          fontSize: premium ? 16 : 15,
                          letterSpacing: premium ? 0.3 : 0,
                          fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      premium
                          ? AppStrings.premiumActiveSubtitle
                          : AppStrings.premiumSubtitle,
                      style: AppStrings.font(TextStyle(
                          color: premium
                              ? _gold.withValues(alpha: 0.75)
                              : _textSec,
                          fontSize: 12)),
                    ),
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
