import 'package:flutter_test/flutter_test.dart';

import 'package:ev_charger_app/app_constants.dart';

void main() {
  group('country list order', () {
    test('pins Georgia, Turkey and Armenia above the alphabet', () {
      expect(kCountries.take(3).map((c) => c.name).toList(),
          ['Georgia', 'Turkey', 'Armenia']);
    });

    test('everything after the pinned three is still A→Z', () {
      final rest = kCountries.skip(3).map((c) => c.name).toList();
      expect(rest, List<String>.from(rest)..sort());
    });

    test('lists every country exactly once', () {
      final names = kCountries.map((c) => c.name).toList();
      expect(names.toSet().length, names.length);
      // The pinned three were lifted out of the alphabet, not duplicated.
      for (final n in ['Georgia', 'Turkey', 'Armenia']) {
        expect(names.where((x) => x == n).length, 1, reason: n);
      }
    });
  });

  group('countryOf', () {
    // The display order above must not reach the classifier: the Armenian and
    // Turkish boxes overlap, and first match wins.
    test('keeps western Armenia Armenian even though Turkey now sorts first', () {
      // Gyumri sits inside BOTH boxes. Ordering the classifier like the list
      // would relabel real Armenian chargers as Turkish.
      expect(countryOf(40.7894, 43.8475), 'Armenia');
      // Yerevan, unambiguous.
      expect(countryOf(40.1792, 44.4991), 'Armenia');
    });

    test('still resolves the other boxed countries', () {
      expect(countryOf(41.7151, 44.8271), 'Georgia');   // Tbilisi
      expect(countryOf(41.0082, 28.9784), 'Turkey');    // Istanbul
      expect(countryOf(39.9334, 32.8597), 'Turkey');    // Ankara
      expect(countryOf(41.6168, 41.6367), 'Georgia');   // Batumi
    });

    test('returns null outside every box', () {
      expect(countryOf(48.8566, 2.3522), isNull);       // Paris
      expect(countryOf(0, 0), isNull);
    });
  });

  group('country codes', () {
    test('map back to the names the selection uses', () {
      expect(countryNameForCode('GE'), 'Georgia');
      expect(countryNameForCode('tr'), 'Turkey');
      expect(countryNameForCode('AM'), 'Armenia');
      expect(countryNameForCode('ZZ'), isNull);
      expect(countryNameForCode(null), isNull);
    });
  });

  group('localCovered', () {
    test('marks exactly the countries we ship provider data for', () {
      // These three are excluded from the Open Charge Map fetch, which is what
      // decides whether the "International" row has anything to show.
      expect(
        kCountries.where((c) => c.localCovered).map((c) => c.name).toSet(),
        {'Georgia', 'Turkey', 'Armenia'},
      );
    });
  });
}
