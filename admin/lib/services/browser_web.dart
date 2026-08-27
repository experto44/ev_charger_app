import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Real browser implementation of [browser.dart]'s API. Only compiled into a
/// web build.

/// Read a persisted string, or `null` when absent/unavailable.
String? readLocal(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null; // localStorage blocked (private mode, embedded frame)
  }
}

/// Persist a string. Best-effort — a failed save just means it won't survive a
/// reload.
void writeLocal(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } catch (_) {/* ignored on purpose */}
}

/// Save [bytes] to the user's machine via an object-URL anchor click.
void downloadBytes(List<int> bytes, String filename, String mimeType) {
  final data = Uint8List.fromList(bytes).toJS;
  final blob = web.Blob(<JSAny>[data].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
