import 'dart:ui' show PlatformDispatcher;

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

  /// Flips whenever the language changes, letting [ValueListenableBuilder]s
  /// rebuild without any global state-management package. Seeded by [load]
  /// before `runApp`, so this initial value is only a safe English fallback.
  static final ValueNotifier<bool> notifier = ValueNotifier<bool>(false);

  static bool get isGeorgian => notifier.value;

  /// `true` when the device itself is set to Georgian.
  ///
  /// Safe to read from [load]: that runs after `WidgetsFlutterBinding
  /// .ensureInitialized()`, so the platform locale is already resolved.
  static bool _deviceIsGeorgian() =>
      PlatformDispatcher.instance.locale.languageCode == 'ka';

  /// Load the saved preference. Call once during app startup (before runApp).
  ///
  /// First launch follows the device language: a Georgian phone opens in
  /// Georgian, everything else opens in English. English is the app's primary
  /// language — the map, station names and filters are English-only — and a
  /// fresh install on a non-Georgian device must reflect that. Users who picked
  /// a language explicitly keep it (setGeorgian persists the key), and the
  /// toggle in the profile screen stays available either way.
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    notifier.value = p.getBool(_prefsKey) ?? _deviceIsGeorgian();
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
  static String get deleteAccount =>
      isGeorgian ? 'ანგარიშის წაშლა' : 'Delete Account';
  static String get deleteAccountTitle =>
      isGeorgian ? 'ანგარიშის წაშლა?' : 'Delete account?';
  static String get deleteAccountBody => isGeorgian
      ? 'ეს სამუდამოდ წაშლის თქვენს ანგარიშს და ყველა მონაცემს. ქმედება შეუქცევადია.'
      : 'This permanently deletes your account and all of your data. This cannot be undone.';
  static String get cancel => isGeorgian ? 'გაუქმება' : 'Cancel';
  static String get delete => isGeorgian ? 'წაშლა' : 'Delete';
  static String get accountDeleted =>
      isGeorgian ? 'ანგარიში წაიშალა' : 'Account deleted';
  static String get reloginToDelete => isGeorgian
      ? 'უსაფრთხოებისთვის თავიდან შედით სისტემაში და სცადეთ წაშლა ხელახლა'
      : 'For security, please sign in again, then retry deleting your account';
  static String get deleteFailed =>
      isGeorgian ? 'წაშლა ვერ მოხერხდა' : 'Could not delete account';
  static String get carModel => isGeorgian ? 'მანქანის მოდელი' : 'Car Model';
  static String get myConnector => isGeorgian ? 'ჩემი კონექტორი' : 'My Connector';
  static String get maxRange => isGeorgian ? 'მაქს. გარბენი' : 'Max Range';
  static String get vehicleDriverInfo =>
      isGeorgian ? 'მანქანის ინფო' : 'Vehicle & Driver Info';
  static String get connectorHint => isGeorgian
      ? 'აირჩიეთ ერთი ან რამდენიმე — გამოიყენება როგორც ნაგულისხმევი ფილტრი რუკაზე'
      : 'Select one or more — used as your default filter on the map';
  static String get maxRangeFull =>
      isGeorgian ? 'მაქს. გარბენი 100%-ზე' : 'Max Range at 100% Battery';
  static String get minPowerTitle =>
      isGeorgian ? 'მინიმალური სიმძლავრე' : 'Minimum Charger Power';
  static String get minPowerHint => isGeorgian
      ? 'ჩართვისას რუკაზე გამოჩნდება მხოლოდ ის დამტენები, რომელთა სიმძლავრე არჩეულ მნიშვნელობას აღემატება ან უტოლდება. მასზე სუსტი დამტენები დაიმალება.'
      : 'When on, the map only shows chargers rated at or above the selected power. Weaker chargers are hidden.';
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

  // ── Route planner charger filters ────────────────────────────────────────────
  static String get routeFiltersTitle =>
      isGeorgian ? 'დამტენის ფილტრები' : 'CHARGER FILTERS';
  static String get routeConnectorsLabel =>
      isGeorgian ? 'კონექტორის ტიპი' : 'Connector type';
  static String get routeMinPowerLabel =>
      isGeorgian ? 'მინ. სიმძლავრე' : 'Min. power';
  static String get routeFiltersHint => isGeorgian
      ? 'მარშრუტი დაიგეგმება მხოლოდ არჩეული კონექტორისა და სიმძლავრის მქონე სადგურებით'
      : 'The route is planned only through stations matching the selected connectors and power';
  static String get anyLabel => isGeorgian ? 'ყველა' : 'Any';

  // ── Charger options list (Plan & Go) ─────────────────────────────────────────
  static String get chargersOnRoute =>
      isGeorgian ? 'დამტენები მარშრუტზე' : 'CHARGERS ON ROUTE';
  static String get selectStopsHint => isGeorgian
      ? 'მონიშნე სად გსურს გაჩერება — გადავა Google Maps-ში'
      : 'Tick where you want to stop — they go to Google Maps';
  static String get recommendedBadge =>
      isGeorgian ? 'რეკომენდ.' : 'Recommended';
  static String get oppositeSideInfo => isGeorgian
      ? 'დამტენი არის გზის საპირისპირო მხარეს, დაგჭირდებათ მობრუნება'
      : 'The charger is on the opposite side of the road — you will need to turn around';
  static String get gotIt => isGeorgian ? 'გასაგებია' : 'Got it';
  static String get noChargersOnRoute => isGeorgian
      ? 'მარშრუტზე დამტენი ვერ მოიძებნა'
      : 'No chargers found along this route';

  /// "N chargers" badge under a block (counts every plug across providers).
  static String chargersCount(int n) =>
      isGeorgian ? '$n დამტენი' : '$n chargers';

  /// "N stations" — how many charger units are merged into one location block.
  static String stationsCount(int n) =>
      isGeorgian ? '$n სადგური' : '$n stations';

  /// "N ports" — total physical plugs across the block.
  static String portsCount(int n) =>
      isGeorgian ? '$n პორტი' : '$n ports';

  /// "X/Y free" — free vs total plugs at a block (so a busy block reads busy).
  static String plugsFree(int free, int total) =>
      isGeorgian ? '$free/$total თავისუფალი' : '$free/$total free';

  /// "X% on arrival" line for a charger block / the destination.
  static String onArrivalPct(int pct) =>
      isGeorgian ? 'ჩასვლისას $pct%' : '$pct% on arrival';

  /// Distance label between two blocks, e.g. "47 km".
  static String kmLabel(num v) =>
      isGeorgian ? '${v.toStringAsFixed(0)} კმ' : '${v.toStringAsFixed(0)} km';

  /// Collapsible route-segment header range, e.g. "0–50 km".
  static String segmentKmRange(int a, int b) =>
      isGeorgian ? '$a–$b კმ' : '$a–$b km';

  /// Hint above the grouped (collapsible) charger segments.
  static String get segmentsHint => isGeorgian
      ? 'გახსენი მონაკვეთი დამტენების სანახავად — ✓ ნიშნავს რომ იქ რეკომენდებული გაჩერებაა'
      : 'Open a segment to see its chargers — ✓ means a recommended stop is inside';

  // ── Premium / subscriptions ──────────────────────────────────────────────
  static String get getPremium =>
      isGeorgian ? 'გახდი Premium' : 'Get Premium';
  static String get premiumActive => 'Premium ✓';
  static String get premiumSubtitle => isGeorgian
      ? 'რეკლამების გარეშე — 7 დღე უფასოდ'
      : 'Remove ads — 7-day free trial';

  // ── Support / daily premium popup ────────────────────────────────────────
  static String get supportTitle => isGeorgian
      ? '⚡ დაუდექი პროექტს გვერდში!'
      : '⚡ Support the Project!';
  static String get supportBody => isGeorgian
      ? 'გინდა გამოიყენო აპლიკაცია სრულიად უფასოდ? პრობლემა არ არის! უბრალოდ, ხანდახან რეკლამებით შეგახსენებთ თავს. :)\n\nმაგრამ, თუ გსურს დამტენები სუპერ-სუფთა ეკრანზე, ყოველგვარი რეკლამების გარეშე ნახო, გახდი პრემიუმი თვეში სულ რაღაც 1 ლარად და დაგვეხმარე პროექტის განვითარებაში.'
      : "Want to use the app completely free? No problem at all! We'll just pop up a few ads here and there to keep the lights on. :)\n\nBut if you prefer looking at chargers on a super-clean screen with zero ads, go Premium for just 1 GEL/month and help us grow!";
  static String get supportGoAdFree => isGeorgian
      ? '🚀 რეკლამების გათიშვა (1 ₾)'
      : '🚀 Go Ad-Free (1 GEL)';
  static String get supportWatchAds => isGeorgian
      ? '☕ არაუშავს, ვუყურებ რეკლამებს'
      : "☕ It's fine, I'll watch ads";

  // ── Station detail ─────────────────────────────────────────────────────────
  static String get providerLastCheck => isGeorgian
      ? 'პროვაიდერის ბოლო შემოწმება — არა რეალურ დროში'
      : "Provider's last server check — not real-time";

  // Shown under the "Last verified" time. Which one applies depends on where the
  // reading came from: the feed carries the provider's own last server check and
  // is a pipeline snapshot, while a direct read from the operator is a second
  // old. Saying "not real-time" under the second one would be false.
  static String get liveFromProvider => isGeorgian
      ? 'ცოცხალი მონაცემი პროვაიდერის სისტემიდან'
      : 'Read live from the operator';

  // ── Manual refresh outcome ─────────────────────────────────────────────────
  // Three distinct answers, because "Updated" used to appear on every successful
  // request even when the data was byte-identical. That made a status stuck ten
  // minutes in the past look like a refresh button doing its job.
  static String get refreshUpdated =>
      isGeorgian ? 'განახლდა' : 'Updated';
  static String get refreshNoChange =>
      isGeorgian ? 'ცვლილება არაა' : 'No change';
  static String get refreshFailed =>
      isGeorgian ? 'ვერ განახლდა' : 'Update failed';

  // ── Connector (per-plug) status ──────────────────────────────────────────────
  static String get connectorsTitle =>
      isGeorgian ? 'კონექტორების სტატუსი' : 'Connector status';
  static String get portFree => isGeorgian ? 'თავისუფალია' : 'Free';
  static String get portBusy => isGeorgian ? 'დაკავებულია' : 'Occupied';
  static String get portOut  => isGeorgian ? 'მწყობრიდან გამოსულია' : 'Out of order';
  /// A plug whose operator publishes no real-time state (Tegeta's Porsche
  /// destination chargers at partner hotels are the first of these). Says we do
  /// not know, which is different from saying the plug is free or broken.
  static String get portUnknown =>
      isGeorgian ? 'სტატუსი არ ჩანს' : 'Status not published';

  /// Approximate "charging for ~N" line shown under a busy connector. Buckets to
  /// 5-min steps (and to hours past 60 min) since the exact figure isn't known.
  static String chargingFor(int minutes) {
    if (minutes >= 60) {
      final h = minutes ~/ 60;
      return isGeorgian ? 'იტენება $h სთ+' : 'Charging $h h+';
    }
    final b = (minutes ~/ 5) * 5;
    if (b <= 0) {
      return isGeorgian ? 'ახლახ დაიწყო' : 'Just started';
    }
    return isGeorgian ? 'იტენება $b+ წთ' : 'Charging $b+ min';
  }

  // ── Charger-free push alerts ("Notify me") ──────────────────────────────────
  static String get notifyMe => isGeorgian ? 'შემატყობინე!' : 'Notify me!';
  static String get alertActive =>
      isGeorgian ? 'შეტყობინება ჩართულია' : 'Alert is on';
  // Compact active-state label for the small per-connector notify button.
  static String get alertOnShort => isGeorgian ? 'ჩართულია' : 'On';
  static String get alertPopupTitle =>
      isGeorgian ? '🔔 შეტყობინება ჩართულია!' : '🔔 Alert set!';
  static String get alertPopupBody => isGeorgian
      ? 'როდესაც დამტენი გათავისუფლდება, შენ მიიღებ შეტყობინებას! გაითვალისწინე, რომ სხვადასხვა პროვაიდერებისგან ინფორმაცია განსხვავებულად მოდის და შეიძლება რამდენიმე წუთიანი დაგვიანებით მიიღო შეტყობინება. იმედია სხვა არ დაგასწრებს 🙂'
      : "When the charger frees up, you'll get a notification! Note that different providers report data differently, so the alert may arrive with a few minutes' delay. Hope no one beats you to it 🙂";
  static String get alertGotIt => isGeorgian ? 'გასაგებია' : 'Got it';
  static String get alertLimitReached => isGeorgian
      ? 'ერთდროულად მაქსიმუმ 4 დამტენზე შეგიძლია შეტყობინების დაყენება'
      : 'You can set alerts on up to 4 chargers at a time';
  static String get alertCancelled =>
      isGeorgian ? 'შეტყობინება გაუქმდა' : 'Alert cancelled';
  static String get alertError => isGeorgian
      ? 'შეტყობინების დაყენება ვერ მოხერხდა — სცადეთ თავიდან'
      : 'Could not set the alert — please try again';
  static String get alertPermissionDenied => isGeorgian
      ? 'შეტყობინებების მისაღებად ჩართე ნებართვა პარამეტრებში'
      : 'Enable notification permission in settings to receive alerts';
  static String get alertPushUnavailable => isGeorgian
      ? 'მოწყობილობაზე push-შეტყობინებები ვერ ჩაირთო — შეამოწმე ნებართვა და სცადე ხელახლა'
      : 'Push notifications could not be enabled on this device — check permission and try again';
  static String get alertLoginRequired => isGeorgian
      ? 'შეტყობინების მისაღებად ჯერ გაიარეთ ავტორიზაცია'
      : 'Sign in first to receive alerts';

  /// Push notification body sent when a subscribed charger frees up. The
  /// station name is the notification title; this is the body line.
  static String get alertPushBody => isGeorgian
      ? 'გათავისუფლდა! მოასწარი დატენვა სანამ სხვამ მიგასწრო 🙂'
      : 'is now free! Grab it before someone beats you to it 🙂';

  // ── New-charger broadcasts (profile) ─────────────────────────────────────
  static String get newStationAlertsTitle =>
      isGeorgian ? 'ახალი დამტენები' : 'New Chargers';
  static String get newStationAlertsHint => isGeorgian
      ? 'შეგატყობინებთ, როცა რომელიმე კომპანია ახალ სადგურს გახსნის'
      : 'Get a heads-up when a provider opens a new station';

  // ── Active alerts list (profile) ─────────────────────────────────────────
  static String get activeAlertsTitle =>
      isGeorgian ? 'აქტიური შეტყობინებები' : 'Active Alerts';
  static String get activeAlertsHint => isGeorgian
      ? 'დამტენები, რომელთა გათავისუფლებასაც ელოდები'
      : 'Chargers you are waiting to free up';
  static String get noActiveAlerts => isGeorgian
      ? 'აქტიური შეტყობინება არ გაქვს — დაკავებულ დამტენზე დააჭირე „შემატყობინე!"'
      : 'No active alerts — tap "Notify me!" on a busy charger';
  static String get cancelAlert =>
      isGeorgian ? 'გაუქმება' : 'Cancel';

  // ── Map filter chips ─────────────────────────────────────────────────────
  static String get fastDcSheetTitle =>
      isGeorgian ? 'Fast DC — მინიმალური სიმძლავრე' : 'Fast DC — Minimum power';
  static String get filterOff => isGeorgian ? 'გამორთვა' : 'Off';
  static String get dcAnyPower =>
      isGeorgian ? 'DC — ნებისმიერი სიმძლავრე' : 'DC — any power';

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

  // Required auto-renewable subscription disclosure (App Store Guideline 3.1.2).
  static String get autoRenewDisclosure => isGeorgian
      ? 'გამოწერა ავტომატურად განახლდება, თუ მიმდინარე პერიოდის დასრულებამდე მინიმუმ 24 საათით ადრე არ გააუქმებთ. გადახდა ჩამოიჭრება თქვენი Apple ID-დან ყიდვის დადასტურებისას. გამოწერის მართვა და გაუქმება შესაძლებელია App Store-ის პარამეტრებში ყიდვის შემდეგ.'
      : 'Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Payment is charged to your Apple ID at confirmation of purchase. You can manage or cancel anytime in your App Store account settings.';
  static String get termsOfUse =>
      isGeorgian ? 'მოხმარების წესები' : 'Terms of Use';
}
