# GeoCharge — Marketing Website Build Brief (for Claude Design)

## 0. What I'm asking you to build
Build a **bilingual (Georgian + English), single-page marketing / showcase website** for **GeoCharge**, a free mobile app that aggregates Georgia's EV (electric vehicle) charging stations into one map. This is an **image / promotional site only** — not the app itself. It must be modern, clean, fast, fully responsive (mobile-first), and meticulously optimized for both **SEO** (search engines) and **AEO** (answer engines / AI assistants like Google AI Overviews, ChatGPT, Perplexity, Claude).

Default language is **Georgian (ka)**, with a toggle to **English (en)**.

---

## 1. Assets I will provide (uploaded with this brief)
1. **Brandbook ZIP** — logo files, color palette, typography. **Follow it strictly.** All colors, fonts, logo usage, and spacing must come from the brandbook. Do not invent a new identity.
2. **App screenshots (PNG)** — real screenshots from the app. Place them in device (phone) mockup frames in the hero and the screenshots gallery. I will indicate which screenshot goes where, or use them in the order provided.

If any asset is missing when you start, use tasteful neutral placeholders in the exact dimensions and tell me what to drop in.

---

## 2. Core requirements (non-negotiable)
- **Bilingual ka/en** with an obvious language toggle in the header. Georgian is the default. Implement real i18n (all UI strings, meta tags, and structured data localized — not just body text).
- **Performance:** static, fast-loading, excellent Core Web Vitals. Lazy-load images, compress/serve modern formats (WebP/AVIF), minimal JavaScript, no heavy frameworks unless justified.
- **Responsive, mobile-first.** Most EV drivers will open this on a phone.
- **Accessibility:** semantic HTML5, proper heading hierarchy, descriptive bilingual `alt` text on every image, sufficient contrast, keyboard-navigable.
- **No personal contact info anywhere.** No phone, no personal email, no address. The **only** way to reach us is the contact form (see §7).

---

## 3. Brand & visual direction
- Pull **all** visual identity from the uploaded brandbook (logo, primary/secondary colors, typography scale).
- Aesthetic: modern, clean, generous whitespace, a tech-meets-clean-energy feel. Subtle, performant scroll animations (gentle fade/slide-in) — nothing heavy or distracting.
- Use **phone device mockups** to frame app screenshots.
- A map / charging / energy visual motif in the hero is welcome, as long as it respects the brandbook palette.
- Smooth anchored scrolling between sections from the nav.

---

## 4. Information architecture (single page, in this order)

### 4.1 Header / Nav (sticky)
- Logo (left).
- Anchor nav links: About · Features · Coverage · How it works · FAQ · Download.
- **Language toggle** (ka / en).
- Primary CTA button: **"Download"** (scrolls to download section).

### 4.2 Hero
- Strong headline + subheadline communicating the core value: *every EV charging station in Georgia, in one app.*
- Phone mockup with a key app screenshot (map view).
- **Store badges:** Google Play (active) + App Store ("coming soon", visibly muted — see §8).
- Small trust line, e.g. "663+ charging stations across Georgia."

Suggested EN hero copy (adapt, keep natural Georgian as the default-language version):
> **Headline:** Every EV charger in Georgia. One app.
> **Subheadline:** GeoCharge brings together 663+ public charging stations from across Georgia's charging networks into a single, free map — so you always know where to charge.

### 4.3 About / Mission
Explain what GeoCharge is and the problem it solves.

Reference content (rewrite naturally in both languages):
- Georgia's EV charging infrastructure is **fragmented** across many independent operators — drivers previously had to juggle several different apps (or had no app at all) to find a compatible charger.
- **GeoCharge unifies them.** It aggregates public charging stations from across the country's networks into one interactive map, with consistent details and filtering.
- Mission: make EV driving in Georgia effortless by giving every driver one trusted place to find, filter, and navigate to any public charger.

