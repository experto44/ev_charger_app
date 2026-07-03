# GeoCharge Admin Panel

Flutter Web admin dashboard for GeoCharge. Reads the same Firebase project as
the mobile app (`geocharge-f6714`) and shows registered users, usage analytics,
and an Excel export — gated to allow-listed admin accounts.

## What it does
- **Google sign-in**, restricted to emails in the Firestore `admins` collection.
- **User list** — name, phone, email, status (Premium / Free-ads), platform
  (Android/iOS), registration date, last active, average opens/day.
- **Analytics** — totals (users, premium, free, Android, iOS) + a 30-day
  new-registrations chart.
- **Filters** — search (name/email/phone), status, platform, registration-date
  range.
- **Excel export** — downloads the currently-filtered users as `.xlsx`.
- **Admin management** — add/remove other admins by email.

## Data source
Everything comes from Firestore `users/{uid}`. The mobile app writes these
fields (see `lib/services/user_activity_service.dart` in the main app):
`name, email, phoneNumber, isPremium, platform, createdAt, lastSeenAt, openCount`.

> ⚠️ Analytics fields only exist for accounts active since the tracking release
> (app **v1.1.14+26**). Older accounts backfill `createdAt`/`platform` on their
> next app open, so early numbers ramp up over time.

## Local dev
```bash
cd admin
flutter run -d chrome
```
`localhost` is an authorized Firebase Auth domain by default, so Google sign-in
works locally. You still need to be in the `admins` list to pass the gate.

## Build
```bash
cd admin
flutter build web --release
# output: admin/build/web  (deployed by the root firebase.json hosting config)
```

See `../ADMIN_PANEL_SETUP.md` for full first-time deploy + custom-domain steps.
