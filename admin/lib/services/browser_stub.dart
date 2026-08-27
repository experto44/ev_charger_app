/// Non-web stand-in for [browser.dart]'s API, used when the panel's code is
/// compiled off the web — in practice, `flutter test` on the VM. Nothing here
/// is reachable in production; it exists so the screens can be rendered in a
/// widget test at all.
library;

String? readLocal(String key) => null;

void writeLocal(String key, String value) {}

void downloadBytes(List<int> bytes, String filename, String mimeType) {}