### 4.4 Key features (icon + short text cards)
- **Nationwide map of 663+ stations** — every major public charging point in Georgia in one view.
- **All networks in one app** — aggregates multiple independent Georgian charging networks so you don't need a separate app for each.
- **Smart filtering** — filter by operator/network, connector type, and power (kW).
- **Route planning with charging stops** — plan trips and find chargers along the way (powered by Google Directions).
- **Detailed station info** — connectors, power, location, and operator at a glance.
- **Quick sign-in** — Google or email sign-in with a saved profile.
- **Covers the whole country** — cities and highways alike.
- **Completely free** — see §4.7.

### 4.5 Coverage / Networks
Communicate breadth: *"All of Georgia's major public charging networks, together in one place."*
- Lead with the headline number (663+ stations) and nationwide coverage.
- **Optional:** a row of operator names/logos can be added here **only if I include those logos in the assets**. By default, keep this section **generic** (no third-party logos or trademarks) to avoid any trademark/partnership sensitivity. I'll tell you if I want named operators added.

### 4.6 How it works (3 steps)
1. **Download** GeoCharge (free).
2. **Open the map** and find chargers near you or along your route.
3. **Filter & navigate** to the right station and charge.

### 4.7 "Free for everyone" note
**Do NOT build a pricing / free-vs-premium section.** Just include **one small, tasteful mention** somewhere natural (e.g. a line in About, a feature card, or a slim banner) that **GeoCharge is completely free for everyone to use.** Nothing more.

