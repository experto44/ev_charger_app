## Release Signing
- Keystore: `android/upload-keystore.jks`
- Key alias: `upload`
- Passwords stored in: `android/key.properties`
- Certificate: CN=GeoCharge, valid to 2053
- Always use `signingConfigs.release` for AAB/APK release builds
- `key.properties` and `upload-keystore.jks` are gitignored — they stay local only
