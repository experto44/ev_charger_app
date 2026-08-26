import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ev_charger_app/routing_service.dart';
import 'package:ev_charger_app/services/live_status_service.dart';

/// A minimal feed row to hang live readings off. Only the id and provider
/// matter to the code under test; the rest is what the feed would have carried.
Station _station({
  String id = 'martev_220',
  String provider = 'mart EV',
  int available = 2,
  int total = 2,
  List<ConnectorPort> ports = const [],
}) =>
    Station(
      id: id,
      name: 'Beri Gabriel Salosi 135',
      location: 'Tbilisi',
      available: available,
      total: total,
      lat: 41.7084911,
      lng: 44.7690355,
      isDC: true,
      kw: 60,
      price: '0.8 ₾/kWh',
      provider: provider,
      lastUpdated: '2026-08-19 18:53 UTC',
      connectors: const ['CCS2', 'GB/T'],
      ports: ports,
    );

void main() {
  final fixture =
      File('test/fixtures/ampeco_location.json').readAsStringSync();
  final svc = LiveStatusService.I;

  group('AMPECO direct read', () {
    test('counts the idle sibling of a charging plug as free', () {
      // The exact case a driver reported: CCS2 charging, GB/T sitting there
      // free, and AMPECO reporting the GB/T as status=unavailable because the
      // two share one power module. Reading "unavailable" as broken would show
      // "0 of 3" for a station that has a plug you can actually use.
      final s = svc.applyAmpecoForTest(_station(), fixture, '220')!;
      expect(s.total, 3);
      expect(s.available, 1);

      expect(s.ports.map((p) => '${p.type}:${p.status}').toList(), [
        'CCS2:busy',
        'GB/T:free',
        'Type 2:out',
      ]);
    });

    test('keeps the session start time so "charging for N" stays right', () {
      final s = svc.applyAmpecoForTest(_station(), fixture, '220')!;
      final busy = s.ports.firstWhere((p) => p.isBusy);
      expect(busy.since, DateTime.utc(2026, 8, 19, 18, 57));
      // Only a busy plug carries one.
      expect(s.ports.where((p) => !p.isBusy).every((p) => p.since == null), isTrue);
    });

    test('ignores other locations carried in the same response', () {
      // One call can answer for several linked locations. Counting them all
      // would inflate this station with plugs that are somewhere else entirely.
      final s = svc.applyAmpecoForTest(_station(), fixture, '220')!;
      expect(s.total, 3, reason: 'location 999 must not be counted');
      final other = svc.applyAmpecoForTest(_station(), fixture, '999')!;
      expect(other.total, 1);
      expect(other.available, 1);
    });

    test('leaves every descriptive field exactly as the feed published it', () {
      final before = _station();
      final after = svc.applyAmpecoForTest(before, fixture, '220')!;
      expect(after.name, before.name);
      expect(after.price, before.price);
      expect(after.provider, before.provider);
      expect(after.connectors, before.connectors);
      expect(after.lat, before.lat);
      expect(after.kw, before.kw);
      // ...but the timestamp now reflects this read, not the feed's cycle.
      expect(after.lastUpdated, isNot(before.lastUpdated));
      expect(after.lastUpdated, endsWith(' UTC'));
    });

    test('returns null rather than something wrong when the read is unusable', () {
      // Each of these means "fall back to the feed", which is the behaviour the
      // app had before this path existed. None may render as a real reading.
      expect(svc.applyAmpecoForTest(_station(), fixture, '12345'), isNull,
          reason: 'station not present in the response');
      expect(svc.applyAmpecoForTest(_station(), 'not json at all', '220'), isNull);
      expect(svc.applyAmpecoForTest(_station(), '{"locations":[]}', '220'), isNull);
      expect(
          svc.applyAmpecoForTest(
              _station(), '{"locations":[{"id":220,"zones":[]}]}', '220'),
          isNull,
          reason: 'a location reporting no plugs at all is not worth showing');
    });
  });

  group('canFetchDirect', () {
    test('accepts the AMPECO networks and refuses everyone else', () {
      expect(svc.canFetchDirect(_station()), isTrue);
      expect(
          svc.canFetchDirect(_station(id: 'moveo_6', provider: 'MOVEO')), isTrue);
      // Right provider name, but no operator endpoint behind that id prefix.
      expect(svc.canFetchDirect(_station(id: 'tegeta_38', provider: 'Tegeta')),
          isFalse);
      expect(svc.canFetchDirect(_station(id: '', provider: 'mart EV')), isFalse);
      // A prefix we do know, but under a provider the config does not list.
      expect(
          svc.canFetchDirect(_station(id: 'martev_220', provider: 'Da-Tene')),
          isFalse);
    });
  });

  group('remote kill-switch', () {
    test('a flipped enabled flag stops every direct read', () {
      final off = LiveConfig.fromJson(
          jsonDecode('{"direct_fetch":{"enabled":false,"providers":["mart EV"]}}')
              as Map<String, dynamic>);
      expect(off.directFetchEnabled, isFalse);
    });

    test('dropping one name stops only that network', () {
      final cfg = LiveConfig.fromJson(jsonDecode(
              '{"direct_fetch":{"enabled":true,"providers":["MOVEO"]}}')
          as Map<String, dynamic>);
      expect(cfg.directFetchEnabled, isTrue);
      expect(cfg.directProviders, {'MOVEO'});
      expect(cfg.directProviders.contains('mart EV'), isFalse);
    });

    test('a malformed or empty config leaves direct reads working', () {
      // The switch is for an operator blocking us, not for a broken config file
      // to quietly disable a working feature.
      for (final raw in ['{}', '{"direct_fetch":null}', '{"direct_fetch":42}']) {
        final cfg =
            LiveConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        expect(cfg.directFetchEnabled, isTrue, reason: raw);
        expect(cfg.directProviders, LiveConfig.fallback.directProviders,
            reason: raw);
      }
    });
  });

  group('remote basemap', () {
    test('a template pair from the feed replaces the shipped basemap', () {
      final cfg = LiveConfig.fromJson(jsonDecode(
              '{"basemap":{"light":"https://tiles.example/l/{z}/{x}/{y}.png?key=k",'
              '"dark":"https://tiles.example/d/{z}/{x}/{y}.png?key=k"}}')
          as Map<String, dynamic>);
      expect(cfg.tileLight, 'https://tiles.example/l/{z}/{x}/{y}.png?key=k');
      expect(cfg.tileDark, 'https://tiles.example/d/{z}/{x}/{y}.png?key=k');
    });

    test('overriding one style leaves the other on the shipped one', () {
      final cfg = LiveConfig.fromJson(jsonDecode(
              '{"basemap":{"light":"https://tiles.example/l/{z}/{x}/{y}.png"}}')
          as Map<String, dynamic>);
      expect(cfg.tileLight, isNotNull);
      // Null is the signal for "keep the compiled-in default".
      expect(cfg.tileDark, isNull);
    });

    test('an unusable template is ignored rather than blanking the map', () {
      // This file is hand-edited under pressure, with a broken map as the very
      // thing being fixed. A typo must cost nothing beyond the edit not landing.
      const bad = [
        '"http://tiles.example/{z}/{x}/{y}.png"', // not https
        '"https://tiles.example/{z}/{x}.png"',    // no {y}
        '"https://tiles.example/tiles.png"',      // no placeholders at all
        '""',
        '"   "',
        '42',
        'null',
      ];
      for (final v in bad) {
        final cfg = LiveConfig.fromJson(
            jsonDecode('{"basemap":{"light":$v,"dark":$v}}')
                as Map<String, dynamic>);
        expect(cfg.tileLight, isNull, reason: v);
        expect(cfg.tileDark, isNull, reason: v);
      }
    });

    test('a basemap-only config still leaves direct reads at their defaults',
        () {
      // The two sections are independent: swapping the basemap must not double
      // as a kill-switch for the operator reads sitting next to it.
      final cfg = LiveConfig.fromJson(jsonDecode(
              '{"basemap":{"light":"https://tiles.example/{z}/{x}/{y}.png"}}')
          as Map<String, dynamic>);
      expect(cfg.directFetchEnabled, isTrue);
      expect(cfg.directProviders, LiveConfig.fallback.directProviders);
    });
  });

  group('sameLiveState', () {
    test('spots a plug changing hands', () {
      final free = _station(available: 2, ports: const [
        ConnectorPort(type: 'CCS2', status: 'free'),
        ConnectorPort(type: 'GB/T', status: 'free'),
      ]);
      final busy = _station(available: 1, ports: const [
        ConnectorPort(type: 'CCS2', status: 'busy'),
        ConnectorPort(type: 'GB/T', status: 'free'),
      ]);
      expect(sameLiveState(free, free), isTrue);
      expect(sameLiveState(free, busy), isFalse);
    });

    test('ignores fields that say nothing about availability', () {
      // Otherwise the button would report "Updated" every cycle purely because
      // the feed re-stamped its timestamp, which is the lie being fixed.
      final a = _station(ports: const [ConnectorPort(type: 'CCS2', status: 'free')]);
      final b = a.withLiveStatus(
        available: a.available,
        total: a.total,
        ports: a.ports,
        lastUpdated: '2099-01-01 00:00 UTC',
      );
      expect(sameLiveState(a, b), isTrue);
    });

    test('spots a plug count changing even at the same availability', () {
      expect(
        sameLiveState(_station(available: 1, total: 2), _station(available: 1, total: 4)),
        isFalse,
      );
    });
  });
}
