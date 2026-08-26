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

## Before you deploy your own instance

- Set a **long, random** admin password. The stored form is a SHA-256 digest;
  it is not salted and not key-stretched, so a short or dictionary password is
  weak if the digest is ever exposed.
- Confirm `app_config` is not readable by `anon` — see the deployment checklist
  in the README.
