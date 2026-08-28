import 'package:flutter_test/flutter_test.dart';
import 'package:ev_charger_app/services/shared_link_service.dart';

// The share sheet hands us prose, not a URL. These are the shapes that have to
// keep working, and the host list has to stay in step with the allow-list in
// functions/google-route.js — a link the server would read must not be
// rejected here.
void main() {
  test('pulls a short link out of shared text', () {
    expect(SharedLinkService.mapsLinkIn('https://maps.app.goo.gl/3KZmvbZU46qC4fxt5'),
        'https://maps.app.goo.gl/3KZmvbZU46qC4fxt5');
    expect(SharedLinkService.mapsLinkIn('სარფი https://maps.app.goo.gl/abc?g_st=ac'),
        'https://maps.app.goo.gl/abc?g_st=ac');
    expect(SharedLinkService.mapsLinkIn('ბათუმი\nhttps://maps.app.goo.gl/abc123\n'),
        'https://maps.app.goo.gl/abc123');
  });

  test('accepts every host the Cloud Function accepts', () {
    expect(SharedLinkService.mapsLinkIn('https://www.google.com/maps/dir/A/B'), isNotNull);
    expect(SharedLinkService.mapsLinkIn('https://google.de/maps/dir/A/B'), isNotNull);
    expect(SharedLinkService.mapsLinkIn('https://maps.google.com/maps/dir/A/B'), isNotNull);
    expect(SharedLinkService.mapsLinkIn('https://goo.gl/maps/abc'), isNotNull);
  });

  test('drops trailing prose punctuation', () {
    expect(SharedLinkService.mapsLinkIn('look (https://maps.app.goo.gl/abc123).'),
        'https://maps.app.goo.gl/abc123');
  });

  test('ignores anything that is not Google Maps', () {
    expect(SharedLinkService.mapsLinkIn('https://example.com/maps/dir/x'), isNull);
    expect(SharedLinkService.mapsLinkIn('no link at all'), isNull);
    expect(SharedLinkService.mapsLinkIn(''), isNull);
    expect(SharedLinkService.mapsLinkIn(null), isNull);
  });
}
