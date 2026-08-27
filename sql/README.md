# Backend setup

Three files, run in order, against a fresh Supabase project. There is no
migration tool and no build step — paste each one into the SQL Editor and run
it, or use `supabase db push`.

| File | What it creates |
|---|---|
| `01_schema.sql` | 14 tables, indexes, Row Level Security, default config, an example prize ladder |
| `02_public.sql` | Ticket arithmetic, the pool builder, and the 7 functions any visitor may call |
| `03_admin.sql` | Password auth with throttling, and the 35 password-gated functions |

All three are idempotent. Re-running is safe.

---

## 1. Run them

Supabase Dashboard → SQL Editor → New query → paste `01_schema.sql` → Run.
Repeat for `02` and `03`, **in that order** — `03` depends on helpers defined
in `02`.

## 2. Change the password immediately

The default is `changeme`. It is stored as a bcrypt digest, but a default is a
default.

```sql
select xf_admin_set_password('changeme', 'your-long-random-password-here');
```

Minimum 10 characters, and please make it long and random rather than
memorable — this one password is the entire admin boundary.

## 3. Set your dates and prizes

```sql
-- When ticket earning stops. After this, the pool is frozen: no new
-- registrations, claims, check-ins, imports or adjustments.
update app_config set value = '2026-12-31T23:59:59+08:00' where key = 'pool_locks_at';

update app_config set value = 'Asia/Kuala_Lumpur' where key = 'timezone';
```

Replace the example prize ladder with yours. `tier` 1 is the grand prize and is
drawn last; `draw_seq` controls the order, ascending.

```sql
delete from prizes where true;
insert into prizes (tier, name, subtitle, qty, draw_seq) values
  (3, 'Dinner for two', 'Any outlet', 5, 1),
  (2, 'Weekend stay',   '',          2, 2),
  (1, 'Grand prize',    '',          1, 3);
```

## 4. Check it works

```sql
select xf_points();                    -- should return your ticket values
select xf_admin_check('your-password'); -- should return {"ok": true}
```

## 5. Verify nothing is publicly readable

The single most important check. Paste this into a browser with your own
project ref and anon key:

```
https://YOUR-REF.supabase.co/rest/v1/app_config?select=*&apikey=YOUR_ANON_KEY
```

You want an error or `[]`. If rows come back, `01_schema.sql` did not take
effect and your password digest is publicly readable — stop and re-run it.

Repeat for `participants`, `draw_tickets`, `winners`.

---

## How the ticket pool works

`draw_tickets` holds one row per issued ticket, each with a permanent serial.
`xf_issue_tickets()` rebuilds it from the underlying records, and every write
path calls it, so the pool is never stale.

The rebuild has two properties that pull against each other, and both matter:

**Stable.** Rebuilding produces identical numbering. Somebody who screenshotted
"No 4,415" still holds No 4,415 tomorrow. Ordering is `(earned_at, md5 of the
row's identity)` — the hash is deterministic, so a rebuild reproduces it
exactly.

**Scattered.** The hash does not correlate with the person, so entrants
interleave. This matters more than it sounds: with a naive `participant_id`
tie-break, a bulk import of 200 renewals lands as 200 contiguous per-person
blocks, and a pool where each person owns one unbroken run of numbers looks
rigged to anyone reading the board — even though it is not.

`earned_at` is the **record** time, not the visit date, so backdating a missed
check-in appends at the end rather than renumbering everyone after it.

Once `pool_locks_at` passes, `xf_issue_tickets()` becomes a no-op and existing
serials are frozen permanently.

## How the draw works

`xf_draw_pick` selects **one uniformly random row from `draw_tickets`**. Someone
holding ten tickets is ten rows, so their chance scales with what they earned —
no weighting code, nothing to get wrong.

Verified on a local Postgres over 20,000 simulated draws: chi-square 9.15 on 9
degrees of freedom, against a critical value of 16.92 at p = 0.05. Win rates
tracked ticket shares to within half a percentage point.

Before any pick, the function counts entrants whose ticket total does not match
their number of serials. If that is non-zero it returns `ledger_stale` and
**refuses to draw**. A pool that is not a faithful copy produces a winner nobody
can verify.

Previous winners are excluded, so one person wins at most one prize. If the
eligible pool empties before a tier is full, the tier closes `exhausted` and
the draw moves on rather than stalling.

**There is no override and no way to steer the result.** That is deliberate.
If someone can choose the winner, nothing else here means anything. Please do
not add one when you fork this.

## Security model

No table is reachable from the REST API. `anon` and `authenticated` are revoked
on all 14 tables, Row Level Security is enabled and forced with no permissive
policy, and every sequence is revoked too. A direct request to
`/rest/v1/participants` returns nothing regardless of who asks.

All access goes through `security definer` functions with a pinned
`search_path`. Only these are granted to `anon`:

- the 7 public functions
- the 35 `xf_admin_*` functions, each of which verifies the password itself

Internal helpers — `xf_admin_ok`, `xf_issue_tickets`, `xf_draw_pick`,
`xf_draw_state`, `xf_me_payload`, `xf_ticket_counts`, `xf_cfg` — are granted to
nobody and are only reachable through the checked wrappers.

`01_schema.sql` opens by revoking `ALTER DEFAULT PRIVILEGES` on tables,
sequences and functions for `anon` and `authenticated`. Some Supabase projects
carry a default that grants those roles full rights on every newly created
table; without that revoke, every table would be world-writable the instant it
was created.

**Identity documents are never stored.** `xf_register` normalises and SHA-256
hashes the document on arrival and keeps only the hash plus the last four
characters. There is no path back to the original, including for you. The QR
code on an entrant's page carries the hash, so a photographed QR leaks nothing.

**Password throttling fails closed.** Twelve failures from one IP within
fifteen minutes locks that IP out, and an attempt whose IP cannot be determined
is counted against a shared bucket rather than waved through. The opposite
choice makes the limit decorative, because anyone who can suppress the header
gets unlimited guesses. Losing the console for fifteen minutes is the lesser
problem. A successful login clears that IP's failures.

## If you are extending this

Two things that will bite you, neither of which reproduces in the SQL Editor:

**Every new table needs `revoke` + `enable row level security` immediately.**
See the `do $$` block at the end of `01_schema.sql` for the pattern.

**Every `DELETE` and `UPDATE` inside a function needs a `WHERE`,** even
`WHERE true`. The `authenticator` role preloads `safeupdate`; the SQL Editor
runs as `postgres` and will not warn you, so this only surfaces at runtime
through the deployed app. Grep this codebase for `-- WHERE required` to see
where it applies.

And end every migration that adds or replaces a function with:

```sql
notify pgrst, 'reload schema';
```

Without it PostgREST keeps serving the previous definition.
