## Release Signing
- Keystore: `android/upload-keystore.jks`
- Key alias: `upload`
- Passwords stored in: `android/key.properties`
- Certificate: CN=GeoCharge, valid to 2053
- Always use `signingConfigs.release` for AAB/APK release builds
- `key.properties` and `upload-keystore.jks` are gitignored — they stay local only

## Version Management
- Single source of truth: `pubspec.yaml` → `version: <name>+<code>` (currently `1.1.6+18`)
- Android `build.gradle` reads it via `flutterVersionCode/Name`; iOS reads it too — bump pubspec ONLY
- For every release: bump the build number (+N) by 1 and the patch digit of the name; both platforms stay in sync
- Codemagic uses the same pubspec version for iOS (build name); iOS build number auto-increments from TestFlight
- Required permissions: `com.google.android.gms.permission.AD_ID` must always be present in AndroidManifest.xml (AdMob requirement)
