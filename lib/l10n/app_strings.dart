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
  static String get contact => isGeorgian ? 'კონტაქტი' : 'Contact';
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
  static String get countriesTitle =>
      isGeorgian ? 'ქვეყნების არჩევა' : 'COUNTRIES';
  static String get myConnector => isGeorgian ? 'ჩემი კონექტორი' : 'My Connector';
  static String get maxRange => isGeorgian ? 'მაქს. გარბენი' : 'Max Range';
  static String get connectorHint => isGeorgian
      ? 'აირჩიეთ ერთი ან რამდენიმე. გამოიყენება როგორც ნაგულისხმევი ფილტრი რუკაზე'
      : 'Select one or more. Used as your default filter on the map';
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
  /// Sits under the gold badge once premium is active. Deliberately says
  /// nothing about price or renewal date; the store owns both.
  static String get premiumActiveSubtitle => isGeorgian
      ? 'რეკლამები გამორთულია. მადლობა მხარდაჭერისთვის.'
      : 'Ads are off. Thank you for the support.';
  static String get premiumSubtitle => isGeorgian
      ? 'რეკლამების გარეშე, 7 დღე უფასოდ'
      : 'Remove ads, 7-day free trial';

  // ── Support / daily premium popup ────────────────────────────────────────
  static String get supportTitle => isGeorgian
      ? '⚡ დაუდექი პროექტს გვერდში!'
      : '⚡ Support the Project!';
  static String get supportBody => isGeorgian
      ? 'გინდა გამოიყენო აპლიკაცია სრულიად უფასოდ? პრობლემა არ არის! უბრალოდ, ხანდახან რეკლამებით შეგახსენებთ თავს. :)\n\nმაგრამ, თუ გსურს დამტენები სუპერ-სუფთა ეკრანზე, ყოველგვარი რეკლამების გარეშე ნახო, გახდი პრემიუმი და დაგვეხმარე პროექტის განვითარებაში.'
      : "Want to use the app completely free? No problem at all! We'll just pop up a few ads here and there to keep the lights on. :)\n\nBut if you prefer looking at chargers on a super-clean screen with zero ads, go Premium and help us grow!";
  static String get supportGoAdFree => isGeorgian
      ? '🚀 რეკლამების გათიშვა'
      : '🚀 Go Ad-Free';
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

  // ── "Status not published" explainer ───────────────────────────────────────
  // "Status not published" answers the wrong question on its own. What a driver
  // actually wants to know is whose charger this is and whether it is still
  // worth driving to, so the row carries an "i" that says exactly that.
  static String get unknownInfoTitle =>
      isGeorgian ? 'რატომ არ ჩანს სტატუსი?' : 'Why is there no status?';

  /// Shown only for plugs the FEED tagged `status_note: "porsche"`, i.e. ones
  /// Tegeta's own catalogue marks `isPorsche: true`. The tag names the flag, not
  /// the copy: the text deliberately does NOT call these Porsche chargers or
  /// name any Porsche programme, because the only thing on record is that flag,
  /// the PORSCHE tab in Tegeta's app and the PDC- prefix on the ids. It says
  /// what can be pointed at instead. The rest (no live data, start on site, no
  /// price) was verified in their app.
  static String get unknownInfoPorsche => isGeorgian
      ? 'ეს თეგეტას დამტენია და მათსავე აპლიკაციაში ცალკე PORSCHE ჩანართში '
          'ხვდება. დგას სასტუმროს, კურორტის ან სხვა კერძო ობიექტის '
          'ტერიტორიაზე.\n\n'
          'თეგეტა მისგან რეალურ დროში მონაცემს არ იღებს და არ გასცემს, ამიტომ '
          'ვერ გეტყვით, ახლა დაკავებულია თუ თავისუფალი. დატენვა მხოლოდ ადგილზე '
          'ირთვება, აპლიკაციიდან ვერც ჩართავთ და ვერც გადაიხდით, ამიტომ ზუსტ '
          'ფასს არ ვწერთ.\n'
          'იგივე ინფორმაციას იძლევა თეგეტას საკუთარი აპლიკაციაც.\n\n'
          'ასეთი დამტენი ხშირად ობიექტის სტუმრებისთვისაა განკუთვნილი.\n'
          'სანამ გზას გაუყვებით, ჯობია წინასწარ დარეკოთ ან ადგილზე იკითხოთ.\n'
          'მადლობა რომ სარგებლობთ GeoCharge აპლიკაციით ❤'
      : 'This is a Tegeta charger, and in their own app it sits under a '
          'separate PORSCHE tab. It stands on a hotel, resort or other private '
          'property.\n\n'
          'Tegeta neither receives nor publishes real-time data for it, so we '
          'cannot tell you whether it is free or in use right now. Charging is '
          'started on site, you cannot start it or pay for it from an app, so '
          'we do not quote an exact price.\n'
          'Tegeta\'s own app says the same.\n\n'
          'Chargers like this are often meant for the venue\'s guests.\n'
          'Call ahead or ask on site before you set off.\n'
          'Thank you for using GeoCharge ❤';

  /// Any other operator that publishes a plug but no state for it.
  static String get unknownInfoGeneric => isGeorgian
      ? 'ამ დამტენზე ოპერატორი ცოცხალ მონაცემს არ გვიზიარებს. ვიცით, რომ '
          'დამტენი იქ დგას, მაგრამ ვერ გეტყვით, ახლა დაკავებულია თუ '
          'თავისუფალი, და ფასსაც იმიტომ არ ვწერთ, რომ დადასტურებული არ არის.\n\n'
          'სანამ გზას გაუყვებით, ჯობია წინასწარ გადაამოწმოთ.'
      : 'The operator does not share live data for this plug. We know the '
          'charger is there, but we cannot tell you whether it is free or in use '
          'right now, and we will not quote a price we cannot confirm.\n\n'
          'Worth checking before you make the trip.';

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
      ? 'აქტიური შეტყობინება არ გაქვს. დაკავებულ დამტენზე დააჭირე „შემატყობინე!"'
      : 'No active alerts. Tap "Notify me!" on a busy charger';
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
      ? 'მაღაზია მიუწვდომელია, სცადეთ მოგვიანებით'
      : 'Store unavailable, please try again later';
  static String get purchaseFailed =>
      isGeorgian ? 'შესყიდვა ვერ მოხერხდა' : 'Purchase failed';
  /// Shown on the paywall when the store returned no products, so the prices on
  /// the cards are the app's own fallbacks rather than real store prices.
  static String get priceLoadFailed => isGeorgian
      ? 'ფასების ჩატვირთვა ვერ მოხერხდა. შეამოწმეთ ინტერნეტი და App Store-ის შეზღუდვები (Screen Time), შემდეგ სცადეთ ხელახლა.'
      : 'Could not load prices. Check your connection and your App Store restrictions (Screen Time), then try again.';
  static String get tryAgain => isGeorgian ? 'ხელახლა ცდა' : 'Try again';
  static String get noActiveSubscription => isGeorgian
      ? 'აქტიური გამოწერა ვერ მოიძებნა'
      : 'No active subscription found';

  // Required auto-renewable subscription disclosure (App Store Guideline 3.1.2).
  static String get autoRenewDisclosure => isGeorgian
      ? 'გამოწერა ავტომატურად განახლდება, თუ მიმდინარე პერიოდის დასრულებამდე მინიმუმ 24 საათით ადრე არ გააუქმებთ. გადახდა ჩამოიჭრება თქვენი Apple ID-დან ყიდვის დადასტურებისას. გამოწერის მართვა და გაუქმება შესაძლებელია App Store-ის პარამეტრებში ყიდვის შემდეგ.'
      : 'Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Payment is charged to your Apple ID at confirmation of purchase. You can manage or cancel anytime in your App Store account settings.';
  static String get termsOfUse =>
      isGeorgian ? 'მოხმარების წესები' : 'Terms of Use';

  // ── Tesla pairing ──────────────────────────────────────────────────────────
  // Signing in to tesla.geocharge.ge without a password: the car shows a code,
  // this app approves it. See functions/tesla-pairing.js.
  static String get teslaTitle => 'Tesla';
  static String get teslaTileConnected =>
      isGeorgian ? 'ავტომობილი დაკავშირებულია' : 'Car connected';
  static String get teslaTileIdle => isGeorgian
      ? 'დააკავშირე ავტომობილი tesla.geocharge.ge-სთან'
      : 'Connect your car to tesla.geocharge.ge';
  static String get teslaLead => isGeorgian
      ? 'ავტომობილის ეკრანზე ნაჩვენები კოდი აქ შეიყვანე და ტესლა ამ ანგარიშით შემოვა. პაროლი საჭირო არაა.'
      : 'Type the code shown on your car screen and the Tesla signs in with this account. No password needed.';
  static String get teslaStep1 => isGeorgian
      ? 'მანქანის ბრაუზერში გახსენი tesla.geocharge.ge'
      : 'Open tesla.geocharge.ge in the car browser';
  static String get teslaStep2 => isGeorgian
      ? 'ეკრანზე გამოჩნდება 6 ნიშნა კოდი'
      : 'A 6-digit code appears on the screen';
  static String get teslaStep3 => isGeorgian
      ? 'შეიყვანე კოდი აქ, სანამ ვადა არ გასვლია'
      : 'Enter that code here before it expires';
  static String get teslaConnect => isGeorgian ? 'დაკავშირება' : 'Connect';
  static String get teslaDisconnect => isGeorgian ? 'გათიშვა' : 'Disconnect';
  static String get teslaConnectedSince =>
      isGeorgian ? 'დაკავშირდა' : 'Connected';
  static String get teslaOneCarNote => isGeorgian
      ? 'ერთ ანგარიშზე ერთი ავტომობილი შეიძლება იყოს დაკავშირებული.'
      : 'One account can be connected to one car at a time.';
  static String get teslaReplaceTitle =>
      isGeorgian ? 'უკვე დაკავშირებულია' : 'Already connected';
  static String get teslaReplaceBody => isGeorgian
      ? 'ეს ანგარიში სხვა ავტომობილზეა დაკავშირებული. გავთიშოთ ის და დავაკავშიროთ ახალი?'
      : 'This account is connected to another car. Disconnect it and connect this one?'
      ;
  static String get teslaReplaceConfirm =>
      isGeorgian ? 'გათიშვა და დაკავშირება' : 'Disconnect and connect';
  static String get teslaBadCode => isGeorgian
      ? 'კოდი არასწორია ან ვადა გაუვიდა'
      : 'That code is wrong or has expired';
  static String get teslaTooMany => isGeorgian
      ? 'ბევრი მცდელობა იყო. სცადე რამდენიმე წუთში'
      : 'Too many attempts. Try again in a few minutes';
  static String get teslaFailed => isGeorgian
      ? 'ვერ მოხერხდა. შეამოწმე ინტერნეტი'
      : 'Could not connect. Check your connection';
  // ── Sending a route to the car ─────────────────────────────────────────────
  // Two ways in: a trip built in the route planner, and a link shared out of
  // the Google Maps app. Both end up in the same place — the car offers the
  // route and the driver decides. See lib/services/tesla_route_service.dart.
  static String get teslaSendToCar =>
      isGeorgian ? 'მანქანაში გაგზავნა' : 'Send to the car';
  static String get teslaSentOk => isGeorgian
      ? 'მარშრუტი გაიგზავნა. ტესლას ეკრანზე დაგხვდება.'
      : 'Route sent. It will be waiting on the car screen.';
  static String get teslaSentNoCar => isGeorgian
      ? 'მარშრუტი შენახულია, თუმცა ავტომობილი ჯერ დაკავშირებული არაა. დააკავშირე პროფილიდან.'
      : 'Route saved, but no car is connected yet. Connect one from your profile.';
  static String get teslaSendFailed => isGeorgian
      ? 'ვერ გაიგზავნა. შეამოწმე ინტერნეტი და სცადე ხელახლა.'
      : 'Could not send. Check your connection and try again.';
  static String get teslaSendSignedOut => isGeorgian
      ? 'მარშრუტის გასაგზავნად ჯერ ანგარიშში შედი.'
      : 'Sign in first to send a route to the car.';
  static String get teslaSendFallbackName =>
      isGeorgian ? 'მარშრუტი' : 'Route';

  // Importing a route shared out of Google Maps.
  static String get teslaImportTitle =>
      isGeorgian ? 'მარშრუტი Google Maps-იდან' : 'Route from Google Maps';
  static String get teslaImportLead => isGeorgian
      ? 'Google Maps-ში დაგეგმე მარშრუტი, დააჭირე გაზიარებას და ბმული აქ ჩასვი. გაჩერებები და ფასიანი გზების პარამეტრი გადმოყვება.'
      : 'Plan the route in Google Maps, tap share, and paste the link here. The stops and the avoid-tolls setting come with it.';
  static String get teslaImportPaste =>
      isGeorgian ? 'ბმულის ჩასმა' : 'Paste link';
  static String get teslaImportHint =>
      isGeorgian ? 'https://maps.app.goo.gl/…' : 'https://maps.app.goo.gl/…';
  static String get teslaImportRead =>
      isGeorgian ? 'წაკითხვა' : 'Read the link';
  static String get teslaImportBadLink => isGeorgian
      ? 'ეს Google Maps-ის მარშრუტის ბმული არაა.'
      : 'That is not a Google Maps route link.';
  static String get teslaImportNotDriving => isGeorgian
      ? 'ეს მარშრუტი მანქანისთვის არაა.'
      : 'That route is not for driving.';
  static String get teslaImportUnreadable => isGeorgian
      ? 'ბმული ვერ წავიკითხეთ. სცადე ხელახლა გაზიარება.'
      : 'Could not read that link. Try sharing it again.';
  static String get teslaImportTooMany => isGeorgian
      ? 'ბევრი ცდაა. სცადე ცოტა ხანში.'
      : 'Too many attempts. Try again shortly.';
  static String get teslaImportNoTolls =>
      isGeorgian ? 'ფასიანი გზების გარეშე' : 'No toll roads';
  /// "2 stops" / "1 stop". Georgian needs no plural, English does, and the
  /// count is worth getting right on a card whose whole job is to say what the
  /// route contains.
  static String teslaImportStops(int n) =>
      isGeorgian ? '$n გაჩერება' : (n == 1 ? '1 stop' : '$n stops');
  static String get teslaImportDirect =>
      isGeorgian ? 'პირდაპირ' : 'Direct';
  static String get teslaImportDropped => isGeorgian
      ? 'ერთი გაჩერება ვერ წავიკითხეთ და გამოვტოვეთ.'
      : 'One stop could not be read and was skipped.';

  static String get teslaDone =>
      isGeorgian ? 'მზადაა, ავტომობილი შემოვიდა' : 'Done, the car is signed in';

  // ── Expenses ───────────────────────────────────────────────────────────────
  // The driver's own charging-cost log: a paid charge is the amount they paid
  // in the provider's app, a home charge is worked out from their tariff.
  static String get expensesTitle => isGeorgian ? 'ხარჯები' : 'Expenses';
  static String get expensesAndCalc =>
      isGeorgian ? 'ხარჯები და კალკულატორი' : 'Expenses and calculator';
  static String get expensesTileHint => isGeorgian
      ? 'დატენის ხარჯების აღრიცხვა'
      : 'Track what charging costs you';
  static String get expensesThisMonth => isGeorgian ? 'ამ თვეში' : 'This month';
  static String get expensesAllTime => isGeorgian ? 'სულ' : 'All time';
  static String get expensesHome => isGeorgian ? 'სახლში' : 'Home';
  static String get expensesPaid => isGeorgian ? 'ფასიანი' : 'Paid';
  static String get expensesByMonth => isGeorgian ? 'თვეების მიხედვით' : 'By month';
  static String get expensesRecords => isGeorgian ? 'ჩანაწერები' : 'Records';
  static String get expensesEmptyTitle =>
      isGeorgian ? 'ჯერ ჩანაწერი არ გაქვს' : 'Nothing recorded yet';
  static String get expensesEmptyBody => isGeorgian
      ? 'დატენის შემდეგ დააჭირე პლიუსს და ჩაწერე, რა დაგიჯდა.'
      : 'After a charge, tap the plus and record what it cost.';
  static String get expensesSignedOutHint => isGeorgian
      ? 'ჩანაწერები ამ ტელეფონზეა შენახული. ანგარიშში შესვლის შემდეგ სხვა ტელეფონზეც გადმოგყვება.'
      : 'Records are kept on this phone. Sign in and they follow you to another one.';

  // Adding and editing
  static String get expensesAddTitle => isGeorgian ? 'როგორ დატენე?' : 'How did you charge?';
  static String get expensesPaidCharge =>
      isGeorgian ? 'ფასიან დამტენზე' : 'At a paid charger';
  static String get expensesHomeCharge => isGeorgian ? 'სახლის დამტენზე' : 'At home';
  static String get expensesPaidTitle =>
      isGeorgian ? 'ფასიანი დატენვა' : 'Paid charge';
  static String get expensesHomeTitle =>
      isGeorgian ? 'სახლში დატენვა' : 'Home charge';
  static String get expensesPaidHint => isGeorgian
      ? 'ჩაწერე თანხა, რომელიც პროვაიდერის აპლიკაციაში გადაიხადე.'
      : "Type the amount you paid in the provider's own app.";
  static String get expensesHomeHint => isGeorgian
      ? 'ჩაწერე, რამდენი პროცენტიდან რამდენამდე დატენე. ხარჯს შენი ტარიფით დავთვლით.'
      : 'Type the percentage you started and finished at. We work the cost out from your tariff.';
  static String get expensesAmount => isGeorgian ? 'თანხა' : 'Amount';
  static String get expensesDate => isGeorgian ? 'თარიღი' : 'Date';
  static String get expensesFromPercent => isGeorgian ? 'საიდან' : 'From';
  static String get expensesToPercent => isGeorgian ? 'სადამდე' : 'To';
  static String get expensesEnergy => isGeorgian ? 'ენერგია' : 'Energy';
  static String get expensesEstimated => isGeorgian ? 'ხარჯი' : 'Cost';
  static String get expensesEdit => isGeorgian ? 'რედაქტირება' : 'Edit';
  static String get expensesDeleteTitle =>
      isGeorgian ? 'ჩანაწერი წაიშალოს?' : 'Delete this record?';
  static String get expensesDeleteBody => isGeorgian
      ? 'ჩანაწერი სამუდამოდ წაიშლება.'
      : 'The record will be gone for good.';
  static String get expensesDeleted => isGeorgian ? 'ჩანაწერი წაიშალა' : 'Record deleted';
  static String get expensesNeedAmount =>
      isGeorgian ? 'შეიყვანე თანხა' : 'Enter an amount';
  static String get expensesSaveFailed => isGeorgian
      ? 'ჩანაწერი ვერ შეინახა. სცადე ხელახლა.'
      : 'Could not save the record. Try again.';
  static String get expensesNeedPercents => isGeorgian
      ? 'პროცენტები 0-დან 100-მდე უნდა იყოს და დასრულება დაწყებაზე მეტი.'
      : 'Percentages run from 0 to 100, and the end must be above the start.';

  // Settings (battery, tariff, loss)
  static String get expensesSettings => isGeorgian ? 'პარამეტრები' : 'Settings';
  static String get expensesBattery =>
      isGeorgian ? 'ბატარეის ტევადობა' : 'Battery capacity';
  static String get expensesBatteryHint => isGeorgian
      ? 'რამდენი კილოვატსაათია შენი ბატარეა. მაგალითად 60'
      : 'How many kilowatt-hours your battery holds. For example 60';
  static String get expensesTariff => isGeorgian ? 'დენის ტარიფი' : 'Electricity tariff';
  static String get expensesTariffHint => isGeorgian
      ? 'რა ღირს ერთი კილოვატსაათი შენს ტარიფში. მაგალითად 0.29'
      : 'What one kilowatt-hour costs on your tariff. For example 0.29';
  static String get expensesLoss => isGeorgian ? 'დატენის დანაკარგი' : 'Charging loss';
  static String get expensesLossHint => isGeorgian
      ? 'ქსელიდან აღებული ენერგიის ნაწილი ბატარეამდე ვერ აღწევს. ჩვეულებრივ 8-დან 12 პროცენტამდე.'
      : 'Some of the energy drawn from the meter never reaches the battery. Usually 8 to 12 percent.';
  static String get expensesSettingsNeeded => isGeorgian
      ? 'ჯერ შეავსე ბატარეის ტევადობა და დენის ტარიფი.'
      : 'Fill in your battery capacity and electricity tariff first.';
  static String get expensesOpenSettings =>
      isGeorgian ? 'პარამეტრების შევსება' : 'Fill them in';
  static String get expensesNeedSettingsValues => isGeorgian
      ? 'ტევადობა და ტარიფი ნულზე მეტი უნდა იყოს.'
      : 'Capacity and tariff must be above zero.';

  /// "20% → 80%", the subtitle under a home record.
  static String expensesRange(int from, int to) => '$from% → $to%';

  // ── Calculator ─────────────────────────────────────────────────────────────
  // Two answers from one set of numbers: how long the stop takes and what it
  // costs. Mirrors the block on geocharge.ge's home page.
  static String get calcTitle => isGeorgian ? 'კალკულატორი' : 'Calculator';
  static String get calcTileHint => isGeorgian
      ? 'რამდენ ხანს გასტანს დატენვა და რა დაჯდება'
      : 'How long a charge takes and what it costs';
  static String get calcIntro => isGeorgian
      ? 'მიუთითე ბატარეის ტევადობა, დამტენის სიმძლავრე და მუხტის დონე.'
      : 'Enter your battery capacity, the charger power and the charge levels.';
  static String get calcBattery =>
      isGeorgian ? 'ბატარეის ტევადობა' : 'Battery capacity';
  static String get calcPower =>
      isGeorgian ? 'დამტენის სიმძლავრე' : 'Charger power';
  static String get calcFrom => isGeorgian ? 'მიმდინარე მუხტი' : 'Current charge';
  static String get calcTo => isGeorgian ? 'სასურველი მუხტი' : 'Target charge';
  static String get calcTariff => isGeorgian ? 'ტარიფი' : 'Tariff';
  static String get calcTariffHint => isGeorgian
      ? 'ნაგულისხმევად საქართველოს სწრაფი დამტენების მედიანაა. შეცვალე იმ ქსელის ტარიფით, სადაც ტენავ.'
      : "Defaults to the median for Georgia's fast chargers. Change it to the tariff of the network you use.";
  static String get calcTimeResult =>
      isGeorgian ? 'რამდენ ხანს გასტანს' : 'How long it takes';
  static String get calcCostResult => isGeorgian ? 'რა დაჯდება' : 'What it costs';
  static String get calcEnergy =>
      isGeorgian ? 'ბატარეაში შედის' : 'Energy added';
  static String get calcAvgPower =>
      isGeorgian ? 'საშუალო სიმძლავრე' : 'Average power';
  static String get calcBand80 =>
      isGeorgian ? '20 პროცენტიდან 80-მდე' : '20 to 80 percent';
  static String get calcBand100 =>
      isGeorgian ? 'ბოლო 20 პროცენტი' : 'The last 20 percent';
  static String get calcNote => isGeorgian
      ? 'დრო დატენვის რეალური მრუდით ითვლება, ამიტომ 80 პროცენტის შემდეგ ბატარეა შესამჩნევად ნელა ივსება. შედეგი შეფასებაა: ზუსტი დრო მანქანის მოდელზე, ბატარეის ტემპერატურასა და დამტენის დატვირთვაზეა დამოკიდებული.'
      : 'The time follows the real charging curve, so the battery fills noticeably more slowly above 80 percent. The result is an estimate: the exact time depends on the car, the battery temperature and how busy the charger is.';
  static String get calcFillIn => isGeorgian
      ? 'შეავსე ველები, რომ შედეგი გამოჩნდეს.'
      : 'Fill in the fields to see the result.';

  /// "1 სთ 12 წთ" / "1 h 12 min", or "48 წთ" under an hour.
  static String duration(int minutes) {
    final h = minutes ~/ 60, m = minutes % 60;
    final hu = isGeorgian ? 'სთ' : 'h', mu = isGeorgian ? 'წთ' : 'min';
    if (minutes < 60) { return '$minutes $mu'; }
    return m == 0 ? '$h $hu' : '$h $hu $m $mu';
  }

  /// Short month name for the chart and the record list headings.
  static String monthShort(int m) {
    const ka = ['იან', 'თებ', 'მარ', 'აპრ', 'მაი', 'ივნ',
                'ივლ', 'აგვ', 'სექ', 'ოქტ', 'ნოე', 'დეკ'];
    const en = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final i = (m - 1).clamp(0, 11);
    return isGeorgian ? ka[i] : en[i];
  }

  /// Full month name, used on the list's month headings.
  static String monthLong(int m) {
    const ka = ['იანვარი', 'თებერვალი', 'მარტი', 'აპრილი', 'მაისი', 'ივნისი',
                'ივლისი', 'აგვისტო', 'სექტემბერი', 'ოქტომბერი', 'ნოემბერი',
                'დეკემბერი'];
    const en = ['January', 'February', 'March', 'April', 'May', 'June',
                'July', 'August', 'September', 'October', 'November',
                'December'];
    final i = (m - 1).clamp(0, 11);
    return isGeorgian ? ka[i] : en[i];
  }
}
