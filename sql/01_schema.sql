-- ============================================================================
--  LUCKY DRAW — complete database schema
--  Part 1 of 3 : extensions, tables, row level security, configuration
-- ============================================================================
--  Run these three files IN ORDER against a fresh Supabase project:
--     01_schema.sql   <- you are here
--     02_public.sql   functions any visitor may call
--     03_admin.sql    functions gated by the admin password
--
--  Everything is idempotent. Re-running is safe.
--
--  SECURITY MODEL, in one paragraph: no table is reachable from the public
--  REST API. `anon` and `authenticated` are revoked on every table and Row
--  Level Security is on with no permissive policy, so a direct request to
--  /rest/v1/participants returns nothing no matter who asks. All access goes
--  through `security definer` functions, which are the only things granted to
--  `anon`. Those functions decide what a caller may see. Read 02 and 03 with
--  that in mind: the checks in them are the whole of the authorisation model.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
--  Guard against this project's most dangerous default.
--  Some Supabase projects carry ALTER DEFAULT PRIVILEGES granting anon and
--  authenticated full rights on every newly created table. If that is set,
--  every table below would be world-writable the instant it is created.
--  Neutralise it before creating anything.
-- ---------------------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  TABLES
-- ═══════════════════════════════════════════════════════════════════════════

-- Key/value settings. Also holds the admin password digest, which is why this
-- table in particular must never be readable by anon.
create table if not exists app_config (
  key    text primary key,
  value  text not null
);

-- One row per entrant.
-- The identity document is NEVER stored. ic_hash is a SHA-256 of the
-- normalised document; ic_last4 exists only so staff can confirm a person at
-- the counter. There is deliberately no way back to the original.
create table if not exists participants (
  id            bigserial primary key,
  ic_hash       text        not null unique,
  ic_last4      text        not null,
  full_name     text        not null,
  phone         text        not null,
  platform      text        not null default 'instagram',
  handle        text        not null default '',
  disqualified  boolean     not null default false,
  dq_reason     text,
  created_at    timestamptz not null default now()
);
create index if not exists participants_created_idx on participants (created_at desc);
create index if not exists participants_name_idx    on participants (upper(full_name));

-- One row per person per calendar day. The unique constraint is what makes a
-- double scan harmless rather than a double ticket.
create table if not exists checkins (
  id             bigserial primary key,
  participant_id bigint      not null references participants(id) on delete cascade,
  visit_date     date        not null,
  source         text        not null default 'scan',
  created_at     timestamptz not null default now(),
  unique (participant_id, visit_date)
);
create index if not exists checkins_date_idx on checkins (visit_date desc);

-- Social-follow and repost claims. One row per person per platform.
-- 'repost' is stored here too, with platform = 'repost'.
create table if not exists claims (
  id             bigserial primary key,
  participant_id bigint      not null references participants(id) on delete cascade,
  platform       text        not null,
  handle         text        not null default '',
  status         text        not null default 'approved',
  created_at     timestamptz not null default now(),
  unique (participant_id, platform)
);

-- Subscription months, imported from your billing export.
-- months REPLACES, never accumulates. Every import must carry the cumulative
-- total per person. This is what makes re-importing the same file a no-op.
create table if not exists renewals (
  participant_id bigint      primary key references participants(id) on delete cascade,
  months         integer     not null default 0 check (months >= 0),
  updated_at     timestamptz not null default now()
);

-- Manual staff corrections. Always visible to the entrant, with the reason.
create table if not exists ticket_adjustments (
  id             bigserial   primary key,
  participant_id bigint      not null references participants(id) on delete cascade,
  delta          integer     not null check (delta <> 0 and delta between -60 and 60),
  reason         text        not null,
  created_at     timestamptz not null default now()
);

-- Prizes, drawn in ascending draw_seq. tier 1 is the grand prize.
create table if not exists prizes (
  tier      integer primary key,
  name      text    not null,
  subtitle  text    not null default '',
  qty       integer not null check (qty > 0),
  draw_seq  integer not null
);

-- THE POOL. One row per issued ticket, with a permanent serial.
-- Serials are assigned in true chronological order of earning, so a person's
-- tickets scatter across the pool instead of sitting in one contiguous block.
-- Contiguous blocks look rigged even when they are not.
create table if not exists draw_tickets (
  serial         bigint      primary key,
  participant_id bigint      not null references participants(id) on delete cascade,
  source         text        not null,   -- checkin | renewal | social | repost | adjust
  detail         text        not null default '',
  earned_at      timestamptz not null,
  created_at     timestamptz not null default now()
);
create index if not exists draw_tickets_pid_idx on draw_tickets (participant_id);

