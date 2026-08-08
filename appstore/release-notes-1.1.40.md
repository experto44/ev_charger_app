# GeoCharge 1.1.40+52 — release notes

Store fields have limits: Google Play allows 500 characters per language, the
App Store 4000. The short version below fits Play; the full version is for the
App Store and for the website / social posts.

This release is bug fixes only. Everything that shipped in 1.1.39 (Turkey) is
unchanged.

---

## ქართული — მოკლე (Play Store, 338 სიმბოლო)

```
შესვლა აღარ იკარგება

• ანდროიდზე აპლიკაციის დახურვის შემდეგ პროფილი ხელახლა შესვლას აღარ ითხოვს. ანგარიში ისევე რჩება, როგორც აიფონზე
• პროვაიდერების ფილტრი ახლა ინახება. ბოლოს მონიშნული არჩევანი გახსნისას დაგხვდებათ
• თურქეთი ნაგულისხმევად აღარ არის მონიშნული. ის მხოლოდ მაშინ ირთვება, როცა პარამეტრებში ქვეყნების სიას თურქეთს დაამატებთ
```

## English — short (Play Store, 364 characters)

```
Signing in sticks

• On Android, closing the app no longer sends you back to the login screen. Your account stays put, the way it already did on iPhone
• The provider filter is remembered. Whatever you last ticked is still ticked when you reopen the app
• Turkey is no longer selected by default. It turns on only after you add Turkey to your countries in Settings
```

---

## ქართული — სრული

```
შესვლა აღარ იკარგება

ეს განახლება ხარვეზებს ასწორებს. 1.1.39-ის თურქეთი უცვლელია.

რა გასწორდა

ანდროიდზე ხელახალი შესვლა. აპლიკაციის დახურვის ან მოკვლის შემდეგ, პროფილში
შესვლისას, ხელახლა ითხოვდა Google-ით შესვლას. ანგარიში სინამდვილეში არსად
იკარგებოდა. საქმე დროში იყო: ანდროიდი შენახულ სესიას აპლიკაციის გაშვების შემდეგ
აღადგენს და ამას წამის ნაწილი სჭირდება, აპლიკაცია კი ამ დროს უკვე ასკვნიდა, რომ
გამოსული ხართ. სწორედ ამიტომ პრემიუმი აქტიური რჩებოდა, შესვლა კი მოთხოვნილი იყო.
ახლა აპლიკაციამ იცის, რომ სესია მოსალოდნელია და ელოდება მის აღდგენას. აიფონზე ეს
ხარვეზი არასდროს ყოფილა.

პროვაიდერების ფილტრი ინახება. აქამდე ფილტრი მხოლოდ იმ სესიაში მუშაობდა და ყოველი
გახსნისას თავიდან იწყებოდა. ახლა ბოლოს მონიშნული არჩევანი ინახება და გახსნისას
ისევ ისე დაგხვდებათ, როგორც დატოვეთ.

თურქეთი მხოლოდ თქვენი გადაწყვეტილებით. თურქეთის რიგი პროვაიდერების სიაში
ნაგულისხმევად მონიშნული იყო, თუმცა ეს რამდენიმე მეგაბაიტიანი რეესტრია და ყველას არ
სჭირდება. ახლა ის ჩამქრალია მანამ, სანამ პარამეტრებში ქვეყნების სიას თურქეთს არ
დაამატებთ. მხოლოდ ამის შემდეგ შეგიძლიათ მონიშნოთ. თუ ქვეყნებიდან თურქეთს მოხსნით,
პროვაიდერიც თავისით გამოირთვება.
```

## English — full

```
Signing in sticks

This release is bug fixes only. The Turkish coverage from 1.1.39 is unchanged.

What we fixed

Signing in again on Android. After closing or killing the app, opening Profile
asked you to sign in with Google all over again. Your account was never actually
lost. It was a timing problem: Android restores the saved session a moment after
the app starts, and the app was concluding you were signed out before that
finished. That is also why premium stayed active while the login screen appeared,
which never made sense. The app now knows when a session is expected and waits
for it. iPhone never had this bug.

The provider filter is remembered. It used to live only for as long as the app
was open, so every launch started from scratch. Your last selection is now saved
and restored exactly as you left it.

Turkey only when you say so. The Turkey row in the provider list was ticked by
default, even though it is a multi-megabyte registry that most people never need.
It is now greyed out until you add Turkey to your countries in Settings, and only
then can you tick it. Remove Turkey from your countries and the provider switches
itself off again.
```

---

# App Store submission — 1.1.39 + 1.1.40 combined

1.1.39 never shipped to the App Store, so 1.1.40 is the first iOS build with
Turkey in it. Use the two blocks below for the App Store, **not** the 1.1.40-only
ones above. Google Play already has 1.1.39, so Play keeps the short 1.1.40 notes.

Two deliberate differences from a plain concatenation:

- **The Android sign-in fix is left out.** iPhone never had that bug, so on the
  App Store it would only confuse people.
- **The "how to turn it on" step changed.** 1.1.39 said Settings → countries →
  Turkey and you were done. Since 1.1.40 that is only step one: Turkey also has
  to be ticked in the provider filter. Copying the old wording would send every
  iOS user to an empty map.

## ქართული — App Store

