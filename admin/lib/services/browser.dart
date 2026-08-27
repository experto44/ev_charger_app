/// Browser-only capabilities the panel needs (localStorage, file download),
/// behind a conditional import.
///
/// Without this indirection every library that reaches `package:web` — the
/// finance config and the Excel export, and therefore the whole dashboard —
/// fails to compile under `flutter test` on the VM, which left the screens
/// untestable. The stub keeps them compiling; the real implementation is picked
/// automatically for a web build.
library;

export 'browser_stub.dart' if (dart.library.js_interop) 'browser_web.dart';
