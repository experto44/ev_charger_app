# iOS გამოშვების გზამკვლევი (GeoCharge)

ეს დოკუმენტი აღწერს, რა არის საჭირო აპლიკაციის iOS-ზე გასაშვებად და როგორ
ვაქცევთ პროცესს ავტომატურად: **main-ში push → iPhone-ზეც ახალი ვერსია TestFlight-ში.**

---

## 0. რა უკვე გაკეთდა repo-ში (ჩემ მიერ)

- ✅ iOS bundle ID შეიცვალა Android-ის შესაბამისად: `ge.geocharge.app`
- ✅ `codemagic.yaml` — ავტომატური iOS build → TestFlight, main-ზე push-ზე
- ✅ `ios/Runner/Runner.entitlements` — Sign in with Apple-ისთვის (მზად, Xcode-ში მისაბმელი)
- ✅ `google-services.json` და `*.pem` gitignore-ში (ლოკალურად რჩება)

დანარჩენი ნაბიჯები **შენ უნდა გააკეთო** Apple/Codemagic-ის ექაუნთებში — კოდით ვერ კეთდება.

---

## 1. საჭირო ექაუნთები და ფასები

| რა | ფასი | აუცილებელია? |
|---|---|---|
| **Apple Developer Program** | **$99 / წელ** | კი — App Store-ზე გასაშვებად და IAP-ისთვის |
| **Codemagic** | უფასო: 500 build წუთი/თვე (macOS) | კი — შემდეგ $0.095/წუთი ან თვიური გეგმა |
| Apple Pay | — | **არა გვჭირდება** (ქვემოთ ახსნილია რატომ) |

> ⚠️ დარწმუნდი, რომ შენი Apple ექაუნთი არის **Apple Developer Program**-ში ჩარიცხული
> ($99/წ), და არა უბრალო უფასო Apple ID. ამის გარეშე ვერც გამოაქვეყნებ და ვერც
> გამოწერებს გაყიდი.

---

## 2. App Store Connect — აპლიკაციის რეგისტრაცია

