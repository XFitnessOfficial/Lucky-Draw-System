# Lucky Draw

A production-grade prize draw system for physical businesses. Customers
register once, earn tickets by showing up and by engaging online, and watch
the winners get drawn live on a screen.

Built and run by **X FITNESS GYM SDN. BHD.** for our first anniversary draw,
and open sourced so other businesses do not have to build it again.

Nothing in it is gym-specific. A restaurant, a salon, a retail chain or a car
workshop can run the same campaign by changing copy and images.

---

## What it does

**For the customer** — one page, no app, no download.

- Register once with name, phone, ID and a social handle
- Log back in with the ID alone; a QR code is their entrant code
- See every ticket they hold, where each one came from, and their live odds
- Four ways to earn: checking in, subscription renewals, following on social,
  tagging and reposting
- English, 中文 and Bahasa Malaysia throughout

**For staff** — a password-gated console on the same origin.

- Scan entrant QR codes to record a check-in, or run a tablet in kiosk mode
  where customers scan themselves
- Import renewals or check-ins from a CSV your billing system already exports
- Reconcile before you write: see exactly who will not match, and why, before
  anything touches the database
- Search, edit, adjust, disqualify or delete an entrant, with every action
  logged and attributed
- A ticket ledger that reconciles issued serials against every entrant's
  balance, so a mismatch is visible before draw night rather than on stage

**For draw night** — a full-screen arena built for a room full of people.

- Rolls the winning ticket number digit by digit on a gold foil ticket, then
  lifts the winner's name in above it
- Pacing scales with prize rank: small prizes move fast, the top three get a
  countdown and a silent beat before the last digit
- All sound is synthesised in the browser — no audio files to lose
- Rehearsal mode recolours the ticket so a practice run can never be mistaken
  for the real thing
- Void and redraw a prize on the spot if a winner cannot claim it

---

## Design principles

These came out of running a real draw with real prizes and a room watching.

**The person is the unit. The ticket number is the receipt.** Names display
first and largest; the winning ticket number sits below, never above.

**Serial numbers are assigned in true chronological order of earning.** They
scatter across the pool rather than sitting in contiguous per-person blocks.
Contiguous blocks look rigged even when they are not, and how it looks matters
on stage.

**The draw picks a uniform random ticket number**, not a weighted person. It is
mathematically identical to weighting people by ticket count — we verified this
across 44,000 simulated draws (chi-square 348.5 against 351.8 at 343 degrees of
freedom) — but the winning ticket becomes a real, showable object.

**No predetermined winner. No override. Not built, and not going to be.** If
someone can pick the winner, nothing else in the system means anything.

**Identity documents are never stored.** IDs are normalised and hashed on
arrival; only the hash and the last four characters persist. Recovering the
original is impossible, including for us.

**Every correction is visible to the person it affects.** A manual ticket
adjustment shows up on the customer's own page with the staff reason attached.

---

## Architecture

A static frontend talking to PostgreSQL through PostgREST. There is no
application server.

```
index.html    customer page, live draw arena, registration, QR
admin.html    staff console, scanner, kiosk, imports, ledger, draw controls
config.js     Supabase URL + anon key (gitignored; copy config.example.js)
terms.html    generated from TERMS.md by build_terms.py — never hand-edit
assets/       images, fonts, and two self-hosted JS libraries
```

No build step. No bundler. No framework. Two HTML files, vanilla JavaScript,
deployed as static files. Editing it does not require a toolchain, which
matters when the person maintaining it is a business owner rather than a
full-time engineer.

**The backend is not in this repository.** See the next section.

---

## Getting started

### 1. You need to build the backend

This repository is the frontend. It expects **38 PostgreSQL functions** exposed
through PostgREST, and those are not included.

That is deliberate. Our production functions encode our own authentication
flow, our rate-limiting thresholds and their failure modes. Publishing them
would be publishing our door codes. What we publish instead is the contract.

**[`API_CONTRACT.md`](API_CONTRACT.md)** lists all 38 functions with the exact
arguments the frontend sends, along with the six rules any implementation has
to follow. Build against it and this frontend runs unmodified.

Tables you will need:

| Table | Holds |
|---|---|
| `participants` | one row per entrant: name, phone, hashed ID, social handle |
| `draw_tickets` | one row per issued ticket, with a permanent serial |
| `checkins` | one row per person per day |
| `claims` | social-follow and repost claims |
| `app_config` | key/value settings, including the admin password digest |
| `prizes` | tier, name, quantity |
| `winners` | one row per prize won, with the serial that won it |

