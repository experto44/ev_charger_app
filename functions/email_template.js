"use strict";

// Brand tokens — kept in sync with the app's palette (emerald on light).
const EMERALD = "#00C896";
const EMERALD_DARK = "#00A67E";
const INK = "#1A1A1A";
const MUTED = "#6B7280";
const BORDER = "#E6E9ED";
const PAGE_BG = "#F4F6F8";
const CARD_BG = "#FFFFFF";

// Hosted on the live marketing site — reliable, cached, renders in every client.
const LOGO_URL = "https://geocharge.ge/assets/icon-1024.png";
const SITE_URL = "https://geocharge.ge";

/**
 * Builds the branded verification email.
 * @param {string} verifyLink Firebase email-verification action link.
 * @returns {{subject: string, html: string, text: string}}
 */
function buildVerificationEmail(verifyLink) {
  const year = new Date().getFullYear();

  const subject = "დაადასტურე ელფოსტა — GeoCharge";

  // Plain-text alternative (improves deliverability + accessibility).
  const text = [
    "GeoCharge — ელფოსტის დადასტურება",
    "",
    "მოგესალმებით! GeoCharge-ში რეგისტრაციის დასასრულებლად დაადასტურეთ",
    "თქვენი ელფოსტის მისამართი ქვემოთ მოცემულ ბმულზე გადასვლით:",
    "",
    verifyLink,
    "",
    "თუ თქვენ არ დარეგისტრირებულხართ GeoCharge-ზე, უბრალოდ უგულებელყავით",
    "ეს წერილი — არაფერი მოხდება.",
    "",
    `© ${year} GeoCharge · ${SITE_URL}`,
  ].join("\n");

  // Preheader: shown as the inbox preview snippet, hidden in the body.
  const preheader =
    "დაადასტურე ელფოსტა ერთი შეხებით და დაასრულე GeoCharge-ზე რეგისტრაცია.";

  const html = `<!DOCTYPE html>
<html lang="ka" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="x-apple-disable-message-reformatting">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<title>${subject}</title>
</head>
<body style="margin:0; padding:0; background:${PAGE_BG}; -webkit-text-size-adjust:100%; -ms-text-size-adjust:100%;">
  <div style="display:none; max-height:0; overflow:hidden; opacity:0; font-size:1px; line-height:1px; color:${PAGE_BG};">
    ${preheader}
    &#847;&zwnj;&nbsp;&#8199;&#65279;&#847;&zwnj;&nbsp;&#8199;&#65279;&#847;&zwnj;&nbsp;&#8199;&#65279;
  </div>

  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${PAGE_BG};">
    <tr>
      <td align="center" style="padding:32px 16px;">

        <!-- Card -->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px; width:100%; background:${CARD_BG}; border:1px solid ${BORDER}; border-radius:18px; overflow:hidden;">

          <!-- Brand header -->
          <tr>
            <td align="center" style="padding:36px 32px 8px 32px;">
              <img src="${LOGO_URL}" width="64" height="64" alt="GeoCharge"
                   style="display:block; width:64px; height:64px; border-radius:16px; border:0; outline:none; text-decoration:none;">
              <div style="height:14px; line-height:14px;">&nbsp;</div>
              <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif; font-size:20px; font-weight:800; letter-spacing:-0.2px; color:${INK};">
                GeoCharge
              </div>
            </td>
          </tr>

          <!-- Body -->
          <tr>
            <td style="padding:20px 40px 8px 40px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
              <h1 style="margin:0 0 14px 0; font-size:22px; line-height:1.35; font-weight:800; color:${INK}; text-align:center;">
                დაადასტურე შენი ელფოსტა
              </h1>
              <p style="margin:0; font-size:15px; line-height:1.7; color:${MUTED}; text-align:center;">
                მოგესალმებით! GeoCharge-ზე რეგისტრაციის დასასრულებლად
                დააჭირე ქვემოთ ღილაკს და დაადასტურე შენი მისამართი.
              </p>
            </td>
          </tr>

          <!-- Button (bulletproof) -->
          <tr>
            <td align="center" style="padding:26px 40px 8px 40px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td align="center" bgcolor="${EMERALD}" style="border-radius:14px;">
                    <a href="${verifyLink}" target="_blank"
                       style="display:inline-block; padding:15px 40px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif; font-size:16px; font-weight:700; color:#0A0A0A; text-decoration:none; border-radius:14px; background:${EMERALD};">
                      ელფოსტის დადასტურება
                    </a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Fallback link -->
          <tr>
            <td style="padding:18px 40px 4px 40px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
              <p style="margin:0; font-size:12px; line-height:1.6; color:${MUTED}; text-align:center;">
                თუ ღილაკი არ მუშაობს, დააკოპირე და ჩასვი ეს ბმული ბრაუზერში:
              </p>
              <p style="margin:8px 0 0 0; font-size:12px; line-height:1.6; text-align:center; word-break:break-all;">
                <a href="${verifyLink}" target="_blank" style="color:${EMERALD_DARK}; text-decoration:underline;">${verifyLink}</a>
              </p>
            </td>
          </tr>

          <!-- Divider -->
          <tr>
            <td style="padding:22px 40px 0 40px;">
              <div style="height:1px; line-height:1px; background:${BORDER};">&nbsp;</div>
            </td>
          </tr>

          <!-- Reassurance -->
          <tr>
            <td style="padding:18px 40px 30px 40px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
              <p style="margin:0; font-size:12px; line-height:1.6; color:${MUTED}; text-align:center;">
                თუ შენ არ დარეგისტრირებულხარ GeoCharge-ზე, უბრალოდ უგულებელყავი
                ეს წერილი — არაფერი მოხდება.
              </p>
            </td>
          </tr>

        </table>

        <!-- Footer -->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px; width:100%;">
          <tr>
            <td align="center" style="padding:22px 24px 8px 24px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
              <p style="margin:0; font-size:12px; line-height:1.6; color:#9AA1AB;">
                GeoCharge — საქართველოს ელექტრომობილების დამტენების რუკა
              </p>
              <p style="margin:6px 0 0 0; font-size:12px; line-height:1.6; color:#9AA1AB;">
                <a href="${SITE_URL}" target="_blank" style="color:#9AA1AB; text-decoration:underline;">geocharge.ge</a>
                &nbsp;·&nbsp; © ${year} GeoCharge
              </p>
            </td>
          </tr>
        </table>

      </td>
    </tr>
  </table>
</body>
</html>`;

  return { subject, html, text };
}

module.exports = { buildVerificationEmail };
