import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight English/Georgian string table — no Flutter intl, just static
/// getters that switch on [isGeorgian]. Language choice is persisted in
/// SharedPreferences and broadcast via [notifier] so screens can rebuild.
///
/// Scope is intentionally limited to the Profile screen, Route Planner, the
/// station detail subtitle and the auth success/error messages. Map UI,
/// station names and filter chips are left untranslated.
class AppStrings {
  AppStrings._();

  static const _prefsKey = 'app_language_georgian';

  /// `true` once a language change happens, letting [ValueListenableBuilder]s
  /// rebuild without any global state-management package.
  static final ValueNotifier<bool> notifier = ValueNotifier<bool>(false);

  static bool get isGeorgian => notifier.value;

  /// Load the saved preference. Call once during app startup (before runApp).
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    notifier.value = p.getBool(_prefsKey) ?? false;
  }

  /// Switch language and persist the choice.
  static Future<void> setGeorgian(bool value) async {
    if (notifier.value != value) { notifier.value = value; }
    final p = await SharedPreferences.getInstance();
    await p.setBool(_prefsKey, value);
  }

  // ── Georgian font helpers ──────────────────────────────────────────────────
  /// Returns [base] with the Noto Sans Georgian face applied when Georgian is
  /// active. Use for one-off styles (e.g. SnackBars, which sit outside the
  /// screen subtree and so don't inherit [wrap]'s DefaultTextStyle).
  static TextStyle font([TextStyle? base]) => isGeorgian
      ? GoogleFonts.notoSansGeorgian(textStyle: base)
      : (base ?? const TextStyle());

  /// Wraps a subtree so every descendant [Text] that doesn't set its own
  /// fontFamily renders with Noto Sans Georgian while Georgian is active.
  /// Applied only to the localized screens, never the map UI.
  static Widget wrap(Widget child) => isGeorgian
      ? DefaultTextStyle.merge(
          style: GoogleFonts.notoSansGeorgian(),
          child: child,
        )
      : child;

  // ── Profile ────────────────────────────────────────────────────────────────
  static String get myProfile => isGeorgian ? 'ჩემი პროფილი' : 'My Profile';
  static String get email => isGeorgian ? 'ელ-ფოსტა' : 'Email';
  static String get verified => isGeorgian ? 'დადასტურებული' : 'Verified';
  static String get unverified => isGeorgian ? 'დაუდასტურებელი' : 'Unverified';
  static String get phoneNumber =>
      isGeorgian ? 'ტელეფონის ნომერი' : 'Phone Number';
  static String get save => isGeorgian ? 'შენახვა' : 'Save';
  static String get savedExclaim => isGeorgian ? 'შენახულია!' : 'Saved!';
  static String get signOut => isGeorgian ? 'გამოსვლა' : 'Sign Out';
  static String get carModel => isGeorgian ? 'მანქანის მოდელი' : 'Car Model';
  static String get myConnector => isGeorgian ? 'ჩემი კონექტორი' : 'My Connector';
  static String get maxRange => isGeorgian ? 'მაქს. გარბენი' : 'Max Range';
  static String get vehicleDriverInfo =>
      isGeorgian ? 'მანქანის ინფო' : 'Vehicle & Driver Info';
  static String get connectorHint => isGeorgian
      ? 'გამოიყენება როგორც ნაგულისხმევი ფილტრი რუკაზე'
      : 'Used as your default filter on the map';
  static String get maxRangeFull =>
      isGeorgian ? 'მაქს. გარბენი 100%-ზე' : 'Max Range at 100% Battery';
  static String get privacyPolicy =>
      isGeorgian ? 'კონფიდენციალურობის პოლიტიკა' : 'Privacy Policy';
  static String get privacyNotice => isGeorgian
      ? 'ნომრის შენახვით თქვენ ეთანხმებით GeoCharge-ისგან სერვისის განახლებების მიღებას. '
      : 'By saving your number you agree to receive service updates from GeoCharge. ';
  static String get invalidPhone => isGeorgian
      ? 'შეიყვანეთ სწორი ქართული მობილურის ნომერი'
      : 'Please enter a valid Georgian mobile number (9 digits)';

  // ── Auth success/error messages ─────────────────────────────────────────────
  static String get phoneSaved =>
      isGeorgian ? 'ნომერი შენახულია!' : 'Phone number saved!';
  static String get phoneSaveError =>
      isGeorgian ? 'შეცდომა ნომრის შენახვისას' : 'Error saving phone number';
  static String get verificationEmailSent => isGeorgian
      ? 'დადასტურების წერილი გაიგზავნა'
      : 'Verification email sent';

  // ── Route planner ────────────────────────────────────────────────────────────
  static String get from => isGeorgian ? 'საიდან' : 'From';
  static String get to => isGeorgian ? 'სად' : 'To';
  static String get stopN => isGeorgian ? 'გაჩერება' : 'Stop';
  static String get battery => isGeorgian ? 'ბატარეა' : 'Battery';
  static String get currentBattery =>
      isGeorgian ? 'ბატარეა' : 'CURRENT BATTERY';
  static String get distance => isGeorgian ? 'მანძილი' : 'Distance';
  static String get arrival => isGeorgian ? 'ჩასვლა' : 'Arrival';
  static String get stops => isGeorgian ? 'გაჩერება' : 'Stops';
  static String get uTurnRequired => isGeorgian
      ? 'საპირისპირო მხარეს — მობრუნება საჭიროა'
      : 'U-turn required — charger is on opposite side';
  static String get openInGoogleMaps =>
      isGeorgian ? 'Google Maps-ში გახსნა' : 'Open in Google Maps';
  static String get addStop =>
      isGeorgian ? 'გაჩერების დამატება' : 'Add stop';

  // ── Premium / subscriptions ──────────────────────────────────────────────
  static String get getPremium =>
      isGeorgian ? 'გახდი Premium' : 'Get Premium';
  static String get premiumActive => 'Premium ✓';
  static String get premiumSubtitle => isGeorgian
      ? 'რეკლამების გარეშე — 7 დღე უფასოდ'
      : 'Remove ads — 7-day free trial';

  // ── Station detail ─────────────────────────────────────────────────────────
  static String get providerLastCheck => isGeorgian
      ? 'პროვაიდერის ბოლო შემოწმება — არა რეალურ დროში'
      : "Provider's last server check — not real-time";

  // ── Paywall ──────────────────────────────────────────────────────────────
  static String get paywallSubtitle => isGeorgian
      ? 'უფასო 7 დღე, შემდეგ აირჩიე გეგმა'
      : '7 days free, then choose a plan';
  static String get benefitNoAds =>
      isGeorgian ? 'რეკლამების გარეშე' : 'Ad-free';
  static String get benefitFullAccess => isGeorgian
      ? 'სრული წვდომა ყველა ფუნქციაზე'
      : 'Full access to all features';
  static String get benefitSupport =>
      isGeorgian ? 'მხარდაჭერა გუნდისთვის' : 'Support the team';
  static String get planYearly => isGeorgian ? 'წლიური' : 'Yearly';
  static String get planMonthly => isGeorgian ? 'ყოველთვიური' : 'Monthly';
  static String get perYear => isGeorgian ? '/წელი' : '/yr';
  static String get perMonth => isGeorgian ? '/თვე' : '/mo';
  static String get freeTrialBadge => isGeorgian ? '7 დღე უფასოდ' : '7 days free';
  static String get continueFree => isGeorgian
      ? 'გააგრძელე რეკლამებით უფასოდ'
      : 'Continue free with ads';
  static String get restorePurchases =>
      isGeorgian ? 'შესყიდვების აღდგენა' : 'Restore purchases';
  static String get storeUnavailable => isGeorgian
      ? 'მაღაზია მიუწვდომელია — სცადეთ მოგვიანებით'
      : 'Store unavailable — please try again later';
  static String get purchaseFailed =>
      isGeorgian ? 'შესყიდვა ვერ მოხერხდა' : 'Purchase failed';
  static String get noActiveSubscription => isGeorgian
      ? 'აქტიური გამოწერა ვერ მოიძებნა'
      : 'No active subscription found';
}
