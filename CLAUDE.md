## Release Signing
- Keystore: `android/upload-keystore.jks`
- Key alias: `upload`
- Passwords stored in: `android/key.properties`
- Certificate: CN=GeoCharge, valid to 2053
- Always use `signingConfigs.release` for AAB/APK release builds
- `key.properties` and `upload-keystore.jks` are gitignored — they stay local only

## Version Management
- Single source of truth: `pubspec.yaml` → `version: <name>+<code>` (currently `1.1.7+19`)
- Android `build.gradle` reads it via `flutterVersionCode/Name`; iOS reads it too — bump pubspec ONLY
- For every release: bump the build number (+N) by 1 and the patch digit of the name; both platforms stay in sync
- Codemagic uses the same pubspec version for iOS (build name); iOS build number auto-increments from TestFlight
- Required permissions: `com.google.android.gms.permission.AD_ID` must always be present in AndroidManifest.xml (AdMob requirement)

## CI Cost Guard — read before touching CI
Codemagic iOS builds run on `mac_mini_m2` and are **billed per minute**. A missing trigger filter
already cost $50 in builds nobody wanted, so:
- `codemagic.yaml` → `ios-release.when.changeset.includes` is an **allow-list**. Only `lib/`, `ios/`,
  `assets/`, `pubspec.yaml`, `pubspec.lock`, `codemagic.yaml` may trigger a build. Never widen it,
  and never remove it "temporarily".
- `.github/workflows/rebuild_charger_pages.yml` **pushes commits to `main`** on a nightly cron.
  Anything that triggers on push to `main` therefore fires once a day for free-of-charge reasons.
- Before adding ANY workflow, cron, or bot that commits to `main`, check what that push triggers
  downstream — GitHub webhooks reach Codemagic even for `github-actions[bot]` pushes.
- Before adding or editing a build trigger, state in the PR/commit exactly which commits will now
  build. If the answer is "every push", that is a bug, not a default.
