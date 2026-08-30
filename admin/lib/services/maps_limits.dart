import 'package:flutter/foundation.dart';

import 'browser.dart' as browser;

/// One Google Maps Platform API, with the two ceilings that matter.
class ApiLimit {
  const ApiLimit({
    required this.key,
    required this.label,
    required this.freeMonthly,
    required this.dailyCap,
    this.rawRequests = false,
    this.note = '',
  });

  /// Field name in a `mapsUsage` document.
  final String key;
  final String label;

  /// Calls per calendar month that cost nothing.
  final int freeMonthly;

  /// The per-day quota cap set by hand in the Cloud console. Over it, requests
  /// FAIL rather than bill — which is the point of having set them — so how
  /// close today is to this number matters as much as the monthly tier.
  final int dailyCap;

  /// This API's counter is RAW HTTP requests rather than billed calls, so the
  /// monthly free tier is not a ceiling it can be compared to.
  ///
  /// Cloud Monitoring only ever counts raw requests. For most APIs that is also
  /// the billed unit, so the comparison holds. Places is the exception: with a
  /// session token one search is 3-6 requests and bills as a single Place
  /// Details call, so measuring 5,640 requests against a 5,000 *billed* free
  /// tier paints the card red while nothing is being billed. The daily cap is
  /// counted in the same unit as the metric, so that is what the gauge uses
  /// instead — see [MapsLimits._defaults].
  final bool rawRequests;

  /// Anything the number does not say for itself.
  final String note;

  ApiLimit copyWith({int? freeMonthly, int? dailyCap}) => ApiLimit(
        key: key,
        label: label,
        freeMonthly: freeMonthly ?? this.freeMonthly,
        dailyCap: dailyCap ?? this.dailyCap,
        rawRequests: rawRequests,
        note: note,
      );
}

/// The free tiers and daily caps the usage gauge is measured against.
///
/// Defaults are GeoCharge's real figures as of 2026-08-29 — the free tiers from
/// Google's price list, the daily caps from the quotas actually set on the
/// `ev-charger-app-497408` project. Both are editable and persisted to
/// localStorage, because Google changes its price list and we change our caps,
/// and neither should need a redeploy of this panel.
class MapsLimits extends ChangeNotifier {
  MapsLimits._();
  static final MapsLimits I = MapsLimits._().._load();

  static const List<ApiLimit> _defaults = [
    ApiLimit(
      key: 'maps',
      label: 'Maps JavaScript API',
      freeMonthly: 10000,
      dailyCap: 330,
      note: 'One map load per opening of tesla.geocharge.ge. '
          'Panning, zooming and live status are free.',
    ),
    ApiLimit(
      key: 'directions',
      label: 'Directions API',
      freeMonthly: 5000,
      dailyCap: 160,
      note: 'The tightest of the four: trip planning in both apps, plus every '
          'navigation start and reroute in the car.',
    ),
    ApiLimit(
      key: 'places',
      label: 'Places API',
      freeMonthly: 5000,
      dailyCap: 1000,
      rawRequests: true,
      note: 'Counted in RAW requests, not billed sessions — with session '
          'tokens one search is 3-6 requests but bills as a single Place '
          'Details call. The gauge therefore shows today against the daily '
          'cap, which is the same unit; the month figure is context only.',
    ),
    ApiLimit(
      key: 'geocoding',
      label: 'Geocoding API',
      freeMonthly: 10000,
      dailyCap: 0,
      note: 'Nothing calls it today. A number here means something new does.',
    ),
  ];

  List<ApiLimit> _limits = List.of(_defaults);

  List<ApiLimit> get all => List.unmodifiable(_limits);

  ApiLimit byKey(String key) =>
      _limits.firstWhere((l) => l.key == key, orElse: () => _defaults.first);

  void update(String key, {int? freeMonthly, int? dailyCap}) {
    _limits = [
      for (final l in _limits)
        l.key == key
            ? l.copyWith(
                freeMonthly: freeMonthly == null || freeMonthly < 0
                    ? null
                    : freeMonthly,
                dailyCap: dailyCap == null || dailyCap < 0 ? null : dailyCap,
              )
            : l,
    ];
    _save();
    notifyListeners();
  }

  /// Put every ceiling back to the shipped figures.
  void reset() {
    _limits = List.of(_defaults);
    _save();
    notifyListeners();
  }

  void _load() {
    _limits = [
      for (final l in _defaults)
        l.copyWith(
          freeMonthly: int.tryParse(browser.readLocal('maps_free_${l.key}') ?? ''),
          dailyCap: int.tryParse(browser.readLocal('maps_cap_${l.key}') ?? ''),
        ),
    ];
  }

  void _save() {
    for (final l in _limits) {
      browser.writeLocal('maps_free_${l.key}', l.freeMonthly.toString());
      browser.writeLocal('maps_cap_${l.key}', l.dailyCap.toString());
    }
  }
}
