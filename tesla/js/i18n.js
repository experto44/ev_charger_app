// Georgian / English strings. Georgian is the default (matches geocharge.ge).

const STRINGS = {
  ka: {
    appTitle: 'GeoCharge',
    forTesla: 'Tesla-სთვის',
    filters: 'ფილტრები',
    provider: 'პროვაიდერი',
    connector: 'კონექტორი',
    fastDcOnly: 'მხოლოდ Fast DC',
    allProviders: 'ყველა პროვაიდერი',
    allConnectors: 'ყველა კონექტორი',
    clearFilters: 'გასუფთავება',
    close: 'დახურვა',
    ports: 'პორტები',
    power: 'სიმძლავრე',
    price: 'ფასი',
    city: 'ქალაქი',
    updated: 'განახლდა',
    statusFree: 'თავისუფალია',
    statusBusy: 'დაკავებულია',
    statusOut: 'არ მუშაობს',
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
    loginFailed: 'შესვლა ვერ მოხერხდა — შეამოწმე ელფოსტა და პაროლი',
    loginNetwork: 'ქსელის შეცდომა — სცადე თავიდან',
    trialBadge: 'საცდელი:',
    premiumBadge: 'Premium',
    logout: 'გასვლა',
    paywallTitle: 'საცდელი პერიოდი ამოიწურა',
    paywallBody: 'Tesla-ეკრანზე წვდომას Premium გამოწერა ხსნის. გააქტიურე ტელეფონიდან — ეს ეკრანი მაშინვე, თავისით გაიხსნება.',
    paywallStep1: 'გახსენი GeoCharge-ის აპი ტელეფონზე',
    paywallStep2: 'შედი ამავე ანგარიშით',
    paywallStep3: 'გააქტიურე Premium გამოწერა',
    paywallQr: 'აპის გადმოსაწერად დაასკანერე',
    trip: 'მარშრუტი',
    tripOrigin: 'საიდან',
    tripDest: 'სად',
    tripPickOnMap: 'რუკაზე არჩევა',
    tripBatteryNow: 'ბატარეა ახლა',
    tripRange: 'სრული მარაგი (კმ)',
    tripPlan: 'მარშრუტის აგება',
    tripPlanning: 'იგეგმება…',
    tripClear: 'გასუფთავება',
    tripStops: 'გაჩერება',
    tripArrival: 'ჩასვლისას',
    tripBattery: 'ბატარეა',
    tripMin: 'წთ',
    tripUTurn: ' · მოსახვევი (U-turn)!',
    tripNoRoute: 'მარშრუტი ვერ აიგო',
    tripUnreachable: 'ყურადღება: მარშრუტის ნაწილზე მისაწვდომი დამტენი ვერ მოიძებნა — ბოლო მონაკვეთი დაუგეგმავია',
    onboardTitle: 'რჩევა Tesla-ს ეკრანისთვის',
    onboardFullscreen: 'ბრაუზერში ჩართე სრულეკრანიანი რეჟიმი (⛶ ღილაკი მისამართის ველთან)',
    onboardBookmark: 'შეინახე ეს გვერდი bookmark-ად, რომ ერთი შეხებით გახსნა',
    onboardOk: 'გასაგებია',
  },
  en: {
    appTitle: 'GeoCharge',
    forTesla: 'for Tesla',
    filters: 'Filters',
    provider: 'Provider',
    connector: 'Connector',
    fastDcOnly: 'Fast DC only',
    allProviders: 'All providers',
    allConnectors: 'All connectors',
    clearFilters: 'Clear',
    close: 'Close',
    ports: 'Ports',
    power: 'Power',
    price: 'Price',
    city: 'City',
    updated: 'Updated',
    statusFree: 'Available',
    statusBusy: 'Busy',
    statusOut: 'Out of service',
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
    loginFailed: 'Sign-in failed — check your email and password',
    loginNetwork: 'Network error — please try again',
    trialBadge: 'Trial:',
    premiumBadge: 'Premium',
    logout: 'Sign out',
    paywallTitle: 'Your trial has ended',
    paywallBody: 'Premium unlocks the Tesla screen. Activate it on your phone — this screen unlocks instantly, by itself.',
    paywallStep1: 'Open the GeoCharge app on your phone',
    paywallStep2: 'Sign in with this same account',
    paywallStep3: 'Activate the Premium subscription',
    paywallQr: 'Scan to get the app',
    trip: 'Trip',
    tripOrigin: 'From',
    tripDest: 'To',
    tripPickOnMap: 'Pick on map',
    tripBatteryNow: 'Battery now',
    tripRange: 'Full range (km)',
    tripPlan: 'Plan route',
    tripPlanning: 'Planning…',
    tripClear: 'Clear',
    tripStops: 'stops',
    tripArrival: 'At arrival',
    tripBattery: 'battery',
    tripMin: 'min',
    tripUTurn: ' · U-turn required!',
    tripNoRoute: 'Could not build a route',
    tripUnreachable: 'Warning: no reachable charger on part of the route — the last segment is unplanned',
    onboardTitle: 'Tips for the Tesla screen',
    onboardFullscreen: 'Switch the browser to fullscreen (⛶ button next to the address bar)',
    onboardBookmark: 'Bookmark this page so it opens with one tap',
    onboardOk: 'Got it',
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
  for (const el of document.querySelectorAll('[data-lang-btn]')) {
    el.classList.toggle('is-active', el.dataset.langBtn === lang);
  }
}
