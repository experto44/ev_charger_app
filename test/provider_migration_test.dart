import 'package:flutter_test/flutter_test.dart';

import 'package:ev_charger_app/app_constants.dart';
import 'package:ev_charger_app/main.dart';

/// Pins the rule that decides whether a newly integrated network is visible at
/// all. Every provider we add ships as a name that no existing install can have
/// saved, so getting this wrong hides the whole network from everyone who has
/// ever opened the provider sheet — silently, with no error anywhere.
void main() {
  const local = [
    'E-Space', 'mart EV', 'EV Power GE', 'Tegeta', 'ZZZ',
  ];
  const knownBefore = {
    'E-Space', 'mart EV', 'EV Power GE', 'Tegeta',
  };

  group('providersToAutoEnable', () {
    test('switches on a network added after the user last chose', () {
      final fresh = providersToAutoEnable(
        saved: {'E-Space', 'mart EV'},
        known: knownBefore,
        local: local,
      );
      expect(fresh, {'ZZZ'});
    });

    test('never re-ticks a provider the user deliberately unticked', () {
      // Tegeta is in the known list, so its absence from `saved` is a choice
      // and must survive; ZZZ could not have been chosen, so it comes on.
      final fresh = providersToAutoEnable(
        saved: {'E-Space', 'mart EV', 'EV Power GE'},
        known: knownBefore,
        local: local,
      );
      expect(fresh, {'ZZZ'});
      expect(fresh, isNot(contains('Tegeta')));
    });

    test('adds nothing once the install has recorded the new network', () {
      final fresh = providersToAutoEnable(
        saved: {'E-Space'},
        known: {...knownBefore, 'ZZZ'},   // user unticked ZZZ after migrating
        local: local,
      );
      expect(fresh, isEmpty);
    });

    test('never touches an empty selection, which means "show everything"', () {
      final fresh = providersToAutoEnable(
        saved: <String>{},
        known: knownBefore,
        local: local,
      );
      expect(fresh, isEmpty);
    });

    test('is idempotent: a second pass with the same input adds nothing new',
        () {
      final saved = {'E-Space', 'mart EV'};
      final first = providersToAutoEnable(
          saved: saved, known: knownBefore, local: local);
      saved.addAll(first);
      final second = providersToAutoEnable(
          saved: saved, known: {...knownBefore, ...first}, local: local);
      expect(second, isEmpty);
    });
  });

  /// City Hall is the exception to everything the group above pins down. Its
  /// posts have no live status at all, so they are shown only to someone who
  /// asked for them — which only holds as long as the row stays out of the
  /// default list, since that same list is what the migration switches on.
  group('City Hall stays opt-in', () {
    test('is offered in the provider sheet', () {
      expect(kAllProviders, contains(kCityHallProvider));
    });

    test('is not selected on a fresh install', () {
      expect(kDefaultProviders, isNot(contains(kCityHallProvider)));
    });

    test('is never switched on for an existing install', () {
      // The real call the app makes: `local` is the default list, so an opt-in
      // row cannot reach `saved` however stale that install's selection is.
      final fresh = providersToAutoEnable(
        saved: {'E-Space', 'mart EV'},
        known: const {'E-Space', 'mart EV'},
        local: kDefaultProviders,
      );
      expect(fresh, isNot(contains(kCityHallProvider)));
    });

    test('every other local provider is still on by default', () {
      for (final p in kAllProviders) {
        if (requiresExplicitOptIn(p) ||
            p == 'Turkey' ||
            p == 'International') {
          continue;
        }
        expect(kDefaultProviders, contains(p),
            reason: '$p should ship switched on');
      }
    });
  });
}
