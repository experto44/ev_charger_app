# Branded email verification (noreply@geocharge.ge)

Replaces Firebase's default, spam-prone verification email with a branded HTML
email sent from **noreply@geocharge.ge** through **Zoho SMTP**, delivered by the
`sendVerificationEmail` Cloud Function.

- Function + template: [`functions/index.js`](functions/index.js),
  [`functions/email_template.js`](functions/email_template.js)
- App side: `AuthService._sendBrandedVerification()` in
  [`lib/services/auth_service.dart`](lib/services/auth_service.dart) — called on
  registration and on "resend". Falls back to Firebase's default email if the
  function is unreachable, so a user is never left unable to verify.

The email design is standard, table-based, inline-CSS HTML that renders in Gmail,
Apple Mail, Outlook, etc. **Deliverability (staying out of spam) depends far more
on the DNS records below than on the code** — do not skip step 2.

**Link domain:** the generated link's host is rewritten in code
([`functions/index.js`](functions/index.js), `LINK_DOMAIN`) from the default
`geocharge-f6714.firebaseapp.com` to **`geocharge.ge`**, which serves the same
Firebase auth action handler (`/__/auth/action`) and is an authorized domain. No
Console "Action URL" change is needed. Requires `geocharge.ge` in Authentication
→ Settings → Authorized domains (already added).

---

## Prerequisites (one-time, done by you)

### 1. Zoho Mail on geocharge.ge

Free Zoho plan supports one domain per organisation, so geocharge.ge needs its
own Zoho org (bugalteri's org can't host a second domain on the free tier).

1. Sign up at <https://www.zoho.com/mail/> → add domain `geocharge.ge`.
2. Create the mailbox **`noreply@geocharge.ge`**.
3. Generate an **app-specific password** for it
   (Zoho → My Account → Security → App Passwords). This is what SMTP uses — not
   the login password.
4. Note your Zoho region — it sets the SMTP host and the SPF include:
   - EU: `smtp.zoho.eu`, SPF `include:zoho.eu`
   - US: `smtp.zoho.com`, SPF `include:zoho.com`

The function defaults to `smtp.zoho.eu:465`. If your account is US, override at
deploy (see step 4).

### 2. DNS records on geocharge.ge (the anti-spam part)

Add these at wherever geocharge.ge DNS is hosted. Zoho shows the exact values in
its setup wizard — use those; the below is the shape.

| Type | Host | Value |
|------|------|-------|
| TXT  | `@` (geocharge.ge) | `v=spf1 include:zoho.eu ~all` |
| TXT  | `zmail._domainkey` | (DKIM key Zoho gives you) |
| TXT  | `_dmarc`           | `v=DMARC1; p=none; rua=mailto:postmaster@geocharge.ge` |

Notes:
- If a SPF TXT record already exists on `@`, **merge** the include into the
  existing one — never publish two SPF records.
- After adding, verify the domain + enable DKIM inside Zoho's console. DKIM must
  show "verified" before deliverability is reliable.
- MX records are only needed if you also want to *receive* mail at geocharge.ge;
  sending works without them.

### 3. Firebase Blaze plan

Cloud Functions require the pay-as-you-go **Blaze** plan (a generous free tier
still applies). Upgrade at Firebase Console → project `geocharge-f6714` → Usage
and billing. Also confirm the sender domain / Firebase action-link domain is
authorised under Authentication → Settings → Authorized domains (defaults are
already authorised).

---

## Deploy

From the project root, with the Firebase CLI logged in:

```bash
cd functions
npm install
cd ..

# Store SMTP credentials as secrets (prompts for the value each time):
firebase functions:secrets:set ZOHO_USER      # → noreply@geocharge.ge
firebase functions:secrets:set ZOHO_PASS      # → the Zoho app password

firebase deploy --only functions
```

`ZOHO_USER` / `ZOHO_PASS` are secrets and never live in source. The SMTP host
is hardcoded in [`functions/index.js`](functions/index.js) as `smtp.zoho.eu`
(EU region — confirmed working). **US Zoho accounts**: change the `ZOHO_HOST`
constant there to `smtp.zoho.com` and redeploy.

After deploying, `flutter pub get` is already done — rebuild the app and register
a test account to confirm the branded email arrives from noreply@geocharge.ge.

---

## Verifying it works

1. Register a fresh account in the app.
2. The email should arrive from `GeoCharge <noreply@geocharge.ge>`, land in the
   inbox (not spam), and its "ელფოსტის დადასტურება" button should verify the
   address.
3. Check function logs on failure: `firebase functions:log` (or
   `cd functions && npm run logs`). SMTP-auth errors mean the app password /
   host / region is wrong; delivery-to-spam means DNS (SPF/DKIM/DMARC) isn't
   fully propagated/verified yet.
4. Test in Gmail's "Show original" to confirm SPF=pass, DKIM=pass, DMARC=pass.
