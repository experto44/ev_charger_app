# Release notes — 1.1.48 (build 60)

Written for drivers, not developers: what changed for them, no mechanics.
Google Play caps "What's new" at 500 characters per language; the App Store
allows 4000. Both versions below are within their limit.

One user-facing change: Android stays signed in.

**This can ship to Android only.** The bug was in the Firebase Android auth
library, so nothing in this build changes anything an iPhone user can see, and
an iOS submission would only spend Codemagic minutes. See the CI cost note in
CLAUDE.md.

Worth saying out loud in the store text: after installing this update people
have to sign in one more time. The old, unreadable session record is still on
their device and no version can decrypt it. Saying so up front is better than
letting them meet one more unexplained login screen.

---

## Google Play — ქართული

გასწორდა: აპლიკაცია ყოველ გახსნაზე ხელახლა ითხოვდა ანგარიშში შესვლას, თუმცა პრემიუმი და ფილტრები ადგილზე რჩებოდა.

ახლა ერთხელ შედიხართ და ანგარიში ისე რჩება, აპლიკაციის დახურვის შემდეგაც.

ამ განახლების შემდეგ ერთხელ კიდევ მოგიწევთ შესვლა. ეს უკანასკნელია.

---

## Google Play — English

Fixed: the app asked you to sign in again every single time you opened it, even
though your premium and filters were still there.

You now sign in once and stay signed in, including after you close the app.

You will need to sign in one more time after this update. That is the last one.

---

## App Store — English only

No user-visible changes on iPhone in this build. iPhone was never affected by
the sign-in bug this release fixes; it lived in the Android Firebase library.

If this version is submitted anyway (for example to keep both stores on the same
build number), the store text can stay:

• Stability and reliability improvements.
