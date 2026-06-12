## Release Signing
- Keystore: `android/upload-keystore.jks`
- Key alias: `upload`
- Passwords stored in: `android/key.properties`
- Certificate: CN=GeoCharge, valid to 2053
- Always use `signingConfigs.release` for AAB/APK release builds
- `key.properties` and `upload-keystore.jks` are gitignored — they stay local only

## Version Management
- Current versionCode: 12, versionName: "1.1.0"
- Always increment versionCode by 1 and bump versionName patch digit for every new release build
- After every release build, update this file with the new versionCode and versionName
- Required permissions: `com.google.android.gms.permission.AD_ID` must always be present in AndroidManifest.xml (AdMob requirement)
