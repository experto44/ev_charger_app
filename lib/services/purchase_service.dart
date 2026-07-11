import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
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

  /// Initialise premium state and (in the background) the store connection.
  /// Call once during app startup, before `runApp`. Only the cached-flag
  /// restore is awaited — it's a local SharedPreferences read, so it returns
  /// instantly and gives the ad layer a correct [isPremium] to gate on. The
  /// store connection is deferred to [_connectStore] and run unawaited, because
  /// binding to Play Billing can hang for many seconds (or forever) when Play
  /// Services/Play Store is slow to respond. Blocking `main()` on it froze the
  /// whole Android launch on the splash screen — this keeps launch instant and
  /// lets billing/products settle in the background.
  Future<void> init() async {
    // Restore the cached flag first so the UI never flashes the wrong state and
    // the ad layer has a correct premium value from the very first frame.
    final prefs = await SharedPreferences.getInstance();
    isPremium.value = prefs.getBool(_prefsKey) ?? false;
    // Everything below can touch the network / Play Billing and must never
    // delay first paint — run it detached from the startup await chain.
    unawaited(_connectStore());
  }

  /// Connect to the store, subscribe to purchase updates, load products, and
  /// reconcile the authoritative premium state. Runs in the background (see
  /// [init]); [isAvailable] is bounded by a timeout so a hung Play Billing
  /// bind can never wedge the flow.
  Future<void> _connectStore() async {
    // Connect to the store (bounded — a stuck Play Billing bind resolves to
    // "unavailable" instead of hanging indefinitely).
    bool available = false;
    try {
      available = await _iap
          .isAvailable()
          .timeout(const Duration(seconds: 8), onTimeout: () => false);
    } catch (_) {
      available = false;
    }
    storeAvailable.value = available;
    if (!available) return;

    // Listen BEFORE querying so we never miss a restored/owned purchase that
    // the platform replays on connection.
    _sub = _iap.purchaseStream.listen(
      _onPurchaseUpdates,
      onDone: () => _sub?.cancel(),
      onError: (_) {/* transient stream error — ignore, next event recovers */},
    );

    // Load product details for the paywall.
    await loadProducts();

    // Establish the authoritative premium state.
    //   • Signed in  → the user's Firestore document is the source of truth, so
    //     premium follows the account across devices (read it, don't trust the
    //     device cache or the local Play account).
    //   • Anonymous  → no account to consult; fall back to the store-based
    //     reconciliation that clears a stale cached flag.
    //   Both run unawaited so they never block; the cached flag drives the UI
    //   instantly and is corrected a moment later.
    if (FirebaseAuth.instance.currentUser != null) {
      unawaited(syncPremiumFromFirestore());
    } else if (isPremium.value) {
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
          // a store-confirmed owned subscription. The store (StoreKit / Play
          // Billing) only reports these statuses AFTER it has verified the
          // transaction itself, so the status is the entitlement signal — we
          // must NOT gate the grant on the local receipt string. On iOS in
          // particular the App Store receipt (serverVerificationData) is often
          // empty on a fresh sandbox install when the first `.purchased` event
          // arrives; gating on it there silently drops a real purchase and the
          // paying user is never credited (App Store review 2.1(b)).
          if (_productIds.contains(purchase.productID)) {
            _ownedSeen = true; // store confirms an active owned subscription
            await _grantPremium();
            // Persist to the signed-in user's account so premium follows the
            // user, not the device.
            await _persistPremiumToFirestore(purchase);
            // Record a revenue event for the admin panel's financial analytics.
            // ONLY for a genuinely new purchase — a `restored` event replays on
            // every launch for an owned subscription, so recording it too would
            // inflate revenue. Deduped by the store transaction id regardless.
            if (purchase.status == PurchaseStatus.purchased) {
              await _recordPurchaseEvent(purchase);
            }
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

  // ── Per-account persistence (Firestore) ────────────────────────────────────
  /// Save the entitlement to the signed-in user's Firestore document
  /// (`users/{uid}.isPremium` + `purchaseToken`) so premium is tied to the
  /// account, not the device. No-op when signed out — the purchase still grants
  /// locally and will be persisted on the next login sync / stream replay.
  Future<void> _persistPremiumToFirestore(PurchaseDetails purchase) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await _firestore.collection('users').doc(uid).set({
        'isPremium':        true,
        'purchaseToken':    purchase.verificationData.serverVerificationData,
        'premiumUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // Offline / Firestore error — premium is still granted locally and will
      // re-persist on the next purchase-stream replay or login sync.
    }
  }

  // ── Revenue events (Firestore `purchases` collection) ──────────────────────
  /// Write one revenue record per completed purchase so the admin panel can
  /// build financial analytics (gross/net, split by plan and platform). The
  /// document id is the store transaction id, making the write idempotent — a
  /// replayed/retried transaction updates the same row instead of double-
  /// counting. Best-effort and never blocks the purchase flow.
  ///
  /// The gross amount + currency come from the store's own [ProductDetails]
  /// (localized, correct per storefront — e.g. GEL on Android, USD on the iOS
  /// App Store in Georgia). When product details are unavailable we fall back to
  /// the list prices so a row is still recorded, just approximate.
  Future<void> _recordPurchaseEvent(PurchaseDetails purchase) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return; // anonymous purchase — no account to attribute it to

    final plan     = purchase.productID == yearlyId ? 'yearly' : 'monthly';
    final platform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'other');
    final product  = _productById(purchase.productID);
    final gross    = (product != null && product.rawPrice > 0)
        ? product.rawPrice
        : (plan == 'yearly' ? 9.99 : 1.0); // GEL list-price fallback
    final currency = product?.currencyCode ?? 'GEL';

    // Store transaction id is globally unique per purchase → dedupe key.
    final docId = purchase.purchaseID?.isNotEmpty == true
        ? purchase.purchaseID!
        : '${uid}_${DateTime.now().millisecondsSinceEpoch}';

    try {
      await _firestore.collection('purchases').doc(docId).set({
        'uid':       uid,
        'plan':      plan,
        'platform':  platform,
        'gross':     gross,
        'currency':  currency,
        'productId': purchase.productID,
        'type':      'new',
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Mirror the resolved plan/price onto the user doc for convenience.
      await _firestore.collection('users').doc(uid).set({
        'plan':          plan,
        'pricePaid':     gross,
        'priceCurrency': currency,
      }, SetOptions(merge: true));
    } catch (_) {
      // Offline / Firestore error — analytics is best-effort; the purchase
      // itself already succeeded. The row is simply lost (no retry queue).
    }
  }

  /// Read the signed-in user's premium flag from Firestore and apply it locally.
  /// Firestore is the per-account source of truth, so this runs on login (and at
  /// startup for an already-signed-in user). Sets premium true OR false to match
  /// the account — clearing any premium the previous user left cached on this
  /// device. No-op when signed out.
  Future<void> syncPremiumFromFirestore() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      final premium = doc.data()?['isPremium'] == true;
      // Account premium must not be revoked by the store-based reconcile (the
      // purchase may live on a different Play account / device).
      if (premium) _ownedSeen = true;
      isPremium.value = premium;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, premium);
    } catch (_) {
      // Firestore unreachable — keep whatever local state we already have.
    }
  }

  /// Clear the locally cached premium flag. Called on logout so the next user on
  /// this device never inherits the previous account's premium state. The
  /// account's Firestore record is left untouched (premium belongs to that user).
  Future<void> clearLocalPremium() async {
    _ownedSeen = false;
    isPremium.value = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, false);
  }

  /// Cancel the purchase-stream subscription. Call from the app root's dispose.
  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
