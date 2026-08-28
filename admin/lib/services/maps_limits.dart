import 'package:flutter/foundation.dart';

import 'browser.dart' as browser;

/// One Google Maps Platform API, with the two ceilings that matter.
class ApiLimit {
  const ApiLimit({
    required this.key,
    required this.label,
    required this.freeMonthly,
    required this.dailyCap,
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

  /// Anything the number does not say for itself.
  final String note;

  ApiLimit copyWith({int? freeMonthly, int? dailyCap}) => ApiLimit(
        key: key,
        label: label,
        freeMonthly: freeMonthly ?? this.freeMonthly,
        dailyCap: dailyCap ?? this.dailyCap,
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
      note: 'RAW requests, not billed sessions — with session tokens one '
          'search is 3-6 requests but bills as a single Place Details call, so '
          'read this against the daily cap rather than the free tier.',
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
