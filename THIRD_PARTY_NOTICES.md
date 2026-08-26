# Third-Party Notices

This project bundles the following third-party software. Full licence texts
are in [`licenses/`](licenses/).

| Library | Version | Licence | Bundled at |
|---|---|---|---|
| [html5-qrcode](https://github.com/mebjas/html5-qrcode) | 2.3.8 | Apache-2.0 | `assets/html5-qrcode-2.3.8.min.js` |
| [qrcodejs](https://github.com/davidshimjs/qrcodejs) | 1.0.0 | MIT | `assets/qrcode-1.0.0.min.js` |

Both are self-hosted rather than loaded from a CDN. That was a deliberate
call: during testing, a phone on a mobile network could not reach
`cdnjs.cloudflare.com`, and a check-in kiosk that silently fails to load its
scanner is worse than a slightly larger page.

## Fonts

Loaded at runtime from Google Fonts, not redistributed here:
JetBrains Mono, Bodoni Moda, Inter, Noto Serif SC — all
[SIL Open Font License 1.1](https://openfontlicense.org/).

## Backend

Supabase (PostgreSQL + PostgREST). Not bundled; you bring your own project.
