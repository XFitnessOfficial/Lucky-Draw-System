-- ============================================================================
--  LUCKY DRAW — Part 2 of 3 : helpers + public functions
-- ============================================================================
--  Everything here is callable by anyone holding the anon key. Treat every
--  argument as hostile. These functions are `security definer`, so they run
--  with the table owner's rights — that is exactly why each one must do its
--  own checking, and why `search_path` is pinned on every single one.
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
--  HELPERS  (not granted to anon — internal use only)
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function xf_cfg(p_key text, p_default text default null)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select value from app_config where key = p_key), p_default)
$$;

create or replace function xf_cfg_int(p_key text, p_default integer)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(nullif(xf_cfg(p_key), '')::integer, p_default)
$$;

create or replace function xf_tz()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(xf_cfg('timezone'), 'Asia/Kuala_Lumpur')
$$;

create or replace function xf_today()
returns date language sql stable security definer set search_path = public as $$
  select (now() at time zone xf_tz())::date
$$;

-- Normalise an identity document before hashing, so the same person typing
-- "990101-01-1234" and "990101011234" resolves to one record.
create or replace function xf_norm_ic(p_ic text)
returns text language sql immutable as $$
  select upper(regexp_replace(coalesce(p_ic, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

create or replace function xf_hash_ic(p_ic text)
returns text language sql immutable as $$
  select encode(digest(xf_norm_ic(p_ic), 'sha256'), 'hex')
$$;

create or replace function xf_pool_locked()
returns boolean language sql stable security definer set search_path = public as $$
  select now() >= coalesce(xf_cfg('pool_locks_at')::timestamptz, 'infinity'::timestamptz)
$$;

-- ---------------------------------------------------------------------------
--  Ticket arithmetic. One place, so the customer page, the admin console and
--  the draw can never disagree about how many tickets somebody holds.
-- ---------------------------------------------------------------------------
create or replace function xf_ticket_counts(p_id bigint)
returns table (checkin integer, renewal integer, social integer,
               repost integer, adjust integer, total integer)
language sql stable security definer set search_path = public as $$
  with
  c as (select least(count(*), xf_cfg_int('checkin_max_days', 7))
               * xf_cfg_int('checkin_pts_per_day', 3) as n
          from checkins where participant_id = p_id),
  r as (select case when xf_cfg_int('renewal_max_months', 0) > 0
                    then least(coalesce(max(months), 0), xf_cfg_int('renewal_max_months', 0))
                    else coalesce(max(months), 0) end
               * xf_cfg_int('renewal_pts_per_month', 1) as n
          from renewals where participant_id = p_id),
  s as (select count(*) * xf_cfg_int('social_points', 3) as n
          from claims where participant_id = p_id
           and platform <> 'repost' and status = 'approved'),
  p as (select count(*) * xf_cfg_int('repost_points', 6) as n
          from claims where participant_id = p_id
           and platform = 'repost' and status = 'approved'),
  a as (select coalesce(sum(delta), 0) as n
          from ticket_adjustments where participant_id = p_id)
  select c.n::int, r.n::int, s.n::int, p.n::int, a.n::int,
         greatest(0, (c.n + r.n + s.n + p.n + a.n))::int
    from c, r, s, p, a
$$;

-- ---------------------------------------------------------------------------
--  Rebuild the ticket pool.
--
--  Serials are handed out in the real chronological order the tickets were
--  earned, across all people at once — NOT in contiguous per-person blocks.
--  This is a deliberate integrity choice: a pool where each person owns one
--  unbroken run of numbers looks fixed to anyone reading the board, and how
--  it looks matters when it is on a screen in front of a room.
--
--  Two properties this MUST have, and they pull against each other:
--
--   1. STABLE. Rebuilding must produce the identical numbering, or somebody
--      who screenshotted "No 4,415" finds a different number tomorrow.
--   2. SCATTERED. Ordering ties must not resolve by participant_id, or every
--      bulk import lands as one contiguous block per person.
--
--  Both are satisfied by ordering on (earned_at, md5 of the row's identity).
--  The hash is deterministic, so a rebuild reproduces it exactly; it does not
--  correlate with the person, so people interleave. earned_at is the RECORD
--  time, not the visit date, so backdating a missed check-in appends at the
--  end instead of renumbering everyone after it.
--
--  Rebuilding is safe and idempotent, but only while the pool is unlocked.
--  Once locked, existing serials are frozen forever.
-- ---------------------------------------------------------------------------
create or replace function xf_issue_tickets()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n bigint; v_max bigint;
begin
  if xf_pool_locked() then
    select count(*), coalesce(max(serial), 0) into v_n, v_max from draw_tickets;
    return jsonb_build_object('ok', true, 'locked', true,
                              'issued', v_n, 'max_serial', v_max);
  end if;

  -- Serials are only stable if we rebuild the whole thing in one shot.
  delete from draw_tickets where true;   -- WHERE required: safeupdate

  insert into draw_tickets (serial, participant_id, source, detail, earned_at)
  select row_number() over (
           order by src.earned_at,
                    md5(src.participant_id::text || '|' || src.source || '|' ||
                        src.detail || '|' || src.k::text)),
         src.participant_id, src.source, src.detail, src.earned_at
  from (
    -- one row per point earned; k makes each copy distinct for the hash
    select c.participant_id, 'checkin'::text as source,
           c.visit_date::text as detail, c.created_at as earned_at, k
      from (select participant_id, visit_date, created_at,
                   row_number() over (partition by participant_id order by visit_date) as rn
              from checkins) c
     cross join generate_series(1, xf_cfg_int('checkin_pts_per_day', 3)) k
     where c.rn <= xf_cfg_int('checkin_max_days', 7)

    union all
    select r.participant_id, 'renewal', 'month ' || g::text, r.updated_at,
           (g * 1000 + k)
      from renewals r
     cross join lateral generate_series(1,
            case when xf_cfg_int('renewal_max_months', 0) > 0
                 then least(r.months, xf_cfg_int('renewal_max_months', 0))
                 else r.months end) g
     cross join generate_series(1, xf_cfg_int('renewal_pts_per_month', 1)) k

    union all
    select cl.participant_id, 'social', cl.platform, cl.created_at, k
      from claims cl
     cross join generate_series(1, xf_cfg_int('social_points', 3)) k
     where cl.platform <> 'repost' and cl.status = 'approved'

    union all
    select cl.participant_id, 'repost', '', cl.created_at, k
      from claims cl
     cross join generate_series(1, xf_cfg_int('repost_points', 6)) k
     where cl.platform = 'repost' and cl.status = 'approved'

    union all
    select ta.participant_id, 'adjust', ta.reason, ta.created_at, k
      from ticket_adjustments ta
     cross join lateral generate_series(1, ta.delta) k
     where ta.delta > 0
  ) src
  join participants pt on pt.id = src.participant_id
  where not pt.disqualified;

  select count(*), coalesce(max(serial), 0) into v_n, v_max from draw_tickets;
  return jsonb_build_object('ok', true, 'locked', false,
                            'issued', v_n, 'max_serial', v_max);
end $$;

-- ---------------------------------------------------------------------------
--  The entrant payload. Shared by register / login / me / both claim calls so
--  the page always receives the identical shape.
-- ---------------------------------------------------------------------------
create or replace function xf_me_payload(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p participants%rowtype; t record; v jsonb;
begin
  select * into p from participants where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select * into t from xf_ticket_counts(p_id);

  v := jsonb_build_object(
    'ok', true,
    'name', p.full_name,
    'ic_last4', p.ic_last4,
    'platform', p.platform,
    'disqualified', p.disqualified,
    -- An opaque random token. Not the document, and not derived from it, so
    -- a photographed QR code reveals nothing about the person. See the
    -- qr_token comment in 01_schema.sql for why this is not paranoia.
    'qr', 'LD1:' || p.qr_token::text,
    'tickets', jsonb_build_object(
      'total', t.total, 'checkin', t.checkin, 'renewal', t.renewal,
      'social', t.social, 'repost', t.repost, 'adjust', t.adjust),
    'checkin_dates', coalesce((select jsonb_agg(visit_date::text order by visit_date)
                                 from checkins where participant_id = p_id), '[]'::jsonb),
    'social', coalesce((select jsonb_object_agg(platform, true)
                          from claims where participant_id = p_id
                           and platform <> 'repost' and status = 'approved'), '{}'::jsonb),
    'repost', coalesce((select status from claims
                         where participant_id = p_id and platform = 'repost'), 'none'),
    'adjustments', coalesce((select jsonb_agg(jsonb_build_object(
                              'delta', delta, 'reason', reason,
                              'at', to_char(created_at at time zone xf_tz(), 'DD Mon YYYY'))
                              order by created_at)
                              from ticket_adjustments where participant_id = p_id), '[]'::jsonb),
    'prize', (select jsonb_build_object(
                'tier', w.tier, 'name', pz.name, 'subtitle', pz.subtitle,
                'claimed', w.claimed,
                'claimed_at', to_char(w.claimed_at at time zone xf_tz(), 'DD Mon YYYY'))
                from winners w join prizes pz on pz.tier = w.tier
               where w.participant_id = p_id)
  );
  return v;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  PUBLIC FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function xf_points()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ok', true,
    'checkin_pts_per_day',   xf_cfg_int('checkin_pts_per_day', 3),
    'checkin_max_days',      xf_cfg_int('checkin_max_days', 7),
    'social_points',         xf_cfg_int('social_points', 3),
    'repost_points',         xf_cfg_int('repost_points', 6),
    'renewal_pts_per_month', xf_cfg_int('renewal_pts_per_month', 1),
    'renewal_max_months',    xf_cfg_int('renewal_max_months', 0),
    'poster', jsonb_build_object(
      'instagram', coalesce(xf_cfg('poster_instagram'), ''),
      'facebook',  coalesce(xf_cfg('poster_facebook'), '')))
$$;

create or replace function xf_register(
  p_ic text, p_name text, p_phone text, p_platform text, p_handle text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_hash text; v_norm text; v_id bigint;
begin
  v_norm := xf_norm_ic(p_ic);
  -- 6..20 accommodates both national IDs and foreign passports. An earlier
  -- 12-character cap silently truncated longer passports, which then failed
  -- to match at the counter — the fix is to allow the real range.
  if length(v_norm) < 6 or length(v_norm) > 20 then
    return jsonb_build_object('ok', false, 'error', 'bad_ic');
  end if;
  if length(btrim(coalesce(p_name, ''))) < 2 then
    return jsonb_build_object('ok', false, 'error', 'bad_name');
  end if;
  if length(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g')) < 8 then
    return jsonb_build_object('ok', false, 'error', 'bad_phone');
  end if;
  if xf_pool_locked() then
    return jsonb_build_object('ok', false, 'error', 'closed');
  end if;

  v_hash := xf_hash_ic(p_ic);
  select id into v_id from participants where ic_hash = v_hash;
  if found then
    return jsonb_build_object('ok', false, 'error', 'already_registered');
  end if;

  insert into participants (ic_hash, ic_last4, full_name, phone, platform, handle)
  values (v_hash, right(v_norm, 4), btrim(p_name),
          btrim(p_phone),
          case when lower(coalesce(p_platform,'')) in ('instagram','facebook')
               then lower(p_platform) else 'instagram' end,
          btrim(coalesce(p_handle, '')))
  returning id into v_id;

  perform xf_issue_tickets();
  return xf_me_payload(v_id);
end $$;

create or replace function xf_login(p_ic text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  select id into v_id from participants where ic_hash = xf_hash_ic(p_ic);
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return xf_me_payload(v_id);
end $$;

create or replace function xf_me(p_ic text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  select id into v_id from participants where ic_hash = xf_hash_ic(p_ic);
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return xf_me_payload(v_id);
end $$;

create or replace function xf_claim_social(p_ic text, p_platform text, p_handle text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_plat text;
begin
  select id into v_id from participants where ic_hash = xf_hash_ic(p_ic);
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if xf_pool_locked() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if exists (select 1 from participants where id = v_id and disqualified) then
    return jsonb_build_object('ok', false, 'error', 'disqualified');
  end if;

  v_plat := lower(btrim(coalesce(p_platform, '')));
  if v_plat not in ('instagram','facebook','tiktok','xhs','google') then
    return jsonb_build_object('ok', false, 'error', 'bad_platform');
  end if;

  -- Only instagram and facebook store a handle. TikTok and RedNote deliberately
  -- store nothing: those platforms give no way to verify a follow, so keeping
  -- a handle would imply a check that cannot happen. Say so in your T&C.
  insert into claims (participant_id, platform, handle, status)
  values (v_id, v_plat,
          case when v_plat in ('instagram','facebook')
               then left(btrim(coalesce(p_handle, '')), 60) else '' end,
          'approved')
  on conflict (participant_id, platform) do nothing;

  perform xf_issue_tickets();
  return xf_me_payload(v_id);
end $$;

create or replace function xf_claim_repost(p_ic text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  select id into v_id from participants where ic_hash = xf_hash_ic(p_ic);
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if xf_pool_locked() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if exists (select 1 from participants where id = v_id and disqualified) then
    return jsonb_build_object('ok', false, 'error', 'disqualified');
  end if;

  insert into claims (participant_id, platform, handle, status)
  values (v_id, 'repost', '', 'approved')
  on conflict (participant_id, platform) do nothing;

  perform xf_issue_tickets();
  return xf_me_payload(v_id);
end $$;

-- The entrant's own serials, grouped into runs so the page shows
-- "No 4,415 – 4,417" rather than three separate lines.
create or replace function xf_my_serials(p_ic text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_pool bigint; v_events jsonb; v_first bigint; v_last bigint; v_total bigint;
begin
  if coalesce(xf_cfg('ticket_numbers_public'), 'true') <> 'true' then
    return jsonb_build_object('ok', true, 'ready', false);
  end if;
  select id into v_id from participants where ic_hash = xf_hash_ic(p_ic);
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  perform xf_issue_tickets();
  select count(*) into v_pool from draw_tickets;

  with mine as (
    select serial, source, detail,
           to_char(earned_at at time zone xf_tz(), 'DD Mon YYYY') as at,
           serial - row_number() over (partition by source, detail order by serial) as grp
      from draw_tickets where participant_id = v_id),
  runs as (
    select source, detail, min(at) as at, min(serial) as f, max(serial) as t, count(*) as n
      from mine group by source, detail, grp order by min(serial))
  select jsonb_agg(jsonb_build_object('source', source, 'detail', detail,
                                      'at', at, 'from', f, 'to', t, 'n', n)),
         min(f), max(t), sum(n)
    into v_events, v_first, v_last, v_total
    from runs;

  return jsonb_build_object('ok', true, 'ready', true,
    'events', coalesce(v_events, '[]'::jsonb),
    'first', coalesce(v_first, 0), 'last', coalesce(v_last, 0),
    'total', coalesce(v_total, 0), 'pool', v_pool);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  GRANTS — the public surface, and nothing else
-- ═══════════════════════════════════════════════════════════════════════════
grant execute on function
  xf_points(), xf_register(text,text,text,text,text), xf_login(text), xf_me(text),
  xf_claim_social(text,text,text), xf_claim_repost(text), xf_my_serials(text)
  to anon, authenticated;

notify pgrst, 'reload schema';
