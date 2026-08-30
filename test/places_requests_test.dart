// What this file checks is the requests that DON'T happen.
//
// Places is billed per request until a session token ties a burst together, and
// the panel's daily quota cap counts raw requests whatever the billing does. So
// the interesting property of PlacesService is not what it returns — it is how
// many times it asks Google to return it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:ev_charger_app/places_service.dart';

void main() {
  // Every request that leaves, in order, so a test can assert both the count
  // and what was actually asked.
  late List<Uri> sent;

  String prediction(String name) => jsonEncode({
        'status': 'OK',
        'predictions': [
          {
            'place_id': 'id-$name',
            'description': '$name, საქართველო',
            'structured_formatting': {
              'main_text': name,
              'secondary_text': 'საქართველო',
            },
          },
        ],
      });

  void answerWith(String body) {
    PlacesService.send = (uri) async {
      sent.add(uri);
      return http.Response(body, 200, headers: {
        'content-type': 'application/json; charset=utf-8',
      });
    };
  }

  setUp(() {
    sent = [];
    PlacesService.resetCache();
    answerWith(prediction('თბილისი'));
  });

  test('a query shorter than the minimum never reaches Google', () async {
    expect(await PlacesService.autocomplete('თ'), isEmpty);
    expect(await PlacesService.autocomplete('თბ'), isEmpty);
    expect(sent, isEmpty);

    expect(await PlacesService.autocomplete('თბი'), isNotEmpty);
    expect(sent, hasLength(1));
  });

  test('the same question is asked once, however often it is typed', () async {
    await PlacesService.autocomplete('თბილისი');
    await PlacesService.autocomplete('თბილისი');
    // Trailing space and capitals are the same question too.
    await PlacesService.autocomplete('  თბილისი ');
    expect(sent, hasLength(1));
  });

  test('backspacing to a query already asked costs nothing', () async {
    await PlacesService.autocomplete('თბილ');
    await PlacesService.autocomplete('თბილი');
    await PlacesService.autocomplete('თბილის');
    expect(sent, hasLength(3));

    // The driver deletes back to where they were.
    await PlacesService.autocomplete('თბილი');
    await PlacesService.autocomplete('თბილ');
    expect(sent, hasLength(3), reason: 'both were answered on the way up');
  });

  test('once Google has nothing, the rest of the typo is free', () async {
    answerWith(jsonEncode({'status': 'ZERO_RESULTS', 'predictions': []}));

    expect(await PlacesService.autocomplete('qqqq'), isEmpty);
    expect(await PlacesService.autocomplete('qqqqw'), isEmpty);
    expect(await PlacesService.autocomplete('qqqqwe'), isEmpty);
    expect(sent, hasLength(1));

    // A different word is still a real question.
    expect(await PlacesService.autocomplete('rrrr'), isEmpty);
    expect(sent, hasLength(2));
  });

  test('a transient failure is retried rather than remembered as empty', () async {
    answerWith(jsonEncode({'status': 'OVER_QUERY_LIMIT'}));
    expect(await PlacesService.autocomplete('თბილისი'), isEmpty);

    answerWith(prediction('თბილისი'));
    expect(await PlacesService.autocomplete('თბილისი'), isNotEmpty);
    expect(sent, hasLength(2), reason: 'the second call must go out');
  });

  test('the same word from another city is a different question', () async {
    const tbilisi = LatLng(41.71, 44.79);
    const batumi  = LatLng(41.64, 41.64);

    await PlacesService.autocomplete('სადგური', bias: tbilisi);
    await PlacesService.autocomplete('სადგური', bias: tbilisi);
    expect(sent, hasLength(1));

    // Bias only ranks predictions, so the order differs and the cache has to
    // notice the move.
    await PlacesService.autocomplete('სადგური', bias: batumi);
    expect(sent, hasLength(2));

    // A few metres of GPS drift is not a move.
    await PlacesService.autocomplete('სადგური',
        bias: const LatLng(41.7104, 44.7912));
    expect(sent, hasLength(2));
  });

  test('a cached answer leaves the billing session untouched', () async {
    final session = PlacesSession();
    final token = session.token;

    await PlacesService.autocomplete('თბილისი', session: session);
    await PlacesService.autocomplete('თბილისი', session: session);

    expect(sent, hasLength(1));
    expect(sent.single.queryParameters['sessiontoken'], token);
    expect(session.token, token, reason: 'only Details ends a session');
  });
}
