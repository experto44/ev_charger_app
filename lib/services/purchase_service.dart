import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Central in-app-subscription manager for GeoCharge.
///
/// Two subscription products (configured in Play Console / App Store Connect):
///   • [monthlyId] — ₾1 / month, 7-day free trial
///   • [yearlyId]  — ₾9.99 / year, 7-day free trial
///
/// The whole app listens to [isPremium] to decide whether to show ads and the
/// upgrade entry points. The flag is cached in SharedPreferences so the UI is
/// correct instantly on the next launch (before the store connection is ready),
/// then reconciled against the real purchase stream.
///
/// Singleton: use [PurchaseService.I].
class PurchaseService {
  PurchaseService._();
  static final PurchaseService I = PurchaseService._();

  // ── Product IDs (must match the store listings exactly) ────────────────────
  static const String monthlyId = 'geocharge_premium_monthly';
  static const String yearlyId  = 'geocharge_premium_yearly';
  static const Set<String> _productIds = {monthlyId, yearlyId};

  static const String _prefsKey = 'is_premium';

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// True while the user holds an active premium subscription. Listened to by
  /// the ad layer, settings and profile screens, and the paywall.
  final ValueNotifier<bool> isPremium = ValueNotifier<bool>(false);

  /// True once the underlying store (Play/App Store) connection is usable.
  final ValueNotifier<bool> storeAvailable = ValueNotifier<bool>(false);

  /// True while product details are being queried from the store.
  final ValueNotifier<bool> loadingProducts = ValueNotifier<bool>(false);

  /// Resolved product details from the store (empty until [loadProducts] runs).
  List<ProductDetails> products = const [];

  ProductDetails? get monthlyProduct => _productById(monthlyId);
  ProductDetails? get yearlyProduct  => _productById(yearlyId);

  ProductDetails? _productById(String id) {
    for (final p in products) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Initialise the store connection and start listening for purchase updates.
  /// Call once during app startup, before `runApp`. Safe to call when the
  /// store is unavailable (e.g. emulator without Play Services) — it just
  /// leaves [storeAvailable] false and the app runs on the cached flag.
  Future<void> init() async {
    // 1. Restore the cached flag first so the UI never flashes the wrong state.
    final prefs = await SharedPreferences.getInstance();
    isPremium.value = prefs.getBool(_prefsKey) ?? false;

    // 2. Connect to the store.
    bool available = false;
    try {
      available = await _iap.isAvailable();
    } catch (_) {
      available = false;
    }
    storeAvailable.value = available;
    if (!available) return;

    // 3. Listen BEFORE querying so we never miss a restored/owned purchase that
    //    the platform replays on connection.
    _sub = _iap.purchaseStream.listen(
      _onPurchaseUpdates,
      onDone: () => _sub?.cancel(),
      onError: (_) {/* transient stream error — ignore, next event recovers */},
    );

    // 4. Load product details for the paywall.
    await loadProducts();
  }

  /// Query (or re-query) the two subscription products from the store.
  Future<void> loadProducts() async {
    if (!storeAvailable.value) return;
    loadingProducts.value = true;
    try {
      final resp = await _iap.queryProductDetails(_productIds);
      products = resp.productDetails;
    } catch (_) {
      // Leave whatever we had; the paywall falls back to default prices.
    } finally {
      loadingProducts.value = false;
    }
  }

  /// Start the purchase flow for [product] (a subscription → non-consumable).
  /// The result arrives asynchronously on the purchase stream.
  Future<void> buy(ProductDetails product) async {
    final param = PurchaseParam(productDetails: product);
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  /// Ask the store to replay previously bought subscriptions. Results arrive on
  /// the purchase stream and flip [isPremium] via [_onPurchaseUpdates].
  Future<void> restorePurchases() async {
    if (!storeAvailable.value) return;
    try {
      await _iap.restorePurchases();
    } catch (_) {/* surfaced to the user by the caller's UI state */}
  }

  // ── Purchase stream handling ───────────────────────────────────────────────
  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          // Payment in progress — nothing to grant yet.
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          if (_productIds.contains(purchase.productID) &&
              await _isValid(purchase)) {
            await _grantPremium();
          }
          await _finish(purchase);
          break;

        case PurchaseStatus.error:
        case PurchaseStatus.canceled:
          // Don't change premium state; just acknowledge so the platform
          // doesn't keep re-delivering the pending transaction.
          await _finish(purchase);
          break;
      }
    }
  }

  /// Verify a purchase before granting entitlement. Here we do a lightweight
  /// local check (a non-empty verification token). For production-grade
  /// anti-fraud you would forward `purchase.verificationData.serverVerificationData`
  /// to your backend / Play Developer API and confirm it there.
  Future<bool> _isValid(PurchaseDetails purchase) async {
    final token = purchase.verificationData.serverVerificationData;
    return token.isNotEmpty;
  }

  /// Acknowledge/consume the transaction with the store so it is not redelivered.
  Future<void> _finish(PurchaseDetails purchase) async {
    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
  }

  Future<void> _grantPremium() async {
    isPremium.value = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, true);
  }

  /// Cancel the purchase-stream subscription. Call from the app root's dispose.
  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
