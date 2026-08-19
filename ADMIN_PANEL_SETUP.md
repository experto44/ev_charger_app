# GeoCharge Admin Panel — Setup & Deployment

This guide covers everything needed to get **admin.geocharge.ge** live. Steps
marked **[YOU]** need your accounts/access; the code is already done.

---

## Overview of what was built
1. **App tracking** (main app) — new `lib/services/user_activity_service.dart`
   records `name, platform, createdAt, lastSeenAt, openCount` into
   `users/{uid}`. Wired into login/registration + app open/resume. Version
   bumped to **1.1.14+26**.
2. **Firestore rules** — `firestore.rules`: users read only their own doc;
   allow-listed admins read all users + manage the admin list.
3. **Admin panel** — `admin/` Flutter Web app (Google login, user table,
   analytics, filters, Excel export, admin management).
4. **Hosting/rules config** — root `firebase.json` deploys both rules and the
   `admin/build/web` output.

---

## Step 1 — Release the app update (starts data collection) **[YOU]**
Analytics only accrues once users run the tracked build. Ship **v1.1.14+26** via
your normal process (build AAB / iOS, upload to Play Console / TestFlight).
Nothing else in the app changed. The sooner it's out, the sooner the panel fills
with real data.

## Step 2 — Install Firebase CLI (once) **[YOU]**
```bash
npm install -g firebase-tools
firebase login          # log in with the Google account that owns geocharge-f6714
```

## Step 3 — Deploy the Firestore security rules **[YOU]**
From the repo root (`D:\flutter\ev_charger_app`):
```bash
firebase deploy --only firestore:rules --project geocharge-f6714
```
> These rules replace whatever is currently in the Firebase console. They keep
> the mobile app working (each user still reads/writes only their own doc) and
> add admin read access.

## Step 4 — Create the FIRST admin (bootstrap) **[YOU]**
The rules forbid writing `admins` unless you're already an admin, so the first
one must be added by hand:

1. Firebase Console → **Firestore Database** → **Start collection**.
2. Collection ID: `admins`
3. **Document ID:** `miruashvili.k@gmail.com`  ← must be the exact, lowercase
   Google account email you'll sign in with.
4. Add any one field (e.g. `addedAt` = current date) — the document just needs
   to exist. Save.

After this, you can add every other admin from inside the panel.

## Step 5 — Confirm Google sign-in is enabled **[YOU]**
Firebase Console → **Authentication** → **Sign-in method** → **Google** should
be **Enabled** (it already is, since the mobile app uses Google sign-in).

## Step 6 — Build & deploy the panel **[YOU]**
```bash
cd admin
flutter build web --release
cd ..
firebase deploy --only hosting --project geocharge-f6714
```
This publishes to `https://geocharge-f6714.web.app`. Open it and sign in with
`miruashvili.k@gmail.com` to verify the dashboard loads.

> Tip: you can deploy rules + hosting together with
> `firebase deploy --only firestore:rules,hosting --project geocharge-f6714`.

## Step 7 — Connect the custom domain admin.geocharge.ge **[YOU]**
1. Firebase Console → **Hosting** → **Add custom domain** → enter
   `admin.geocharge.ge`.
2. Firebase shows you a DNS record to add (usually a **CNAME** `admin` →
   `<something>.web.app`, or two **A records** with IPs).
3. Go to **proservice.ge** DNS management for `geocharge.ge` and add exactly
   that record:
   - Type: **CNAME** (or A, as Firebase specifies)
   - Host/Name: `admin`
   - Value: the target Firebase gave you
4. Back in Firebase, click **Verify**. SSL is provisioned automatically
   (can take 15 min – a few hours).

> Your main site on Netlify (`geocharge.ge`) is untouched — this only adds the
> `admin` subdomain pointing at Firebase Hosting.

## Step 8 — Authorize the domain for sign-in **[YOU]**
Firebase Console → **Authentication** → **Settings** → **Authorized domains** →
**Add domain** → `admin.geocharge.ge`. (Also add it if you test on any other
host.) Without this, Google sign-in popups are blocked on the custom domain.

---

## Done. Day-to-day use
- Go to **admin.geocharge.ge**, sign in with an admin Google account.
- Filter by status / platform / registration date, search by name/phone/email.
- **Export Excel** downloads exactly the filtered rows.
- **Manage admins** (top-right icon) to add/remove other admins.

---

## Manual premium (users who paid you directly)

Some users can't complete the in-app purchase and transfer the money to you
instead. The **Premium** tab activates their subscription by hand.

**Granting**
- *Premium* tab → **Activate premium** → search the user → pick **1 month** or
  **1 year**, enter the amount received (GEL) and an optional note → *Activate*.
- The same button sits on every row of the *Users* tab (the card icon), so you
  can grant straight from a search result.
- Time is **added** to whatever is left: re-activating someone with 10 days
  remaining gives them 10 days + the new term. The dialog shows the resulting
  date before you confirm.

**What happens under the hood**
- `users/{uid}` gets `isPremium: true`, `premiumUntil`, `premiumSource: manual`,
  plus who granted it, when, and the note.
- The app reads `isPremium` from Firestore on every launch, so ads stop on the
  user's next app open. **No app update is needed** — nothing in the mobile app
  changed for this feature.
- The `expireManualPremium` Cloud Function runs hourly, and once `premiumUntil`
  passes it sets `isPremium: false` again. The ad-supported version returns on
  the user's next launch. Store subscriptions (`premiumSource != manual`) are
  never touched by it.
- If you entered an amount, a row is written to `purchases` with
  `platform: manual` and **0 % commission** (no store took a cut), so the
  *Finance* tab still reconciles. Filter it with the *Manual (bank)* platform.

**Ending early:** the red *End now* button on a Premium-tab row drops the user
back to free immediately. Recorded revenue is kept.

**Deploying this feature** (rules + the expiry job + the panel):
```bash
firebase deploy --only firestore:rules,functions:expireManualPremium --project geocharge-f6714
cd admin && flutter build web --release && cd ..
firebase deploy --only hosting --project geocharge-f6714
```
The first deploy of the scheduled function creates a Cloud Scheduler job — this
requires the **Blaze** plan (the project is already on it for the verification
emails).

## Redeploying after code changes
```bash
cd admin && flutter build web --release && cd ..
firebase deploy --only hosting --project geocharge-f6714
```

## Notes & limitations
- **Historical data:** registration date / device can't be recovered for users
  who existed before v1.1.14+26; they backfill on their next app open.
- **"Opens/day"** = `openCount ÷ days since registration`. An open is counted at
  most once per 10 minutes (so quick app-switching doesn't inflate it).
- **Scale:** the panel loads the full `users` collection client-side — perfect
  for the current user base. If it grows into tens of thousands, switch to
  paginated/server-side queries (and possibly Cloud Functions).
- **Cost:** Firebase Hosting + the Firestore reads fit the free tier at this
  scale. The one scheduled function (`expireManualPremium`) needs the Blaze plan
  — already enabled for the branded verification emails — and costs cents: an
  hourly run over a range query that returns only already-expired documents.
- **Manual expiry timing:** the sweep runs hourly, and the app only re-reads
  `isPremium` when it launches, so ads can come back up to an hour (plus the
  user's next app open) after the date. The panel itself computes the status
  from `premiumUntil`, so it never shows a lapsed grant as Premium.
