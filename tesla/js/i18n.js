// Georgian / English strings. Georgian is the default (matches geocharge.ge).

const STRINGS = {
  ka: {
    appTitle: 'GeoCharge',
    forTesla: 'Tesla',
    filters: 'ფილტრები',
    provider: 'პროვაიდერი',
    connector: 'კონექტორი',
    fastDcOnly: 'Fast DC',
    availableOnly: 'თავისუფალი',
    status: 'სტატუსი',
    minPower: 'მინ. სიმძლავრე',
    anyPower: 'ნებისმიერი',
    allProviders: 'ყველა პროვაიდერი',
    allConnectors: 'ყველა კონექტორი',
    clearFilters: 'გასუფთავება',
    close: 'დახურვა',
    ports: 'პორტები',
    power: 'სიმძლავრე',
    price: 'ფასი',
    city: 'ქალაქი',
    updated: 'განახლდა',
    refresh: 'განახლება',
    // Three distinct answers, so the button can never claim it did something it
    // did not. "განახლდა" is already the timestamp label above it, hence
    // "შეიცვალა" for the outcome.
    refreshChanged: 'შეიცვალა',
    refreshNoChange: 'ცვლილება არაა',
    refreshFailed: 'ვერ განახლდა',
    refreshChecking: 'მოწმდება…',
    sourceFeed: 'პროვაიდერის ბოლო შემოწმება',
    sourceLive: 'ცოცხალი მონაცემი პროვაიდერის სისტემიდან',
    statusFree: 'თავისუფალია',
    statusBusy: 'დაკავებულია',
    statusOut: 'არ მუშაობს',
    statusUnknown: 'სტატუსი უცნობია',
    // Explains a plug the operator publishes no state for. Same wording as the
    // phone app, and every sentence in it was checked against Tegeta's own app.
    unknownInfoTitle: 'რატომ არ ჩანს სტატუსი?',
    unknownInfoPorsche:
      'ეს თეგეტას დამტენია და მათსავე აპლიკაციაში ცალკე PORSCHE ჩანართში ' +
      'ხვდება. დგას სასტუმროს, კურორტის ან სხვა კერძო ობიექტის ' +
      'ტერიტორიაზე.\n\n' +
      'თეგეტა მისგან რეალურ დროში მონაცემს არ იღებს და არ გასცემს, ამიტომ ' +
      'ვერ გეტყვით, ახლა დაკავებულია თუ თავისუფალი. დატენვა მხოლოდ ადგილზე ' +
      'ირთვება, აპლიკაციიდან ვერც ჩართავთ და ვერც გადაიხდით, ამიტომ ზუსტ ' +
      'ფასს არ ვწერთ.\n' +
      'იგივე ინფორმაციას იძლევა თეგეტას საკუთარი აპლიკაციაც.\n\n' +
      'ასეთი დამტენი ხშირად ობიექტის სტუმრებისთვისაა განკუთვნილი.\n' +
      'სანამ გზას გაუყვებით, ჯობია წინასწარ დარეკოთ ან ადგილზე იკითხოთ.\n' +
      'მადლობა რომ სარგებლობთ GeoCharge აპლიკაციით ❤',
    unknownInfoGeneric:
      'ამ დამტენზე ოპერატორი ცოცხალ მონაცემს არ გვიზიარებს. ვიცით, რომ ' +
      'დამტენი იქ დგას, მაგრამ ვერ გეტყვით, ახლა დაკავებულია თუ ' +
      'თავისუფალი, და ფასსაც იმიტომ არ ვწერთ, რომ დადასტურებული არ არის.\n\n' +
      'სანამ გზას გაუყვებით, ჯობია წინასწარ გადაამოწმოთ.',
    unknownInfoAria: 'რას ნიშნავს ეს სტატუსი',
    countries: 'ქვეყნები',
    reloadHint: 'განახლება',
    countryGeorgia: 'საქართველო',
    countryArmenia: 'სომხეთი',
    countryTurkey: 'თურქეთი',
    plugsCount: 'სოკეტი',
    navigate: 'ნავიგაცია',
    searchPlaceholder: 'ძებნა — დამტენი ან მისამართი',
    searchStations: 'დამტენები',
    searchPlaces: 'ადგილები',
    planRouteHere: 'მარშრუტი აქამდე',
    locationError: 'ლოკაცია ვერ მოიძებნა — შეამოწმე ბრაუზერის ნებართვა',
    stationsShown: 'სადგური',
    loading: 'იტვირთება…',
    fetchError: 'მონაცემების განახლება ვერ მოხერხდა — ნაჩვენებია ბოლო ცნობილი სტატუსები',
    mapError: 'რუკის ჩატვირთვა ვერ მოხერხდა',
    signInTitle: 'შესვლა',
    signInSubtitle: 'გამოიყენე იგივე ანგარიში, რომლითაც GeoCharge-ის აპში შედიხარ',
    email: 'ელფოსტა',
    password: 'პაროლი',
    signInBtn: 'შესვლა',
    orDivider: 'ან',
    googleBtn: 'Google-ით შესვლა',
    noAccount: 'ანგარიში არ გაქვს? დარეგისტრირდი GeoCharge-ის აპში ტელეფონზე.',
    signInPrice: 'სერვისი ფასიანია — Premium გამოწერა თვეში 1 ₾ (GeoCharge-ის მობილურ აპლიკაციაში). ახალ მომხმარებელს 24 საათი უფასოდ.',
    loginFailed: 'შესვლა ვერ მოხერხდა — შეამოწმე ელფოსტა და პაროლი',
    loginNetwork: 'ქსელის შეცდომა — სცადე თავიდან',
    trialBadge: 'საცდელი:',
    premiumBadge: 'Premium',
    logout: 'გასვლა',
    paywallTitle: 'საცდელი პერიოდი ამოიწურა',
    paywallBody: 'სერვისის გამოსაყენებლად საჭიროა Premium გამოწერა — შეიძინე GeoCharge-ის მობილურ აპლიკაციაში, თვეში 1 ₾. გააქტიურე ტელეფონიდან და ეს ეკრანი მაშინვე, თავისით გაიხსნება.',
    paywallStep1: 'გახსენი GeoCharge-ის აპი ტელეფონზე',
    paywallStep2: 'შედი ამავე ანგარიშით',
    paywallStep3: 'გააქტიურე Premium გამოწერა',
    paywallQr: 'აპის გადმოსაწერად დაასკანერე',
    trip: 'მარშრუტი',
    tripFrom: 'საიდან',
    tripTo: 'სად',
    tripStopN: 'გაჩერება',
    addStop: 'გაჩერების დამატება',
    tripMyLocation: 'ჩემი ლოკაცია',
    tripPickOnMap: 'რუკაზე არჩევა',
    tripBatteryNow: 'ბატარეა ახლა',
    tripRange: 'სრული მარაგი (კმ)',
    tripStops: 'გაჩერება',
    tripArrival: 'ჩასვლისას',
    tripChargers: 'დამტენი',
    tripStationsUnit: 'სადგური',
    tripPortsUnit: 'პორტი',
    tripFreeUnit: 'თავისუფალი',
    tripKmUnit: 'კმ',
    tripSegmentsHint: 'გახსენი მონაკვეთი დამტენების სანახავად — ✓ ნიშნავს რომ იქ რეკომენდებული გაჩერებაა',
    chargersOnRoute: 'დამტენები მარშრუტზე',
    recommended: 'რეკომენდ.',
    uTurnInfo: 'დამტენი გზის მოპირდაპირე მხარესაა — მოგიწევს მობრუნება',
    startNav: 'ნავიგაციის დაწყება',
    tripSetStops: 'მიუთითე საწყისი და დანიშნულება',
    tripNoChargers: 'ამ მარშრუტზე დამტენი ვერ მოიძებნა',
    tripNoRoute: 'მარშრუტი ვერ აიგო',
    tripClearRoute: 'მარშრუტის გასუფთავება',
    tripUnreachable: 'ყურადღება: მარშრუტის ნაწილზე მისაწვდომი დამტენი ვერ მოიძებნა — ბოლო მონაკვეთი დაუგეგმავია',
    onboardTitle: 'რჩევა Tesla-ს ეკრანისთვის',
    onboardFullscreen: 'ბრაუზერში ჩართე სრულეკრანიანი რეჟიმი (⛶ ღილაკი მისამართის ველთან)',
    onboardBookmark: 'შეინახე ეს გვერდი bookmark-ად, რომ ერთი შეხებით გახსნა',
    onboardOk: 'გასაგებია',
    driveEnd: 'დასრულება',
    driveRerouting: 'მარშრუტის გადათვლა…',
    driveRerouted: 'მარშრუტი გადათვლილია',
    driveArrived: 'დანიშნულების ადგილას ხართ',
    driveArrive: 'ჩასვლა დანიშნულებამდე',
    driveLocating: 'ლოკაციის დადგენა…',
    driveNoLocation: 'ნავიგაციისთვის ლოკაცია საჭიროა — შეამოწმე ბრაუზერის ნებართვა',
  },
  en: {
    appTitle: 'GeoCharge',
    forTesla: 'Tesla',
    filters: 'Filters',
    provider: 'Provider',
    connector: 'Connector',
    fastDcOnly: 'Fast DC',
    availableOnly: 'Available',
    status: 'Status',
    minPower: 'Min. power',
    anyPower: 'Any',
    allProviders: 'All providers',
    allConnectors: 'All connectors',
    clearFilters: 'Clear',
    close: 'Close',
    ports: 'Ports',
    power: 'Power',
    price: 'Price',
    city: 'City',
    updated: 'Updated',
    refresh: 'Refresh',
    refreshChanged: 'Changed',
    refreshNoChange: 'No change',
    refreshFailed: 'Update failed',
    refreshChecking: 'Checking…',
    sourceFeed: "Provider's last server check",
    sourceLive: 'Read live from the operator',
    statusFree: 'Available',
    statusBusy: 'Busy',
    statusOut: 'Out of service',
    statusUnknown: 'Live status not published',
    unknownInfoTitle: 'Why is there no status?',
    unknownInfoPorsche:
      'This is a Tegeta charger, and in their own app it sits under a ' +
      'separate PORSCHE tab. It stands on a hotel, resort or other private ' +
      'property.\n\n' +
      'Tegeta neither receives nor publishes real-time data for it, so we ' +
      'cannot tell you whether it is free or in use right now. Charging is ' +
      'started on site, you cannot start it or pay for it from an app, so we ' +
      'do not quote an exact price.\n' +
      "Tegeta's own app says the same.\n\n" +
      "Chargers like this are often meant for the venue's guests.\n" +
      'Call ahead or ask on site before you set off.\n' +
      'Thank you for using GeoCharge ❤',
    unknownInfoGeneric:
      'The operator does not share live data for this plug. We know the ' +
      'charger is there, but we cannot tell you whether it is free or in use ' +
      'right now, and we will not quote a price we cannot confirm.\n\n' +
      'Worth checking before you make the trip.',
    unknownInfoAria: 'What this status means',
    countries: 'Countries',
    reloadHint: 'Reload',
    countryGeorgia: 'Georgia',
    countryArmenia: 'Armenia',
    countryTurkey: 'Turkey',
    plugsCount: 'plugs',
    navigate: 'Navigate',
    searchPlaceholder: 'Search — charger or address',
    searchStations: 'Chargers',
    searchPlaces: 'Places',
    planRouteHere: 'Route here',
    locationError: 'Could not get your location — check the browser permission',
    stationsShown: 'stations',
    loading: 'Loading…',
    fetchError: 'Could not refresh data — showing last known statuses',
    mapError: 'Failed to load the map',
    signInTitle: 'Sign in',
    signInSubtitle: 'Use the same account you use in the GeoCharge app',
    email: 'Email',
    password: 'Password',
    signInBtn: 'Sign in',
    orDivider: 'or',
    googleBtn: 'Sign in with Google',
    noAccount: "Don't have an account? Register in the GeoCharge app on your phone.",
    signInPrice: 'This is a paid service — Premium is 1 ₾/month (in the GeoCharge mobile app). New users get 24 hours free.',
    loginFailed: 'Sign-in failed — check your email and password',
    loginNetwork: 'Network error — please try again',
    trialBadge: 'Trial:',
    premiumBadge: 'Premium',
    logout: 'Sign out',
    paywallTitle: 'Your trial has ended',
    paywallBody: 'To use the service you need a Premium subscription — get it in the GeoCharge mobile app for 1 ₾/month. Activate it on your phone and this screen unlocks instantly, by itself.',
    paywallStep1: 'Open the GeoCharge app on your phone',
    paywallStep2: 'Sign in with this same account',
    paywallStep3: 'Activate the Premium subscription',
    paywallQr: 'Scan to get the app',
    trip: 'Trip',
    tripFrom: 'From',
    tripTo: 'To',
    tripStopN: 'Stop',
    addStop: 'Add stop',
    tripMyLocation: 'My location',
    tripPickOnMap: 'Pick on map',
    tripBatteryNow: 'Battery now',
    tripRange: 'Full range (km)',
    tripStops: 'stops',
    tripArrival: 'At arrival',
    tripChargers: 'chargers',
    tripStationsUnit: 'stations',
    tripPortsUnit: 'ports',
    tripFreeUnit: 'free',
    tripKmUnit: 'km',
    tripSegmentsHint: 'Open a segment to see its chargers — ✓ means a recommended stop is inside',
    chargersOnRoute: 'Chargers on route',
    recommended: 'Recommended',
    uTurnInfo: 'The charger is on the opposite side of the road — you will need to turn around',
    startNav: 'Start navigation',
    tripSetStops: 'Set start & destination',
    tripNoChargers: 'No chargers found along this route',
    tripNoRoute: 'Could not build a route',
    tripClearRoute: 'Clear route',
    tripUnreachable: 'Warning: no reachable charger on part of the route — the last segment is unplanned',
    onboardTitle: 'Tips for the Tesla screen',
    onboardFullscreen: 'Switch the browser to fullscreen (⛶ button next to the address bar)',
    onboardBookmark: 'Bookmark this page so it opens with one tap',
    onboardOk: 'Got it',
    driveEnd: 'End',
    driveRerouting: 'Rerouting…',
    driveRerouted: 'Route updated',
    driveArrived: 'You have arrived',
    driveArrive: 'Arrive at destination',
    driveLocating: 'Getting your location…',
    driveNoLocation: 'Navigation needs your location — check the browser permission',
  },
};

let lang = localStorage.getItem('gc_lang') || 'ka';

export function t(key) {
  return STRINGS[lang][key] ?? STRINGS.en[key] ?? key;
}

export function getLang() {
  return lang;
}

export function setLang(next) {
  lang = next;
  localStorage.setItem('gc_lang', next);
  applyStaticStrings();
}

/** Re-translate every element carrying a data-t="key" attribute. */
export function applyStaticStrings() {
  document.documentElement.lang = lang;
  for (const el of document.querySelectorAll('[data-t]')) {
    el.textContent = t(el.dataset.t);
  }
  for (const el of document.querySelectorAll('[data-t-placeholder]')) {
    el.placeholder = t(el.dataset.tPlaceholder);
  }
  for (const el of document.querySelectorAll('[data-t-title]')) {
    el.title = t(el.dataset.tTitle);
  }
  for (const el of document.querySelectorAll('[data-lang-btn]')) {
    el.classList.toggle('is-active', el.dataset.langBtn === lang);
  }
}
