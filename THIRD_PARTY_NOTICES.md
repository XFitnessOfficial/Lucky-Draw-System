# Third-Party Notices

This project bundles the following third-party software. Full licence texts
are in [`licenses/`](licenses/).

| Library | Version | Licence | Bundled at |
|---|---|---|---|
| [html5-qrcode](https://github.com/mebjas/html5-qrcode) | 2.3.8 | Apache-2.0 | `assets/html5-qrcode-2.3.8.min.js` |
| [qrcodejs](https://github.com/davidshimjs/qrcodejs) | 1.0.0 | MIT | `assets/qrcode-1.0.0.min.js` |

Both are self-hosted rather than loaded from a CDN, and there is no CDN
fallback. Two reasons: a phone on a patchy mobile network could not reliably
reach a CDN during testing, and more importantly the admin console holds the
admin password in memory — a console that can be made to execute a third
party's script is a console whose password is only as safe as that third
party. `script-src` in `vercel.json` is `'self'` accordingly.

Both libraries are at their latest published version and neither has a known
vulnerability, but both are unmaintained (html5-qrcode last released 2022,
qrcodejs 2013). Verify the bundled copies against the official releases before
trusting them:

```
curl -sL https://registry.npmjs.org/html5-qrcode/-/html5-qrcode-2.3.8.tgz | tar xz -O package/html5-qrcode.min.js | sha256sum
# 660b12437b1d747e3e68b8be0685c08cb728140110ad213f167b14b66f8b1d8e

curl -sL https://registry.npmjs.org/qrcodejs/-/qrcodejs-1.0.0.tgz | tar xz -O package/qrcode.min.js | sha256sum
# c541ef06327885a8415bca8df6071e14189b4855336def4f36db54bde8484f36
```

## Fonts

Loaded at runtime from Google Fonts, not redistributed here:
JetBrains Mono, Bodoni Moda, Inter, Noto Serif SC — all
[SIL Open Font License 1.1](https://openfontlicense.org/).

## Backend

Supabase (PostgreSQL + PostgREST). Not bundled; you bring your own project.