```
თურქეთი GeoCharge-ში

ქართველები ხშირად მოგზაურობენ თურქეთში, ამიტომ თურქეთის დაფარვა თავიდან ავაწყვეთ.

რა შეიცვალა

13,296 დამტენი მთელ თურქეთში. აქამდე 2,110 გვქონდა. მონაცემები EPDK-ის, თურქეთის
ენერგეტიკის მარეგულირებლის, ოფიციალური რეესტრიდან მოდის, სადაც ქვეყნის ყველა საჯარო
დამტენი სავალდებულოდ არის რეგისტრირებული. კერძო დამტენები, რომლებითაც ვერ ისარგებლებთ,
რუკაზე არ ჩანს.

პროვაიდერის სახელი და ტარიფი. ყველა დამტენს აწერია ქსელის სახელი, ZES, Trugo, Eşarj,
Voltrun და სხვა. დამტენების 68 პროცენტს ტარიფიც აქვს ლირებში, თან წერია რომელი
ოპერატორის გამოქვეყნებული ფასია და როდის შემოწმდა.

მარშრუტი საზღვრის გაღმაც. თბილისი სტამბოლი ახლა ბოლომდე იგეგმება. მარშრუტიდან 8
კილომეტრში 2,428 დამტენია, აქედან 1,518 სწრაფი DC. თურქეთის მონაცემები თავად
ჩამოიტვირთება, როცა მარშრუტი თურქეთს კვეთს.

ძებნა გაიხსნა. საძიებო ველი აღარ შემოიფარგლება საქართველოთი, ანუ სტამბოლის
აეროპორტსაც იპოვით და მარშრუტშიც ჩასვამთ.

სწრაფი დამტენები რეკომენდაციაში. გრძელ მარშრუტზე პროგრამა ჯერ DC დამტენს გთავაზობთ
და AC-ს მხოლოდ მაშინ, თუ DC მისაწვდომი არ არის. აქამდე შეიძლებოდა 11 კილოვატიანი
სოკეტი შემოგთავაზებოდათ, სადაც დატენვას 8 საათზე მეტი დასჭირდებოდა.

ბევრად სწრაფი დაგეგმვა. გრძელ მარშრუტზე გამოთვლა აღარ აჭედებს აპლიკაციას.

პატიოსანი სტატუსი. თურქეთის რეესტრი ცოცხალ დატვირთვას არ აქვეყნებს, ამიტომ ასეთი
დამტენები აღარ იღებება მწვანედ თითქოს თავისუფალი იყოს. მათზე წერია რამდენი სოკეტია
და რომ ცოცხალი სტატუსი უცნობია. ქართული დამტენების ცოცხალი სტატუსი უცვლელია.

პროვაიდერების ფილტრი ინახება. ფილტრი აქამდე მხოლოდ მიმდინარე სესიაში მუშაობდა და
ყოველ გახსნაზე თავიდან იწყებოდა. ახლა ბოლოს მონიშნული არჩევანი ინახება და ისევ ისე
დაგხვდებათ, როგორც დატოვეთ.

როგორ ჩავრთოთ თურქეთი

ორი ნაბიჯია. ჯერ პარამეტრები, ქვეყნების სია, თურქეთი. შემდეგ რუკაზე პროვაიდერების
ფილტრი და იქ თურქეთის მონიშვნა. მონაცემები მხოლოდ ამის შემდეგ ჩამოიტვირთება, ანუ
თუ თურქეთი არ გჭირდებათ, არაფერი იტვირთება.
```

## English — App Store

```
Turkey is here

Georgians drive to Turkey often, so we rebuilt our Turkish coverage from scratch.

What changed

13,296 chargers across Turkey, up from 2,110. The data comes from EPDK, Turkey's
energy regulator, whose registry every publicly usable charger in the country is
legally required to appear in. Private sites you cannot use are filtered out.

Network names and prices. Every charger shows its network: ZES, Trugo, Eşarj,
Voltrun and the rest. 68 percent also carry the operator's published tariff in
lira, along with whose tariff it is and the date it was checked.

Routes across the border. Tbilisi to Istanbul now plans end to end. There are
2,428 chargers within 8 km of that route, 1,518 of them fast DC. Turkish data
loads by itself when a route crosses Turkey.

Search opened up. The search box is no longer limited to Georgia, so you can
find Istanbul Airport and set it as a destination.

Fast chargers first. On a long route the planner now recommends DC chargers, and
only falls back to AC when no DC is within reach. It could previously suggest an
11 kW socket, where a charge would take more than 8 hours.

Much faster planning. Long routes no longer freeze the app while they compute.

Honest status. The Turkish registry does not publish live occupancy, so those
chargers are no longer drawn green as if they were free. They show how many plugs
exist and say that live status is not published. Live status for Georgian
chargers is unchanged.

The provider filter is remembered. It used to live only for as long as the app
was open, so every launch started from scratch. Your last selection is now saved
and restored exactly as you left it.

How to turn Turkey on

Two steps. First Settings, countries, Turkey. Then the provider filter on the
map, and tick Turkey there. Nothing is downloaded until you do both, so if you
never go to Turkey, nothing is downloaded at all.
```

---

## Notes for whoever publishes this

Nothing changed on tesla.geocharge.ge in this release.
