import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'purchase_service.dart';

/// AdMob wrapper for the free tier. Every ad path is gated on
/// `PurchaseService.I.isPremium` — when the user is premium, NO ad is ever
/// requested, loaded, or shown.
///
/// ┌──────────────────────────────────────────────────────────────────────┐
/// │  TODO(admob): paste the real AdMob ad-unit IDs below.                   │
/// │  The AdMob *App ID* goes in android/app/src/main/AndroidManifest.xml    │
/// │  (meta-data com.google.android.gms.ads.APPLICATION_ID) and in           │
/// │  ios/Runner/Info.plist (GADApplicationIdentifier).                       │
/// │                                                                         │
/// │  While these unit IDs are empty, ad loading is disabled app-wide, so    │
/// │  the free tier simply shows no ads until the IDs are filled in.         │
/// └──────────────────────────────────────────────────────────────────────┘
// Production AdMob ad units, per platform (separate AdMob app per platform).
// iOS app id ca-app-pub-2323581212631140~3327603543 (GADApplicationIdentifier
// in ios/Runner/Info.plist); Android app id ~2516919486 (AndroidManifest.xml).
final String _kBannerAdUnitId = Platform.isIOS
    ? 'ca-app-pub-2323581212631140/6197309466'   // iOS banner
    : 'ca-app-pub-2323581212631140/6735366094';  // Android banner
final String _kInterstitialAdUnitId = Platform.isIOS
    ? 'ca-app-pub-2323581212631140/3758848388'   // iOS interstitial
    : 'ca-app-pub-2323581212631140/4959249997';  // Android interstitial

/// How often an interstitial may be shown, at most.
const Duration _kInterstitialMinGap = Duration(minutes: 2);

class AdService {
  AdService._();
  static final AdService I = AdService._();

  bool _initialized = false;
  InterstitialAd? _interstitial;
  DateTime _lastInterstitial = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get bannerConfigured       => _kBannerAdUnitId.isNotEmpty;
  static bool get interstitialConfigured => _kInterstitialAdUnitId.isNotEmpty;

  /// Ads are allowed only for non-premium users.
  bool get _adsAllowed => !PurchaseService.I.isPremium.value;

  /// Initialise the Mobile Ads SDK. No-op when no ad unit is configured (so the
  /// SDK isn't spun up needlessly) — call once at startup after PurchaseService.
  Future<void> init() async {
    if (_initialized) return;
    if (!bannerConfigured && !interstitialConfigured) return;
    try {
      await MobileAds.instance.initialize();
      _initialized = true;
      _preloadInterstitial();
    } catch (_) {
      // SDK init can fail on devices without Play Services — degrade silently.
    }
  }

  // ── Banner ─────────────────────────────────────────────────────────────────
  /// A bottom banner for the free tier, or `null` when ads shouldn't show
  /// (premium user, or no banner unit configured). Suitable for
  /// `Scaffold.bottomNavigationBar`.
  Widget? bottomBanner() {
    if (!_adsAllowed || !bannerConfigured || !_initialized) return null;
    return _AdBanner(adUnitId: _kBannerAdUnitId);
  }

  /// A banner for the top of the free-tier map screen (placed below the search
  /// bar). Same gating as [bottomBanner] — returns `null` for premium users, an
  /// unconfigured unit, or before the SDK is initialised — so it disappears the
  /// moment premium is granted. Loads its own [BannerAd] independently of the
  /// bottom banner.
  Widget? topBanner() {
    if (!_adsAllowed || !bannerConfigured || !_initialized) return null;
    return _AdBanner(adUnitId: _kBannerAdUnitId);
  }

  // ── Interstitial ─────────────────────────────────────────────────────────
  void _preloadInterstitial() {
    if (!interstitialConfigured || !_adsAllowed) return;
    InterstitialAd.load(
      adUnitId: _kInterstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _interstitial = ad,
        onAdFailedToLoad: (_) => _interstitial = null,
      ),
    );
  }

  /// Show an interstitial if one is ready, the user isn't premium, and enough
  /// time has passed since the last one. Always reloads for next time.
  void maybeShowInterstitial() {
    if (!_adsAllowed || !interstitialConfigured) return;
    final ad = _interstitial;
    if (ad == null) {
      _preloadInterstitial();
      return;
    }
    if (DateTime.now().difference(_lastInterstitial) < _kInterstitialMinGap) {
      return;
    }
    _lastInterstitial = DateTime.now();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _interstitial = null;
        _preloadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        ad.dispose();
        _interstitial = null;
        _preloadInterstitial();
      },
    );
    ad.show();
  }

  void dispose() {
    _interstitial?.dispose();
    _interstitial = null;
  }
}

/// Self-contained banner widget that loads its own [BannerAd] and cleans it up.
class _AdBanner extends StatefulWidget {
  const _AdBanner({required this.adUnitId});
  final String adUnitId;

  @override
  State<_AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<_AdBanner> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _ad = BannerAd(
      adUnitId: widget.adUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, _) {
          ad.dispose();
          if (mounted) setState(() => _loaded = false);
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!_loaded || ad == null) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
