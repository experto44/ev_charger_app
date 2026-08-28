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

  // The shape an iPhone's share link expands to. Nobody shares one of these
  // directly, but copying it out of a browser is a fair thing to do, and the
  // server reads it.
  test('accepts the old query form, which has no /maps in its path', () {
    const url = 'https://maps.google.com/?geocode=Fbfc%3D%3D;FUeP%3D%3D'
        '&daddr=Sarpi&saddr=41.6718630,44.8671428&dirflg=d';
    expect(SharedLinkService.mapsLinkIn(url), url);
    expect(
        SharedLinkService.mapsLinkIn('https://www.google.com/?daddr=Batumi'), isNotNull);
    // A Google link with no route in it is still not ours to open.
    expect(SharedLinkService.mapsLinkIn('https://www.google.com/?q=batumi'), isNull);
    expect(SharedLinkService.mapsLinkIn('https://www.google.com/search?q=daddr'), isNull);
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
