import 'package:ev_charger_app/routing_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Turkish dataset (tools/build_turkey.py → chargers_tr.json) is the first
/// feed that carries `live: false` and `price_note`. These tests pin the schema
/// contract between the builder and Station.fromJson: if either side drifts,
/// stations silently start claiming live availability again.
void main() {
  Map<String, dynamic> trRow({
    bool? live,
    String priceNote = 'ZES published tariff · checked 07.08.2026',
  }) =>
      <String, dynamic>{
        'id': 'epdk_srj2140',
        'name': 'KMO FENERKÖY KUZEY',
        'lat': 41.1219176401397,
        'lng': 28.2289614588942,
        'power': '160 kW',
        'type': 'Fast DC',
        'price': '12,99 - 16,49 ₺/kWh',
        'price_note': priceNote,
        'available_spots': '3 available',
        'total_spots': 3,
        'city': 'İstanbul',
        'provider': 'ZES',
        'country': 'Turkey',
        'connectors': ['CCS2', 'Type 2'],
        if (live != null) 'live': live,
        'last_updated': '2026-08-06 21:20 UTC',
      };

  test('parses a Turkish registry row', () {
    final s = Station.fromJson(trRow(live: false));

    expect(s.id, 'epdk_srj2140');
    expect(s.provider, 'ZES');
    expect(s.country, 'Turkey');
    expect(s.kw, 160);
    expect(s.isDC, isTrue);
    expect(s.total, 3);
    expect(s.available, 3);
    expect(s.price, '12,99 - 16,49 ₺/kWh');
    expect(s.connectors, ['CCS2', 'Type 2']);
  });

  test('registry rows are not treated as live availability', () {
    expect(Station.fromJson(trRow(live: false)).live, isFalse);
    expect(Station.fromJson(trRow(live: false)).priceNote,
        'ZES published tariff · checked 07.08.2026');
  });

  test('feeds without a live flag stay live (Georgian providers)', () {
    // The Georgian gist has no `live` key and its availability IS real-time,
    // so the default must not flip those stations to "status not published".
    expect(Station.fromJson(trRow()).live, isTrue);
  });

  test('a brand with no verified tariff carries no price note', () {
    final s = Station.fromJson(<String, dynamic>{
      ...trRow(live: false),
      'price': '',
      'price_note': '',
    });
    expect(s.price, isEmpty);
    expect(s.priceNote, isEmpty);
  });

  test('withDistance keeps the Turkish-specific fields', () {
    final s = Station.fromJson(trRow(live: false)).withDistance('12 km');
    expect(s.distance, '12 km');
    expect(s.live, isFalse);
    expect(s.priceNote, isNotEmpty);
    expect(s.country, 'Turkey');
  });
}
