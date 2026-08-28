import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Text shared into GeoCharge from another app.
///
/// Today that means one thing: a route shared out of Google Maps, which is a
/// plain text share containing a maps.app.goo.gl link. Android side lives in
/// MainActivity.kt.
///
/// iOS is not wired up. Appearing in its share sheet needs a Share Extension —
/// a separate app target with its own bundle id, App Group and provisioning
/// profile — so on iOS the driver pastes the link instead (Profile → Tesla).
class SharedLinkService {
  SharedLinkService._();

  static const _channel = MethodChannel('ge.geocharge.app/share');

  /// A Google Maps link somewhere in shared text. Share sheets often send a
  /// sentence with the link in it rather than the bare URL, so this digs it out
  /// rather than expecting the whole string to be one.
  static String? mapsLinkIn(String? text) {
    if (text == null || text.isEmpty) return null;
    // Host shapes must match what functions/google-route.js will accept, or the
    // app rejects a link the server would have read. `maps.google.com` is the
    // one that used to be missing here.
    //
    // The last alternative is the old query form an iPhone shares
    // (`maps.google.com/?saddr=…&daddr=…`), which has no `/maps` in its path at
    // all. A short link never arrives in that shape, but a link copied out of a
    // browser does.
    final m = RegExp(
      r'https://(?:maps\.app\.goo\.gl/\S+'
      r'|goo\.gl/maps/\S+'
      r'|(?:(?:www|maps)\.)?google\.[a-z.]{2,6}'
      r'(?:/maps\S*|/?\?\S*daddr=\S*))',
    ).firstMatch(text);
    // Share text is prose as often as not: "look at this (<link>)." would
    // otherwise carry the bracket and full stop into the URL.
    return m?.group(0)?.replaceAll(RegExp(r'[).,;!\]]+$'), '');
  }

  /// Start listening. [onLink] fires for every Google Maps link that arrives,
  /// including one that cold-started the app.
  ///
  /// Safe to call on iOS: nothing is registered there, so it simply never
  /// fires.
  static void start(void Function(String url) onLink) {
    if (!Platform.isAndroid) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'sharedText') return null;
      final url = mapsLinkIn(call.arguments as String?);
      if (url != null) onLink(url);
      return null;
    });

    // A cold start delivered the share before Dart was listening; MainActivity
    // held it for exactly this call.
    _channel.invokeMethod<String>('initialSharedText').then((text) {
      final url = mapsLinkIn(text);
      if (url != null) onLink(url);
    }).catchError((Object e) {
      debugPrint('[SharedLink] initial read failed: $e');
      return null;
    });
  }
}