1. გადი [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **My Apps → +**
2. შექმენი ახალი აპი:
   - **Bundle ID**: `ge.geocharge.app` (ჯერ Developer portal-ში დაარეგისტრირე — იხ. ქვემოთ)
   - **Name**: GeoCharge
   - **Primary language**: Georgian / English
3. Apple მოგცემს **Apple ID (numeric)** — მაგ. `6749xxxxxx`. ეს ნომერი Codemagic-ს დასჭირდება (`APP_STORE_APPLE_ID`).

**Bundle ID-ის რეგისტრაცია:** [developer.apple.com](https://developer.apple.com/account) → Certificates, IDs & Profiles →
**Identifiers → +** → App IDs → `ge.geocharge.app`. ჩართე capabilities:
- ✅ **Sign in with Apple**
- ✅ **In-App Purchase**
- ✅ **Push Notifications** (თუ მომავალში დაგჭირდება)

---

## 3. Firebase iOS კონფიგი

Android-ს აქვს `google-services.json`; iOS-ს სჭირდება **`GoogleService-Info.plist`**.

1. [Firebase Console](https://console.firebase.google.com) → შენი პროექტი → ⚙ → **Add app → iOS**
2. Bundle ID: `ge.geocharge.app`
3. ჩამოტვირთე `GoogleService-Info.plist`, ჩადე ლოკალურად: `ios/Runner/GoogleService-Info.plist`
4. CI-სთვის გადააქციე base64-ად და ატვირთე Codemagic-ში როგორც `GOOGLE_SERVICE_INFO_PLIST`:
   ```bash
   base64 -i ios/Runner/GoogleService-Info.plist | pbcopy   # Mac
   # Windows (PowerShell):
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("ios/Runner/GoogleService-Info.plist"))
   ```
   > ეს ფაილი `*.plist` არ არის gitignore-ში, მაგრამ ჯობს ლოკალურად დატოვო და CI-ში
   > secure ცვლადად მისცე (ისე როგორც google-services.json).

---

## 4. Code Signing — App Store Connect API Key (ავტომატური ხელმოწერა)

ეს არის Codemagic-ის ყველაზე მნიშვნელოვანი ნაბიჯი. **არ გჭირდება Mac.** Codemagic
თავად შექმნის სერტიფიკატებსა და provisioning profile-ებს ამ key-ით.

1. App Store Connect → **Users and Access → Integrations → App Store Connect API → +**
2. Access: **App Manager** (ან Admin)
3. ჩამოტვირთე **`.p8` ფაილი** (მხოლოდ ერთხელ ჩამოიტვირთება!), დაიმახსოვre:
   - **Issuer ID**
   - **Key ID**
4. Codemagic → **Teams → Integrations → App Store Connect → Add key**:
   - ატვირთე `.p8`, ჩაწერე Issuer ID + Key ID
   - დაარქვი ზუსტად: **`GeoCharge ASC Key`** (ეს სახელი `codemagic.yaml`-შია ჩაწერილი)

---

## 5. Codemagic — repo და ცვლადები

1. [codemagic.io](https://codemagic.io) → **Add application → GitHub → `ev_charger_app`**
2. Codemagic თავად აღმოაჩენს `codemagic.yaml`-ს.
3. **Environment variables → Add group `geocharge_ios`** (ყველა secure/encrypted):
   | ცვლადი | მნიშვნელობა |
   |---|---|
   | `APP_STORE_APPLE_ID` | აპის numeric Apple ID (ნაბიჯი 2) |
   | `APP_VERSION` | marketing ვერსია, მაგ. `1.1.5` |
   | `GOOGLE_SERVICE_INFO_PLIST` | base64 (ნაბიჯი 3) |
4. დაამატე **App Store Connect integration** `GeoCharge ASC Key` (ნაბიჯი 4).

ამის შემდეგ: **main-ში ყოველი push ავტომატურად ააწყობს iOS build-ს და ატვირთავს
TestFlight-ში.** build number ავტომატურად იზრდება (TestFlight-ის ბოლო +1).

---

## 6. Sign in with Apple (სავალდებულო)

რადგან აპს აქვს **Google login** (`google_sign_in`), Apple-ის წესით (Guideline 4.8)
**Sign in with Apple-ის დამატება სავალდებულოა**, თორემ review-ს ვერ გაივლის.

ნაბიჯები:
1. Developer portal-ში App ID-ზე ჩართე **Sign in with Apple** (ნაბიჯი 2). ✅
2. Xcode-ში (ან Mac-ზე ერთხელ): Runner target → Signing & Capabilities → **+ Sign in with Apple**,
   ან Build Settings → `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` (ფაილი უკვე მზადაა).
3. Firebase Console → Authentication → **Sign-in method → Apple → Enable**.
4. კოდში დაემატება ღილაკი `sign_in_with_apple` package-ით (ეს მე გავაკეთებ Flutter-ის მხარეს, როცა ვიტყვი — ცალკე დავალებაა).

---

## 7. გამოწერა (1₾/თვე) — In-App Purchase, NOT Apple Pay

⚠️ **მნიშვნელოვანი:** iOS-ზე ციფრული გამოწერა **სავალდებულოდ Apple In-App Purchase-ით
(StoreKit) უნდა გაიყიდოს**, და **არა Apple Pay-ით**. Apple Pay მხოლოდ ფიზიკურ
საქონელ/მომსახურებაზეა. შენი premium = **auto-renewable subscription** IAP-ით.

კარგი ამბავი: კოდი უკვე იყენებს `in_app_purchase` package-ს, რომელიც iOS StoreKit-საც
უჭერს მხარს — ანუ დიდი კოდი არ იცვლება. საჭიროა მხოლოდ:

1. App Store Connect → შენი აპი → **Subscriptions** → შექმენი:
   - Subscription Group (მაგ. "GeoCharge Premium")
   - Auto-renewable subscription, **Product ID** (იგივე ან iOS-ვერსია იმ ID-ისა, რასაც
     Android იყენებს — შევამოწმებთ კოდში)
   - ფასი: 1₾-ის ეკვივალენტი (Apple-ის ფასების ცხრილიდან)
2. **Paid Apps Agreement** ხელი მოაწერე (ნაბიჯი 8) — ამის გარეშე IAP არ მუშაობს.
3. Sandbox tester შექმენი ტესტირებისთვის (Users and Access → Sandbox Testers).

---

## 8. ფული საიდან მოდის (payout) 💰

ეს არის შენი კითხვა "ფულს მერე საიდან ვიღებ". პროცესი:

1. **Apple აგროვებს ფულს** მომხმარებლისგან (ბარათით/Apple ანგარიშით).
2. **Apple იღებს საკომისიოს:**
   - **15%** — თუ წელიწადში $1M-ზე ნაკლებს გამოიმუშავებ (**Small Business Program** — ჩაეწერე! [აქ](https://developer.apple.com/app-store/small-business-program/))
   - 30% — სტანდარტული (თუ არ ჩაეწერები / $1M-ზე მეტი)
3. **დანარჩენს Apple გიგზავნის შენს ბანკში** ყოველთვიურად (დაახ. თვის დახურვიდან
   ~33-45 დღეში), მინიმალური ზღვრის გადაცილების შემდეგ.

ამისთვის App Store Connect-ში შეავსე **Agreements, Tax, and Banking**:
- ✅ **Paid Apps Agreement** — ხელმოწერა
- ✅ **Bank account** — შენი ბანკის IBAN (საქართველოს ბანკი/TBC მუშაობს)
- ✅ **Tax forms** — საქართველოსთვის **W-8BEN** (აშშ-ის გადასახადის თავიდან ასაცილებლად)

> ანუ: მომხმარებელი იხდის → Apple იჭერს 15-30%-ს → დანარჩენი ყოველთვიურად შენს IBAN-ზე.

---

## 9. ვერსიების სინქრონი (რეკომენდაცია)

ახლა Android-ის ვერსია `android/app/build.gradle`-შია ხელით ჩაწერილი
(`versionCode`/`versionName`), iOS კი `APP_VERSION`-ს იღებს Codemagic-იდან.

**რეკომენდაცია:** გადავიყვანოთ ორივე ერთ წყაროზე — `pubspec.yaml`-ის `version:`-ზე
(მაგ. `1.1.5+17`). მაშინ ერთ ადგილას bump = ორივე პლატფორმა განახლდება. ეს ცალკე
პატარა refactor-ია; თუ მინდა, გავაკეთებ.

---

## 10. მოკლე checklist (რიგით)

- [ ] Apple Developer Program აქტიური ($99/წ)
- [ ] Bundle ID `ge.geocharge.app` + capabilities (Developer portal)
- [ ] App record App Store Connect-ში → numeric Apple ID
- [ ] `GoogleService-Info.plist` (Firebase iOS) ლოკალურად + base64 Codemagic-ში
- [ ] App Store Connect API key (.p8) → Codemagic integration "GeoCharge ASC Key"
- [ ] Codemagic-ში repo + `geocharge_ios` ცვლადების group
- [ ] Firebase Apple sign-in ჩართული
- [ ] Subscription product + Paid Apps Agreement + Banking/Tax
- [ ] პირველი push main-ში → TestFlight build ✅

ამის შემდეგ პროცესი სრულად ავტომატურია.
