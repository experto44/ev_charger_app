/* Visitor statistics for geocharge.ge.
 *
 * One small POST per page view, and one per click on a Google Play or App Store
 * link, to the sitePulse Cloud Function (functions/site-pulse.js), which folds
 * them into daily totals for the admin panel's Site tab.
 *
 * Nothing here identifies a person or a device: no cookie, no id, no
 * fingerprint. The browser keeps one value, the date of its last visit, which is
 * how a returning visitor is told apart from a new one. The country is worked
 * out on the server from the device's time zone, so no IP address is looked up
 * or stored either.
 *
 * To keep your own visits out of the numbers, open any page once with
 * ?notrack=1 (?notrack=0 undoes it). The setting lives in that one browser.
 *
 * Every API newer than ES5 sits behind a try: this runs on every page, in old
 * in-app browsers too, and must never be the thing that throws.
 */
(function () {
  'use strict';

  var ENDPOINT = 'https://us-central1-geocharge-f6714.cloudfunctions.net/sitePulse';

  // /get/ calls gcPulse.click() before it redirects, whether or not this
  // browser is counted, so the handle exists either way.
  var api = (window.gcPulse = { click: function () {} });

  // Local and deploy previews are not visitors, and neither is a driven browser.
  if (!/(^|\.)geocharge\.ge$/.test(location.hostname) || navigator.webdriver) return;

  var storage = null;
  try {
    storage = window.localStorage;
    if (/[?&]notrack=1(&|$)/.test(location.search)) storage.setItem('gc_notrack', '1');
    else if (/[?&]notrack=0(&|$)/.test(location.search)) storage.removeItem('gc_notrack');
    if (storage.getItem('gc_notrack') === '1') return;
  } catch (e) {
    storage = null; // storage blocked: still count, just without the day marker
  }

  function send(hit) {
    var body = JSON.stringify(hit);
    // sendBeacon survives the page being navigated away, which is exactly what
    // a click on a store link does. text/plain keeps it a simple request, so
    // there is no preflight to wait for.
    try {
      if (navigator.sendBeacon && navigator.sendBeacon(ENDPOINT, new Blob([body], { type: 'text/plain' }))) return;
    } catch (e) {}
    try {
      fetch(ENDPOINT, { method: 'POST', body: body, mode: 'no-cors', keepalive: true });
    } catch (e) {}
  }

  // The date in Tbilisi (UTC+4 all year): the day the server files the hit under.
  var today = new Date(Date.now() + 144e5).toISOString().slice(0, 10);

  var lastSeen; // undefined: unknown, because there is no storage
  if (storage) {
    try {
      lastSeen = storage.getItem('gc_seen'); // null: this browser has never been here
      storage.setItem('gc_seen', today);
    } catch (e) {
      lastSeen = undefined;
    }
  }

  var refHost = '';
  try {
    refHost = document.referrer ? new URL(document.referrer).hostname : '';
  } catch (e) {}
  var internal = /(^|\.)geocharge\.ge$/.test(refHost);

  var navType = '';
  try {
    navType = (performance.getEntriesByType('navigation')[0] || {}).type || '';
  } catch (e) {}

  // A visit starts when someone arrives from outside, not on every page they
  // read after that, and not on a reload or a step back. The first page of the
  // day always starts one, so visitors can never outnumber visits.
  var firstToday = lastSeen === undefined ? !internal : lastSeen !== today;
  var entry = firstToday || (!internal && navType !== 'reload' && navType !== 'back_forward');

  var hit = { t: 'view', p: location.pathname };
  if (firstToday) hit.u = 1;
  if (lastSeen === null) hit.n = 1;
  if (entry) {
    hit.e = 1;
    if (refHost && !internal) hit.r = refHost;
    try {
      var params = new URLSearchParams(location.search);
      // Facebook and Google Ads tag their clicks even when a link carries no utm.
      var source = params.get('utm_source') ||
        (params.has('fbclid') ? 'facebook' : params.has('gclid') ? 'google-ads' : '');
      if (source) hit.s = source.slice(0, 40);
      if (params.get('utm_campaign')) hit.c = params.get('utm_campaign').slice(0, 60);
    } catch (e) {}
    try {
      hit.tz = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
    } catch (e) {}
  }
  send(hit);

  api.click = function (store) {
    send({ t: 'click', p: location.pathname, k: store });
  };

  function onClick(ev) {
    if (ev.type === 'auxclick' && ev.button !== 1) return; // middle click, not the context menu
    var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
    if (!a) return;
    var href = a.href || '';
    if (href.indexOf('play.google.com') > -1) api.click('play');
    else if (href.indexOf('apps.apple.com') > -1) api.click('appstore');
  }
  // Capture phase and delegated, so it also sees the homepage's sticky button,
  // whose href is only rewritten to a store link after the page has loaded.
  document.addEventListener('click', onClick, true);
  document.addEventListener('auxclick', onClick, true);
})();
