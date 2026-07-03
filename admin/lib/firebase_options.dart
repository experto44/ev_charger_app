import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

/// Firebase web configuration for the GeoCharge admin panel.
///
/// Reuses the same Firebase project as the mobile app (`geocharge-f6714`) and
/// its already-registered Web app, so the panel authenticates against the same
/// user pool and reads the same Firestore data.
class DefaultFirebaseOptions {
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyC3gB4qBlgYW7_nLd8JZijyha0xXekGuaE',
    appId: '1:518875377655:web:460e04cac1603f2545c8f2',
    messagingSenderId: '518875377655',
    projectId: 'geocharge-f6714',
    authDomain: 'geocharge-f6714.firebaseapp.com',
    storageBucket: 'geocharge-f6714.firebasestorage.app',
    measurementId: 'G-3DK8B61WL8',
  );
}