Plus audit tables: `ticket_adjustments`, `participant_edits`,
`admin_auth_fails`, `draw_voids`, `deleted_participants`.

### 2. Configure

```bash
cp config.example.js config.js
```

Fill in your Supabase URL, your anon key, your draw date and your social links.
`config.js` is gitignored on purpose.

Then edit `vercel.json`. Its Content-Security-Policy `connect-src` whitelists
exactly one Supabase host and currently reads `YOUR-PROJECT-REF`. **If you skip
this, the browser blocks every API call silently at the CSP layer** — you get a
CSP violation in the console rather than a network error, which is a confusing
hour to lose.

### 3. Replace the branding

Everything in `assets/` is X FITNESS artwork and is **not** covered by the MIT
licence. Replace it. See [`LICENSE`](LICENSE).

Also update `manifest.webmanifest`, `robots.txt`, `favicon.ico`, and bump the
cache key in `sw.js` or returning visitors get served stale files.

### 4. Rewrite the terms

`TERMS.md` → `build_terms.py` → `terms.html`. Never edit `terms.html` directly;
it is generated. The current text is ours and will not fit your campaign or
your jurisdiction.

### 5. Deploy

Any static host. We use Vercel via a GitHub push. There is nothing to compile.

---

## Adapting it to your industry

The system vocabulary is already neutral: *entrant*, *check-in*, *subscription
months*, *ticket*. What remains specific to us is campaign **content**, and it
lives in three places:

1. **The prize section in `index.html`** — ours are gym memberships and gift
   cards. Yours will not be.
2. **The promotion section** — our anniversary offer.
3. **The `I18N` object in `index.html`** — three language blocks, ~120 keys
   each. Change a string once per language and every screen follows.

`pkgMonths()` in `admin.html` maps your billing system's plan names to a number
of months. Ours understands things like `12-MONTH` and `JOIN ONLY`. Teach it
yours — it is one small function.

The CSV importer accepts several common column names for each field
(`ic`/`nric`/`id`, `membertype`/`plan`/`package`/`product`, `name`/`fullname`),
so many exports work without editing anything.

---

## Two deployment landmines

Both cost us real time. Neither reproduces in the Supabase SQL Editor, which is
what makes them expensive.

**`ALTER DEFAULT PRIVILEGES` may grant `anon` full rights on every newly
created table.** Check your project. If it applies, every new table needs,
immediately:

```sql
revoke all on <table> from public, anon, authenticated;
alter table <table> enable row level security;
```

Miss it and the table is world-readable and world-writable through the public
REST endpoint. Verify the one holding your admin password digest by opening
this in a browser:

```
https://YOUR-REF.supabase.co/rest/v1/app_config?select=*&apikey=YOUR_ANON_KEY
```

You want an error or `[]`. Rows coming back means anyone can read that table.

**The `authenticator` role preloads `safeupdate`.** Any `DELETE` or `UPDATE`
inside a function must carry a `WHERE` clause, even `WHERE true`. The SQL
Editor runs as `postgres` and will not warn you; this only surfaces at runtime
through the deployed app.

---

## Contributing

`admin.html` and `index.html` are single files with roughly 125 top-level
declarations each. Collisions are silent — a duplicate `const` or a duplicate
object key does not warn, the second one simply wins. This has caused real
production bugs here twice.

Before opening a pull request, check:

1. No duplicate top-level `const` / `let` / `function` names
2. No duplicate keys in any language's i18n object
3. All three languages updated when copy changes
4. All form controls **≥16px** — Safari auto-zooms on focus below that and does
   not zoom back on blur. `maximum-scale=1` is not an acceptable fix; modern
   Safari ignores it and it breaks accessibility pinch-zoom
5. `node --check` passes on the inline scripts

Security issues: please do not open a public issue. See
[`SECURITY.md`](SECURITY.md).

---

## Licence

Code is [MIT](LICENSE).

The X FITNESS name, logo, wordmark and the brand artwork in `assets/` are
trademarks and copyright of X FITNESS GYM SDN. BHD. and are **not** licensed
for reuse. Use the code freely; please do not ship something that looks like it
came from us.

Bundled third-party libraries and their licences are listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

---

<div align="center">

Built in Johor Bahru, Malaysia by **X FITNESS GYM SDN. BHD.**

</div>
