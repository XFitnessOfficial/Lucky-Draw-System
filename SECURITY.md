# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Report privately via GitHub's **Security → Report a vulnerability** tab on this
repository. We aim to acknowledge within 72 hours.

## Design notes for anyone auditing this code

This is a static frontend talking to a PostgreSQL backend through PostgREST.
There is no application server. That means:

- **The `anon` key is public by design.** It identifies the project, it does
  not authorise anything. All authorisation is Row Level Security plus
  `security definer` functions.
- **Every write goes through an RPC**, never through a direct table endpoint.
  Tables are revoked from `anon` and `authenticated`.
- **The admin console is a static file.** It is not a trusted boundary. Every
  admin RPC independently verifies the password server-side; the console
  simply holds it in memory and passes it on each call.
- **Identity documents are never stored in plaintext.** ICs and passports are
  normalised and SHA-256 hashed on arrival; only the hash and the last four
  characters persist.

## Two deployment landmines specific to this stack

Both are easy to hit and neither reproduces in the Supabase SQL Editor.

1. **`ALTER DEFAULT PRIVILEGES` on this schema grants `anon` full rights on
   every newly created table.** Every new table needs, immediately:
   ```sql
   revoke all on <table> from public, anon, authenticated;
   alter table <table> enable row level security;
   ```
   Miss this and the table is world-readable and world-writable through the
   public REST endpoint.

2. **The `authenticator` role preloads `safeupdate`.** Any `DELETE` or
   `UPDATE` inside a function must carry a `WHERE` clause, even `WHERE true`.
   This does not fire in the SQL Editor (which runs as `postgres`); it only
   surfaces at runtime through the deployed app.

## What this repository does and does not keep secret

This code is public, and it is the same code that runs a live deployment. That
is deliberate, and it is only safe because of what the repository deliberately
does **not** contain.

**Not secret, and must not need to be:** table names, function names, argument
names, error codes, the shape of every response, the fact that the admin
console is a static file at `/admin.html`, and the fact that entrants log in
with an identity document alone. All of that is readable in the browser on any
deployment. A system whose safety depends on an attacker not knowing its schema
is a system with no safety at all — authorisation is the control, not
obscurity. That is why `01_schema.sql` revokes `anon` on every table: once that
is done, knowing a table's name buys nothing.

**Deliberately not published, because it is genuinely per-deployment:** the
admin password, obviously, but also the **login throttle thresholds**. Those
live in `app_config` (`auth_max_fails`, `auth_window_minutes`,
`auth_delay_ms`) rather than being written into the function body. Published
thresholds let an attacker pace a password attack to sit just under the limit,
which is the one piece of tuning that is worth more to them than to anyone
reading this code. Change them from the defaults.

The same reasoning applies to `qr_token`: the QR carries a random UUID rather
than anything derived from the identity document, so publishing exactly how the
QR is built gives an attacker nothing to reverse.

## Before you deploy your own instance

- Set a **long, random** admin password. The stored form is a SHA-256 digest;
  it is not salted and not key-stretched, so a short or dictionary password is
  weak if the digest is ever exposed.
- Confirm `app_config` is not readable by `anon` — see the deployment checklist
  in the README.