### 4.8 Screenshots gallery
- A clean gallery of app screenshots in phone mockups (I'll provide the images).
- Each with a short bilingual caption describing the screen (map, filters, station detail, route planning, etc.).
- Lazy-loaded; swipeable/carousel on mobile.

### 4.9 Why GeoCharge / advantages
Short, scannable benefit statements:
- One app instead of many.
- The most complete station coverage in Georgia.
- Plan longer trips with confidence.
- Free, fast, and simple.

### 4.10 FAQ (also powers AEO — see §6)
Include these as expandable Q&A (and mirror them in FAQ structured data). Provide both languages:
1. **What is GeoCharge?** — A free app that shows EV charging stations across Georgia on one map, aggregating multiple charging networks.
2. **Is GeoCharge free?** — Yes, GeoCharge is completely free to use.
3. **How many charging stations does GeoCharge show?** — 663+ public charging stations across Georgia.
4. **Does GeoCharge work across all of Georgia?** — Yes — in cities and along highways nationwide.
5. **Can I plan a route with charging stops?** — Yes, GeoCharge includes route planning so you can find chargers along your way.
6. **What devices is GeoCharge available on?** — Android now (on Google Play); iOS is coming soon.
7. **Do I need an account?** — You can sign in quickly with Google or email to save your profile.
8. **How is GeoCharge different from using each network's own app?** — Instead of juggling multiple apps, GeoCharge brings stations from across Georgia's networks into a single map with consistent details and filtering.

### 4.11 Download section
- Headline CTA.
- **Google Play badge** → active link: `https://play.google.com/store/apps/details?id=ge.geocharge.app`
- **App Store badge** → "Coming soon", visibly muted (see §8), not clickable.

### 4.12 Contact (form only — see §7)
- Heading like "Get in touch" / "Contact us".
- The contact **form only**. **No** displayed email, phone, or address.

### 4.13 Footer
- Logo, short tagline.
- Anchor links repeated.
- Language toggle.
- **Privacy Policy** link → `[PRIVACY_POLICY_URL]` (I'll paste my existing GitHub Pages privacy policy URL).
- Copyright line (e.g. "© 2026 GeoCharge").
- **No personal contact details.**

---

## 5. SEO requirements
- Unique, localized **`<title>`** and **meta description** per language.
- **`hreflang`** annotations for `ka` and `en` (+ `x-default`), and correct `<html lang>` per rendered language.
- **Canonical** URL tags.
- **Open Graph** + **Twitter Card** meta (title, description, image) — localized.
- Semantic HTML5 landmarks: `header`, `nav`, `main`, `section`, `article`, `footer`.
- Descriptive, keyword-aware, bilingual `alt` text on every screenshot/image.
- Generate a **`sitemap.xml`** and **`robots.txt`** (or clearly note where they go).
- Logical heading hierarchy (one `h1`, then `h2`/`h3`).
- Target keywords to weave in naturally:
  - **Georgian:** ელექტრომობილის დამტენი საქართველო · EV დატენვა საქართველო · დამტენი სადგურები რუკა · ელექტრომანქანის დატენვა · დამტენების რუკა
  - **English:** EV charging Georgia · electric car charging stations Georgia · EV charger map Georgia · charging stations Tbilisi · GeoCharge app

---

## 6. AEO / structured data requirements
Add **JSON-LD** structured data so AI assistants and search engines can confidently cite the site:
- **`MobileApplication`** (or `SoftwareApplication`): name *GeoCharge*, `applicationCategory: TravelApplication` (or Navigation/Utilities), `operatingSystem: Android` (note iOS coming soon), `offers` with `price: 0` / `priceCurrency: GEL` (free), `installUrl` = the Play Store link, and a short description mentioning 663+ stations across Georgia.
- **`Organization`** for GeoCharge (name, logo, URL).
- **`FAQPage`** built from the §4.10 FAQ, localized per language.
- Keep on-page copy **factual, self-contained, and answer-style** (short declarative sentences with the key facts: what it is, free, 663+ stations, nationwide, Android now / iOS soon) so it's easily extractable by LLMs.

---

## 7. Contact form spec (Web3Forms)
Use **Web3Forms** — no backend or account required.
- Submit via JavaScript `fetch` (AJAX) **POST** to `https://api.web3forms.com/submit`, so the page doesn't reload; show an inline success / error state and reset the form on success.
- Hidden field **`access_key`** = `[WEB3FORMS_ACCESS_KEY]` (I'll paste my key here — I get it instantly by entering `miruashvili.k@gmail.com` once at web3forms.com; submissions are delivered to that email).
- Fields: **Name**, **Email**, **Message** (all required, client-side validated). Optional **Subject**.
- Include a **honeypot** anti-spam field (e.g. hidden `botcheck` checkbox) per Web3Forms convention.
- Bilingual labels, placeholders, validation messages, and success/error text.
- Accessible (labels tied to inputs, visible focus states).
- **Do not display the destination email anywhere** — it only lives in the hidden key/config.

---

## 8. Store badges spec
- **Google Play:** use the official "Get it on Google Play" badge, full color, linked to `https://play.google.com/store/apps/details?id=ge.geocharge.app` (opens in new tab).
- **App Store:** use the official "Download on the App Store" badge but **desaturated / reduced opacity** with a small **"Coming soon"** label, **non-clickable** (clear visual signal that it's in progress but planned). Keep it present from launch so visitors know iOS is coming.

---

## 9. Technical / build notes
- Clean, production-ready static output (HTML/CSS/JS). Keep JS minimal.
- All third-party assets optimized and lazy-loaded.
- Language switching should not reload-flash; persist the user's choice (e.g. in localStorage) **only if the build environment supports it** — otherwise default to Georgian and keep it simple.
- Provide the final files in a structure ready to deploy to a static host (the site will live on a subdomain I control).
- Use `[SITE_URL]` as a placeholder for canonical/hreflang/OG URLs — I'll set the real domain at deploy.

---

## 10. Out of scope / do NOT include
- ❌ No pricing or free-vs-premium section (only the small "completely free" mention).
- ❌ No personal contact information (phone, email, address) anywhere — contact form only.
- ❌ No third-party operator logos/trademarks unless I explicitly provide them.
- ❌ No login, no app functionality — this is a marketing site only.

---

## 11. Acceptance checklist
- [ ] Bilingual ka/en with working toggle; Georgian default.
- [ ] All visual identity matches the uploaded brandbook.
- [ ] All sections from §4 present, in order, with my screenshots placed in phone mockups.
- [ ] Small "completely free" mention included; **no** premium section.
- [ ] SEO: localized title/meta, hreflang, canonical, OG/Twitter, sitemap, robots, semantic HTML, bilingual alt text.
- [ ] AEO: MobileApplication + Organization + FAQPage JSON-LD, localized; answer-style copy.
- [ ] Contact form posts to Web3Forms; success/error states; no contact info shown.
- [ ] Google Play badge active; App Store badge muted "coming soon", non-clickable.
- [ ] Fast, mobile-first, accessible, strong Core Web Vitals.
- [ ] No personal contact details anywhere on the page.
