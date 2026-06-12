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

  /// Set true the moment the store replays/confirms an owned subscription for
  /// this session. Used by [_reconcileEntitlement] to tell "really owns premium"
  /// apart from "stale cached flag".
  bool _ownedSeen = false;

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

    // 5. Reconcile the cached entitlement against the store. The cached flag is
    //    only an instant-UI hint, NOT proof of an active subscription: a trial
    //    or sub that was later canceled/expired would otherwise keep premium
    //    (and suppress ads) forever. If we still think we're premium, ask the
    //    store to replay owned purchases and revoke if none come back.
    if (isPremium.value) {
      unawaited(_reconcileEntitlement());
    }
  }

  /// Confirm a cached `premium=true` really reflects an owned subscription.
  /// Triggers a silent restore and, if the store replays no owned purchase
  /// within a short window, downgrades to free and clears the cache. Conservative
  /// by design: only ever downgrades when the store is reachable and the restore
  /// request itself succeeds, so a paying user is never flipped to free on a
  /// transient/offline blip (they keep the cached premium until a clean check).
  Future<void> _reconcileEntitlement() async {
    if (!storeAvailable.value) return;
    _ownedSeen = false;
    try {
      await _iap.restorePurchases();
    } catch (_) {
      return; // store hiccup — keep the cached flag, re-check next launch
    }
    // Owned purchases replay on the purchase stream right after the request;
    // give them time to arrive before concluding nothing is owned.
    await Future<void>.delayed(const Duration(seconds: 8));
    if (!_ownedSeen) {
      isPremium.value = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, false);
    }
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
          // Payment in progress (e.g. the Play sheet is open). NOT a completed
          // transaction — never grant premium here. Dismissing the sheet without
          // paying resolves to canceled/error below, which also grants nothing.
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // The only paths that confer entitlement: a completed new purchase or
          // a store-confirmed owned subscription, and only after validation.
          if (_productIds.contains(purchase.productID) &&
              await _isValid(purchase)) {
            _ownedSeen = true; // store confirms an active owned subscription
            await _grantPremium();
          }
          await _finish(purchase);
          break;

        case PurchaseStatus.error:
        case PurchaseStatus.canceled:
          // User dismissed the sheet or the flow failed. Do NOT touch premium;
          // just acknowledge so the platform stops re-delivering the transaction.
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