-- One row per prize slot won.
create table if not exists winners (
  id             bigserial   primary key,
  tier           integer     not null references prizes(tier),
  seq            integer     not null,
  participant_id bigint      not null references participants(id) on delete cascade,
  serial         bigint,
  tickets_held   integer     not null default 0,
  claimed        boolean     not null default false,
  claimed_at     timestamptz,
  drawn_at       timestamptz not null default now(),
  unique (tier, seq),
  unique (participant_id)
);

-- Forfeited winners. Archived with a written reason; never drawn again.
create table if not exists draw_voids (
  id             bigserial   primary key,
  tier           integer     not null,
  seq            integer     not null,
  participant_id bigint      not null references participants(id) on delete cascade,
  serial         bigint,
  tickets_held   integer     not null default 0,
  reason         text        not null,
  created_at     timestamptz not null default now()
);

-- Rehearsal sandbox. Same engine, separate table, wiped freely.
create table if not exists rehearsal_winners (
  id             bigserial   primary key,
  tier           integer     not null,
  seq            integer     not null,
  participant_id bigint      not null references participants(id) on delete cascade,
  serial         bigint,
  tickets_held   integer     not null default 0,
  drawn_at       timestamptz not null default now(),
  unique (tier, seq)
);

-- Audit trail for staff edits to a participant's details.
create table if not exists participant_edits (
  id             bigserial   primary key,
  participant_id bigint      not null,
  fields         jsonb       not null,
  created_at     timestamptz not null default now()
);

-- Deleted participants are archived, not erased, so a ledger can still be
-- reconciled after a deletion.
create table if not exists deleted_participants (
  id           bigserial   primary key,
  ic_hash      text        not null,
  ic_last4     text        not null,
  full_name    text        not null,
  phone        text        not null,
  tickets_held integer     not null default 0,
  deleted_at   timestamptz not null default now()
);

-- Failed admin password attempts, for rate limiting.
create table if not exists admin_auth_fails (
  id         bigserial   primary key,
  ip         text        not null,
  created_at timestamptz not null default now()
);
create index if not exists admin_auth_fails_idx on admin_auth_fails (ip, created_at desc);

-- ═══════════════════════════════════════════════════════════════════════════
--  LOCK EVERY TABLE DOWN
--  Nothing here is reachable from the REST API. RLS is enabled with no
--  permissive policy, which denies everything by default; the revokes are
--  belt and braces in case a policy is ever added by mistake.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  foreach t in array array[
    'app_config','participants','checkins','claims','renewals',
    'ticket_adjustments','prizes','draw_tickets','winners','draw_voids',
    'rehearsal_winners','participant_edits','deleted_participants',
    'admin_auth_fails'
  ] loop
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

revoke all on all sequences in schema public from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  DEFAULT CONFIGURATION
--  Only inserted if absent, so re-running never overwrites your settings.
-- ═══════════════════════════════════════════════════════════════════════════
insert into app_config (key, value) values
  ('checkin_pts_per_day',   '3'),
  ('checkin_max_days',      '7'),
  ('social_points',         '3'),
  ('repost_points',         '6'),
  ('renewal_pts_per_month', '1'),
  ('renewal_max_months',    '0'),        -- 0 = no cap
  ('pool_locks_at',         '2099-12-31T23:59:59+08:00'),
  ('ticket_numbers_public', 'true'),
  ('poster_instagram',      ''),
  ('poster_facebook',       ''),
  ('timezone',              'Asia/Kuala_Lumpur'),
  -- CHANGE THIS IMMEDIATELY. Default password is: changeme
  ('admin_secret',          crypt('changeme', gen_salt('bf', 10)))
on conflict (key) do nothing;

-- Example prize ladder. Replace with your own; tier 1 is drawn last and is
-- treated as the grand prize by the console.
insert into prizes (tier, name, subtitle, qty, draw_seq) values
  (8, 'Consolation prize', '',            10, 1),
  (7, 'Voucher',           'Small',        5, 2),
  (6, 'Voucher',           'Medium',       3, 3),
  (5, 'Voucher',           'Large',        2, 4),
  (4, 'Bundle',            '',             2, 5),
  (3, '3rd prize',         '',             1, 6),
  (2, '2nd prize',         '',             1, 7),
  (1, 'Grand prize',       '',             1, 8)
on conflict (tier) do nothing;
