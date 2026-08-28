-- ============================================================================
--  LUCKY DRAW — Part 3 of 3 : admin functions
-- ============================================================================
--  Every function here takes p_secret and verifies it ITSELF before doing
--  anything. The admin console is a static HTML file served publicly — it is
--  not a security boundary, and a function that trusts its caller because
--  "only the console calls it" is already broken.
--
--  The password is stored as a bcrypt digest (pgcrypto `crypt` with
--  gen_salt('bf')), which is salted and deliberately slow. Do not replace it
--  with a bare sha256: an unsalted digest of a human-chosen password falls to
--  a wordlist in seconds if it is ever exposed.
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
--  AUTHENTICATION
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function xf_client_ip()
returns text language plpgsql stable as $$
declare v text;
begin
  -- PostgREST forwards request headers as a JSON GUC. Absent outside PostgREST.
  begin
    v := split_part(
           coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''),
           ',', 1);
  exception when others then v := '';
  end;
  return nullif(btrim(coalesce(v, '')), '');
end $$;

-- Verify the admin password, with throttling.
--
-- This FAILS CLOSED. If the client IP cannot be determined, the attempt is
-- counted against a shared bucket rather than waved through. The opposite
-- choice — skip throttling when the IP is unknown — turns the rate limit into
-- decoration, because an attacker who can suppress the header gets unlimited
-- guesses. Losing the console for fifteen minutes is the lesser problem.
--
-- CHANGE THE THRESHOLDS FOR YOUR INSTALL. They live in app_config
-- (auth_max_fails, auth_window_minutes, auth_delay_ms) precisely so that
-- reading this file tells an attacker nothing about how any particular
-- deployment is tuned. Values published in a repository are values an
-- attacker can pace an attack against.
create or replace function xf_admin_ok(p_secret text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_hash text; v_ip text; v_fails int; v_ok boolean;
        v_max int; v_win int; v_delay numeric;
begin
  v_ip    := coalesce(xf_client_ip(), 'unknown');
  v_max   := xf_cfg_int('auth_max_fails', 8);
  v_win   := xf_cfg_int('auth_window_minutes', 10);
  v_delay := xf_cfg_int('auth_delay_ms', 500) / 1000.0;

  select count(*) into v_fails from admin_auth_fails
   where ip = v_ip and created_at > now() - (v_win || ' minutes')::interval;
  if v_fails >= v_max then
    perform pg_sleep(v_delay * 2);
    return false;
  end if;

  select value into v_hash from app_config where key = 'admin_secret';
  if v_hash is null or coalesce(p_secret, '') = '' then
    return false;
  end if;

  v_ok := (crypt(p_secret, v_hash) = v_hash);

  if not v_ok then
    insert into admin_auth_fails (ip) values (v_ip);
    -- Constant-ish delay on failure: slows a wordlist, and stops the response
    -- time from revealing whether the password was close.
    perform pg_sleep(v_delay);
  else
    delete from admin_auth_fails
     where ip = v_ip and created_at > now() - (v_win || ' minutes')::interval;  -- WHERE: safeupdate
  end if;

  return v_ok;
end $$;

create or replace function xf_admin_check(p_secret text)
returns jsonb language sql security definer set search_path = public as $$
  select case when xf_admin_ok(p_secret)
              then jsonb_build_object('ok', true)
              else jsonb_build_object('ok', false, 'error', 'auth') end
$$;

create or replace function xf_admin_set_password(p_secret text, p_new text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if length(coalesce(p_new, '')) < 10 then
    return jsonb_build_object('ok', false, 'error', 'too_short');
  end if;
  update app_config set value = crypt(p_new, gen_salt('bf', 10)) where key = 'admin_secret';
  return jsonb_build_object('ok', true);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  READ-ONLY PANELS
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function xf_admin_stats(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  return jsonb_build_object(
    'ok', true,
    'participants', (select count(*) from participants),
    'tickets',      (select count(*) from draw_tickets),
    'prizes_total', (select coalesce(sum(qty), 0) from prizes),
    'drawn',        (select count(*) from winners),
    -- Where the pool came from. Worth showing: if most of it is self-declared
    -- taps rather than scans, that is a fact about your campaign you want on
    -- screen rather than discovered afterwards.
    'pool_by_source', coalesce((select jsonb_object_agg(source, n)
                                  from (select source, count(*) as n
                                          from draw_tickets group by source) s), '{}'::jsonb));
end $$;

create or replace function xf_admin_today(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_feed jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;

  -- The order/limit must live INSIDE the subquery. Putting it outside the
  -- aggregate is a 42803 waiting to happen and it will fire on every call.
  select coalesce(jsonb_agg(jsonb_build_object(
           'at', at, 'name', name, 'detail', detail, 'kind', kind)), '[]'::jsonb)
    into v_feed
    from (
      select to_char(ev.ts at time zone xf_tz(), 'HH24:MI') as at,
             ev.name, ev.detail, ev.kind, ev.ts
        from (
          select p.full_name as name, 'joined' as detail, 'join' as kind, p.created_at as ts
            from participants p
          union all
          select p.full_name, to_char(c.visit_date, 'DD Mon'), 'checkin', c.created_at
            from checkins c join participants p on p.id = c.participant_id
          union all
          select p.full_name, cl.platform, case when cl.platform = 'repost' then 'repost' else 'social' end, cl.created_at
            from claims cl join participants p on p.id = cl.participant_id
          union all
          select p.full_name, r.months || ' month(s)', 'renewal', r.updated_at
            from renewals r join participants p on p.id = r.participant_id
          union all
          select p.full_name, (case when a.delta > 0 then '+' else '' end) || a.delta || ' · ' || a.reason,
                 'adjust', a.created_at
            from ticket_adjustments a join participants p on p.id = a.participant_id
        ) ev
       order by ev.ts desc
       limit 14) f;

  return jsonb_build_object(
    'ok', true,
    'day', to_char(xf_today(), 'DD Mon YYYY'),
    'new_today',      (select count(*) from participants
                        where (created_at at time zone xf_tz())::date = xf_today()),
    'checkins_today', (select count(*) from checkins where visit_date = xf_today()),
    'reposts_done',   (select count(*) from claims where platform = 'repost' and status = 'approved'),
    'feed', v_feed);
end $$;

-- Does the pool faithfully represent what people actually hold?
-- `mismatch` counts people whose ticket total does not equal the number of
-- serials they own. The draw refuses to run while that is non-zero, because a
-- pool that is not a faithful copy produces a winner nobody can verify.
create or replace function xf_admin_ledger(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_err text := null; v_mis int;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  begin
    perform xf_issue_tickets();
  exception when others then v_err := sqlerrm;
  end;

  select count(*) into v_mis
    from participants p
    cross join lateral xf_ticket_counts(p.id) tc
   where not p.disqualified
     and tc.total <> (select count(*) from draw_tickets d where d.participant_id = p.id);

  return jsonb_build_object(
    'ok', true,
    'live',       (select count(*) from draw_tickets),
    'max_serial', (select coalesce(max(serial), 0) from draw_tickets),
    'issued_at',  to_char(now() at time zone xf_tz(), 'DD Mon HH24:MI'),
    'mismatch',   v_mis,
    'voided',     (select count(*) from draw_voids),
    'public',     coalesce(xf_cfg('ticket_numbers_public'), 'true') = 'true',
    'issuer_error', v_err);
end $$;

create or replace function xf_admin_participants(p_secret text, p_q text default '', p_limit int default 1000)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select coalesce(jsonb_agg(r order by r->>'name'), '[]'::jsonb) into v from (
    select jsonb_build_object(
      'id', p.id, 'name', p.full_name, 'ic_last4', p.ic_last4, 'phone', p.phone,
      'platform', p.platform, 'handle', p.handle, 'disqualified', p.disqualified,
      'joined', to_char(p.created_at at time zone xf_tz(), 'DD Mon'),
      'checkin', tc.checkin, 'renewal', tc.renewal, 'social', tc.social,
      'repost', tc.repost, 'adjust', tc.adjust, 'total', tc.total,
      'checkin_days', (select count(*) from checkins c where c.participant_id = p.id)) as r
      from participants p
      cross join lateral xf_ticket_counts(p.id) tc
     where coalesce(btrim(p_q), '') = ''
        or upper(p.full_name) like '%' || upper(btrim(p_q)) || '%'
        or p.phone like '%' || btrim(p_q) || '%'
        or p.ic_last4 = right(regexp_replace(btrim(p_q), '[^A-Za-z0-9]', '', 'g'), 4)
        or upper(p.handle) like '%' || upper(btrim(p_q)) || '%'
     limit greatest(1, least(coalesce(p_limit, 1000), 20000))) q;
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

create or replace function xf_admin_adjustments(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'participant_id', a.participant_id, 'name', p.full_name,
           'ic_last4', p.ic_last4, 'delta', a.delta, 'reason', a.reason,
           'at', to_char(a.created_at at time zone xf_tz(), 'DD Mon HH24:MI'))
           order by a.created_at desc), '[]'::jsonb)
    into v from ticket_adjustments a join participants p on p.id = a.participant_id;
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

create or replace function xf_admin_reposts(p_secret text, p_status text default 'all')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', cl.id, 'participant_id', cl.participant_id, 'name', p.full_name,
           'ic_last4', p.ic_last4, 'phone', p.phone, 'platform', p.platform,
           'handle', p.handle, 'status', cl.status,
           'submitted', to_char(cl.created_at at time zone xf_tz(), 'DD Mon HH24:MI'))
           order by cl.created_at desc), '[]'::jsonb)
    into v from claims cl join participants p on p.id = cl.participant_id
   where cl.platform = 'repost'
     and (coalesce(p_status, 'all') = 'all' or cl.status = p_status);
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

create or replace function xf_admin_socials(p_secret text, p_platforms text[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', cl.id, 'participant_id', cl.participant_id, 'name', p.full_name,
           'ic_last4', p.ic_last4, 'phone', p.phone, 'platform', cl.platform,
           'handle', cl.handle, 'status', cl.status,
           'submitted', to_char(cl.created_at at time zone xf_tz(), 'DD Mon HH24:MI'))
           order by cl.created_at desc), '[]'::jsonb)
    into v from claims cl join participants p on p.id = cl.participant_id
   where cl.platform <> 'repost'
     and (p_platforms is null or cl.platform = any(p_platforms));
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

create or replace function xf_admin_voids(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'seq', dv.seq, 'tier', dv.tier, 'prize', pz.name, 'name', p.full_name,
           'ic_last4', p.ic_last4, 'tickets', dv.tickets_held, 'reason', dv.reason,
           'at', to_char(dv.created_at at time zone xf_tz(), 'DD Mon HH24:MI'))
           order by dv.created_at desc), '[]'::jsonb)
    into v from draw_voids dv
      join participants p on p.id = dv.participant_id
      left join prizes pz on pz.tier = dv.tier;
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

create or replace function xf_admin_winners(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'tier', w.tier, 'seq', w.seq, 'qty', pz.qty,
           'prize', pz.name, 'subtitle', pz.subtitle,
           'participant_id', w.participant_id, 'name', p.full_name,
           'ic_last4', p.ic_last4, 'phone', p.phone,
           'platform', p.platform, 'handle', p.handle,
           'tickets', w.tickets_held, 'serial', w.serial,
           'source', dt.source, 'detail', dt.detail,
           'earned_at', to_char(dt.earned_at at time zone xf_tz(), 'DD Mon HH24:MI'),
           'claimed', w.claimed,
           'claimed_at', to_char(w.claimed_at at time zone xf_tz(), 'DD Mon HH24:MI'),
           'drawn_at', to_char(w.drawn_at at time zone xf_tz(), 'DD Mon HH24:MI'))
           order by w.tier, w.seq), '[]'::jsonb)
    into v from winners w
      join participants p on p.id = w.participant_id
      join prizes pz on pz.tier = w.tier
      left join draw_tickets dt on dt.serial = w.serial;
  return jsonb_build_object('ok', true, 'rows', v,
    'poster', jsonb_build_object('instagram', coalesce(xf_cfg('poster_instagram'), ''),
                                 'facebook',  coalesce(xf_cfg('poster_facebook'), '')));
end $$;

-- What the pool would look like under a different set of ticket values.
-- Lets you see the effect of a change before committing to it.
create or replace function xf_admin_projection(
  p_secret text, p_checkin_pts int default null, p_checkin_max int default null,
  p_social_pts int default null, p_repost_pts int default null,
  p_renewal_pts int default null, p_renewal_max int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cur bigint; v_max bigint; v_gym bigint; v_loy bigint; v_nov bigint; v_np int;
        cp int; cm int; sp int; rp int; np int; nm int;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  cp := coalesce(p_checkin_pts, xf_cfg_int('checkin_pts_per_day', 3));
  cm := coalesce(p_checkin_max, xf_cfg_int('checkin_max_days', 7));
  sp := coalesce(p_social_pts,  xf_cfg_int('social_points', 3));
  rp := coalesce(p_repost_pts,  xf_cfg_int('repost_points', 6));
  np := coalesce(p_renewal_pts, xf_cfg_int('renewal_pts_per_month', 1));
  nm := coalesce(p_renewal_max, xf_cfg_int('renewal_max_months', 0));

  select count(*) into v_cur from draw_tickets;
  select count(*) * cm * cp into v_gym from participants where not disqualified;
  select coalesce(sum(case when nm > 0 then least(months, nm) else months end), 0) * np
    into v_loy from renewals;
  -- The ceiling for someone who never sets foot in the shop: every social
  -- platform plus the repost. Worth knowing before you publish the rules.
  v_np := 5 * sp + rp;
  select count(*) * v_np into v_nov from participants where not disqualified;
  v_max := v_gym + v_loy + v_nov;

  return jsonb_build_object('ok', true,
    'current', v_cur, 'max_possible', v_max,
    'gym_only', v_gym, 'loyal_renewal', v_loy,
    'no_visit_possible', v_np,
    'no_visit_share', case when v_max > 0 then round(100.0 * v_nov / v_max) else 0 end);
end $$;

-- Answers "do any of these hashes belong to someone?" and nothing else.
-- The console hashes IDs in the BROWSER and sends only digests, so plaintext
-- never reaches the server and no digest is ever sent back down.
create or replace function xf_admin_match_ic(p_secret text, p_hashes text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if p_hashes is null or array_length(p_hashes, 1) is null then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  end if;
  if array_length(p_hashes, 1) > 30000 then
    return jsonb_build_object('ok', false, 'error', 'too_many');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'ic', p.ic_hash, 'name', p.full_name,
           'months', coalesce(r.months, 0))), '[]'::jsonb)
    into v from participants p
      left join renewals r on r.participant_id = p.id
     where p.ic_hash = any(p_hashes);
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  WRITES
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function xf_admin_checkin_id(p_secret text, p_id bigint, p_on date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_day date; v_dup boolean := false; v_before int; v_after int; p participants%rowtype;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select * into p from participants where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if p.disqualified then return jsonb_build_object('ok', false, 'error', 'disqualified'); end if;
  if xf_pool_locked() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;

  v_day := coalesce(p_on, xf_today());
  select total into v_before from xf_ticket_counts(p_id);

  insert into checkins (participant_id, visit_date, source) values (p_id, v_day, 'staff')
  on conflict (participant_id, visit_date) do nothing;
  if not found then v_dup := true; end if;

  perform xf_issue_tickets();
  select total into v_after from xf_ticket_counts(p_id);

  return jsonb_build_object('ok', true, 'duplicate', v_dup,
    'name', p.full_name, 'ic_last4', p.ic_last4,
    'points_added', v_after - v_before, 'total', v_after,
    'eligible', true,
    'tiers', (select count(*) from checkins where participant_id = p_id));
end $$;

create or replace function xf_admin_checkin_scan(p_secret text, p_qr text, p_on date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; v jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  begin
    select id into v_id from participants
     where qr_token = replace(coalesce(p_qr, ''), 'LD1:', '')::uuid;
  exception when others then v_id := null;   -- not a UUID at all
  end;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'bad_code'); end if;
  v := xf_admin_checkin_id(p_secret, v_id, p_on);
  return v || jsonb_build_object('prize',
    (select jsonb_build_object('tier', w.tier, 'name', pz.name, 'claimed', w.claimed)
       from winners w join prizes pz on pz.tier = w.tier where w.participant_id = v_id));
end $$;

create or replace function xf_admin_verify_scan(p_secret text, p_qr text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p participants%rowtype; t record;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  begin
    select * into p from participants
     where qr_token = replace(coalesce(p_qr, ''), 'LD1:', '')::uuid;
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_code');
  end;
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'bad_code'); end if;
  select * into t from xf_ticket_counts(p.id);
  return jsonb_build_object('ok', true, 'name', p.full_name, 'ic_last4', p.ic_last4,
    'phone', p.phone, 'total', t.total, 'disqualified', p.disqualified,
    'prize', (select jsonb_build_object('tier', w.tier, 'name', pz.name,
                       'subtitle', pz.subtitle, 'seq', w.seq, 'claimed', w.claimed)
                from winners w join prizes pz on pz.tier = w.tier
               where w.participant_id = p.id));
end $$;

create or replace function xf_admin_disqualify(p_secret text, p_id bigint, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 4 then
    return jsonb_build_object('ok', false, 'error', 'reason_required');
  end if;
  update participants set disqualified = true, dq_reason = btrim(p_reason) where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  perform xf_issue_tickets();
  return jsonb_build_object('ok', true, 'rows', 1);
end $$;

create or replace function xf_admin_adjust_tickets(
  p_secret text, p_participant_id bigint, p_delta int, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_before int; v_after int;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if p_delta is null or p_delta = 0 or p_delta < -60 or p_delta > 60 then
    return jsonb_build_object('ok', false, 'error', 'bad_delta');
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 4 then
    return jsonb_build_object('ok', false, 'error', 'reason_required');
  end if;
  if xf_pool_locked() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;

  select total into v_before from xf_ticket_counts(p_participant_id);
  if v_before is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_before + p_delta < 0 then
    return jsonb_build_object('ok', false, 'error', 'would_go_negative',
      'would_be', v_before + p_delta, 'ceiling', v_before);
  end if;

  insert into ticket_adjustments (participant_id, delta, reason)
  values (p_participant_id, p_delta, btrim(p_reason));

  perform xf_issue_tickets();
  select total into v_after from xf_ticket_counts(p_participant_id);
  return jsonb_build_object('ok', true, 'new_total', v_after, 'rows', 1);
end $$;

create or replace function xf_admin_edit_participant(
  p_secret text, p_id bigint, p_name text default null, p_phone text default null,
  p_platform text default null, p_handle text default null, p_ic text default null,
  p_reason text default null, p_password text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p participants%rowtype; v_fields jsonb := '{}'::jsonb;
        v_hash text; v_taken bigint; v_icch boolean := false;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select * into p from participants where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  -- Changing an identity document is the one edit that can silently merge or
  -- orphan a record, so it needs the password typed again.
  if coalesce(btrim(p_ic), '') <> '' then
    if not xf_admin_ok(coalesce(p_password, '')) then
      return jsonb_build_object('ok', false, 'error', 'password_required');
    end if;
    v_hash := xf_hash_ic(p_ic);
    if v_hash <> p.ic_hash then
      select id into v_taken from participants where ic_hash = v_hash and id <> p_id;
      if v_taken is not null then
        return jsonb_build_object('ok', false, 'error', 'ic_taken', 'taken_by', v_taken);
      end if;
      update participants
         set ic_hash = v_hash, ic_last4 = right(xf_norm_ic(p_ic), 4)
       where id = p_id;
      v_icch := true;
      v_fields := v_fields || jsonb_build_object('ic_last4', right(xf_norm_ic(p_ic), 4));
    end if;
  end if;

  if p_name is not null and btrim(p_name) <> '' and btrim(p_name) <> p.full_name then
    update participants set full_name = btrim(p_name) where id = p_id;
    v_fields := v_fields || jsonb_build_object('name', btrim(p_name));
  end if;
  if p_phone is not null and btrim(p_phone) <> '' and btrim(p_phone) <> p.phone then
    update participants set phone = btrim(p_phone) where id = p_id;
    v_fields := v_fields || jsonb_build_object('phone', btrim(p_phone));
  end if;
  if p_platform is not null and lower(p_platform) in ('instagram','facebook')
     and lower(p_platform) <> p.platform then
    update participants set platform = lower(p_platform) where id = p_id;
    v_fields := v_fields || jsonb_build_object('platform', lower(p_platform));
  end if;
  if p_handle is not null and btrim(p_handle) <> p.handle then
    update participants set handle = btrim(p_handle) where id = p_id;
    v_fields := v_fields || jsonb_build_object('handle', btrim(p_handle));
  end if;

  if v_fields = '{}'::jsonb then
    return jsonb_build_object('ok', true, 'unchanged', true);
  end if;

  insert into participant_edits (participant_id, fields)
  values (p_id, v_fields || jsonb_build_object('reason', coalesce(p_reason, '')));

  select * into p from participants where id = p_id;
  return jsonb_build_object('ok', true, 'fields', v_fields, 'ic_changed', v_icch,
                            'ic_last4', p.ic_last4, 'name', p.full_name);
end $$;

create or replace function xf_admin_delete_participant(
  p_secret text, p_id bigint, p_reason text default null, p_password text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p participants%rowtype; v_t int; v_new bigint;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if not xf_admin_ok(coalesce(p_password, '')) then
    return jsonb_build_object('ok', false, 'error', 'password_required');
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 4 then
    return jsonb_build_object('ok', false, 'error', 'reason_required');
  end if;
  select * into p from participants where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if exists (select 1 from winners where participant_id = p_id) then
    return jsonb_build_object('ok', false, 'error', 'is_a_winner');
  end if;

  select total into v_t from xf_ticket_counts(p_id);
  insert into deleted_participants (ic_hash, ic_last4, full_name, phone, tickets_held)
  values (p.ic_hash, p.ic_last4, p.full_name, p.phone, coalesce(v_t, 0));

  delete from participants where id = p_id;
  perform xf_issue_tickets();
  select count(*) into v_new from draw_tickets;
  return jsonb_build_object('ok', true, 'name', p.full_name,
                            'tickets', coalesce(v_t, 0), 'new_total', v_new);
end $$;

create or replace function xf_admin_mark_claimed(
  p_secret text, p_participant_id bigint, p_undo boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  update winners
     set claimed = not coalesce(p_undo, false),
         claimed_at = case when coalesce(p_undo, false) then null else now() end
   where participant_id = p_participant_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_a_winner'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function xf_admin_review_repost(p_secret text, p_id bigint, p_approve boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  update claims set status = case when p_approve then 'approved' else 'rejected' end
   where id = p_id and platform = 'repost';
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  perform xf_issue_tickets();
  return jsonb_build_object('ok', true);
end $$;

create or replace function xf_admin_set_points(
  p_secret text, p_checkin_pts int, p_checkin_max int, p_social_pts int,
  p_repost_pts int, p_renewal_pts int, p_renewal_max int)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if p_checkin_pts < 0 or p_checkin_max < 1 or p_social_pts < 0
     or p_repost_pts < 0 or p_renewal_pts < 0 or p_renewal_max < 0 then
    return jsonb_build_object('ok', false, 'error', 'bad_values');
  end if;
  if xf_pool_locked() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;

  insert into app_config (key, value) values
    ('checkin_pts_per_day',   p_checkin_pts::text),
    ('checkin_max_days',      p_checkin_max::text),
    ('social_points',         p_social_pts::text),
    ('repost_points',         p_repost_pts::text),
    ('renewal_pts_per_month', p_renewal_pts::text),
    ('renewal_max_months',    p_renewal_max::text)
  on conflict (key) do update set value = excluded.value;

  perform xf_issue_tickets();
  return jsonb_build_object('ok', true, 'rows', (select count(*) from draw_tickets));
end $$;

create or replace function xf_admin_set_poster(
  p_secret text, p_instagram text default '', p_facebook text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  insert into app_config (key, value) values
    ('poster_instagram', coalesce(btrim(p_instagram), '')),
    ('poster_facebook',  coalesce(btrim(p_facebook), ''))
  on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('ok', true,
    'instagram', coalesce(btrim(p_instagram), ''),
    'facebook',  coalesce(btrim(p_facebook), ''));
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  CSV IMPORTS
--  p_rows is a JSON array. Months REPLACE, never accumulate: every file must
--  carry the cumulative total per person. That single rule is what makes
--  re-importing yesterday's export a no-op instead of a disaster.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function xf_admin_import_renewals(
  p_secret text, p_rows jsonb, p_allow_decrease boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; v_hash text; v_id bigint; v_m int; v_cur int;
        n_saved int := 0; n_missing int := 0; n_bad int := 0; n_blocked int := 0;
        v_blocked jsonb := '[]'::jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if xf_pool_locked() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    begin v_m := (r->>'months')::int; exception when others then v_m := null; end;
    if v_m is null or v_m < 0 then n_bad := n_bad + 1; continue; end if;

    v_hash := xf_hash_ic(r->>'ic');
    select id into v_id from participants where ic_hash = v_hash;
    if not found then n_missing := n_missing + 1; continue; end if;

    select months into v_cur from renewals where participant_id = v_id;
    if v_cur is not null and v_m < v_cur and not coalesce(p_allow_decrease, false) then
      n_blocked := n_blocked + 1;
      v_blocked := v_blocked || jsonb_build_object(
        'name', (select full_name from participants where id = v_id),
        'was', v_cur, 'file_says', v_m);
      continue;
    end if;

    insert into renewals (participant_id, months, updated_at)
    values (v_id, v_m, now())
    on conflict (participant_id) do update
      set months = excluded.months, updated_at = excluded.updated_at;
    n_saved := n_saved + 1;
  end loop;

  perform xf_issue_tickets();
  return jsonb_build_object('ok', true, 'saved', n_saved,
    'not_registered', n_missing, 'bad_value', n_bad,
    'blocked_decrease', n_blocked, 'blocked', v_blocked,
    'waiting', (select count(*) from participants p
                 left join renewals rn on rn.participant_id = p.id
                where rn.participant_id is null));
end $$;

create or replace function xf_admin_import_checkins(p_secret text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; v_id bigint; v_d date;
        n_ins int := 0; n_dup int := 0; n_missing int := 0; n_bad int := 0;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if xf_pool_locked() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    begin v_d := (r->>'date')::date; exception when others then v_d := null; end;
    if v_d is null then n_bad := n_bad + 1; continue; end if;

    select id into v_id from participants where ic_hash = xf_hash_ic(r->>'ic');
    if not found then n_missing := n_missing + 1; continue; end if;

    insert into checkins (participant_id, visit_date, source)
    values (v_id, v_d, 'import')
    on conflict (participant_id, visit_date) do nothing;
    if found then n_ins := n_ins + 1; else n_dup := n_dup + 1; end if;
  end loop;

  perform xf_issue_tickets();
  return jsonb_build_object('ok', true, 'inserted', n_ins, 'duplicate', n_dup,
    'not_registered', n_missing, 'bad_date', n_bad,
    'blocked', 0, 'blocked_decrease', 0, 'missed', n_missing);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  THE DRAW
--
--  A uniform random pick from draw_tickets. NOT a weighted pick over people —
--  the two are mathematically identical, but picking a ticket means the
--  winning number is a real object you can show the room.
--
--  There is no override and no way to steer the result. That is not an
--  oversight. If someone can choose the winner, nothing else here means
--  anything, so please do not add one when you fork this.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function xf_draw_state(p_secret text, p_rehearsal boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb; v_elig bigint;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'tier', pz.tier, 'name', pz.name, 'subtitle', pz.subtitle,
           'qty', pz.qty, 'draw_seq', pz.draw_seq, 'drawn', d.n,
           'is_drawn', d.n >= pz.qty) order by pz.draw_seq), '[]'::jsonb)
    into v
    from prizes pz
    cross join lateral (
      select count(*)::int as n from (
        select tier from winners where not p_rehearsal
        union all
        select tier from rehearsal_winners where p_rehearsal) w
       where w.tier = pz.tier) d;

  select count(distinct dt.participant_id) into v_elig
    from draw_tickets dt join participants p on p.id = dt.participant_id
   where not p.disqualified
     and not exists (select 1 from draw_voids v where v.participant_id = dt.participant_id)
     and not exists (select 1 from winners w where w.participant_id = dt.participant_id and not p_rehearsal)
     and not exists (select 1 from rehearsal_winners w where w.participant_id = dt.participant_id and p_rehearsal);

  return jsonb_build_object('ok', true, 'tiers', v, 'eligible', coalesce(v_elig, 0));
end $$;

create or replace function xf_admin_draw_state(p_secret text)
returns jsonb language sql security definer set search_path = public as $$
  select xf_draw_state(p_secret, false) $$;

create or replace function xf_admin_rehearse_state(p_secret text)
returns jsonb language sql security definer set search_path = public as $$
  select xf_draw_state(p_secret, true) $$;

create or replace function xf_draw_pick(p_secret text, p_rehearsal boolean, p_tier int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_tier int; v_qty int; v_drawn int; v_seq int; v_mis int;
        v_serial bigint; v_pid bigint; p participants%rowtype; t record; dt draw_tickets%rowtype;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;

  -- The pool must be a faithful copy before anything is picked from it.
  select count(*) into v_mis
    from participants pp
    cross join lateral xf_ticket_counts(pp.id) tc
   where not pp.disqualified
     and tc.total <> (select count(*) from draw_tickets d where d.participant_id = pp.id);
  if v_mis > 0 then
    return jsonb_build_object('ok', false, 'error', 'ledger_stale', 'mismatch', v_mis);
  end if;

  if p_tier is not null then
    v_tier := p_tier;
  else
    select pz.tier into v_tier from prizes pz
     where (select count(*) from (select tier from winners where not p_rehearsal
                                  union all
                                  select tier from rehearsal_winners where p_rehearsal) w
             where w.tier = pz.tier) < pz.qty
     order by pz.draw_seq limit 1;
  end if;
  if v_tier is null then return jsonb_build_object('ok', true, 'done', true); end if;

  select qty into v_qty from prizes where tier = v_tier;
  select count(*) into v_drawn from (select tier from winners where not p_rehearsal
                                     union all
                                     select tier from rehearsal_winners where p_rehearsal) w
   where w.tier = v_tier;
  v_seq := v_drawn + 1;

  -- Uniform over TICKETS. A person holding ten tickets is ten rows here, so
  -- their chance scales with what they earned, without any weighting code.
  select dt2.serial, dt2.participant_id into v_serial, v_pid
    from draw_tickets dt2
    join participants pp on pp.id = dt2.participant_id
   where not pp.disqualified
     and not exists (select 1 from draw_voids v where v.participant_id = dt2.participant_id)
     and not exists (select 1 from winners w where w.participant_id = dt2.participant_id and not p_rehearsal)
     and not exists (select 1 from rehearsal_winners w where w.participant_id = dt2.participant_id and p_rehearsal)
   order by random() limit 1;

  if v_pid is null then
    return jsonb_build_object('ok', true, 'exhausted', true,
      'tier', v_tier, 'seq', v_drawn, 'qty', v_qty);
  end if;

  select * into p from participants where id = v_pid;
  select * into t from xf_ticket_counts(v_pid);
  select * into dt from draw_tickets where serial = v_serial;

  if p_rehearsal then
    insert into rehearsal_winners (tier, seq, participant_id, serial, tickets_held)
    values (v_tier, v_seq, v_pid, v_serial, t.total);
  else
    insert into winners (tier, seq, participant_id, serial, tickets_held)
    values (v_tier, v_seq, v_pid, v_serial, t.total);
  end if;

  return jsonb_build_object('ok', true, 'tier', v_tier, 'seq', v_seq, 'qty', v_qty,
    'tier_complete', v_seq >= v_qty,
    'winner', jsonb_build_object('name', p.full_name, 'ic_last4', p.ic_last4,
                'phone', p.phone, 'platform', p.platform, 'handle', p.handle,
                'tickets', t.total),
    'ticket', jsonb_build_object('serial', dt.serial, 'source', dt.source, 'detail', dt.detail));
end $$;

create or replace function xf_admin_draw_next(p_secret text)
returns jsonb language sql security definer set search_path = public as $$
  select xf_draw_pick(p_secret, false, null) $$;

create or replace function xf_admin_rehearse_next(p_secret text)
returns jsonb language sql security definer set search_path = public as $$
  select xf_draw_pick(p_secret, true, null) $$;

-- Forfeit a winner and immediately draw a replacement for the SAME slot.
-- The forfeited person is archived with a written reason and excluded from
-- every future pick.
create or replace function xf_admin_redraw(p_secret text, p_participant_id bigint, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare w winners%rowtype; v_name text; v_new jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 4 then
    return jsonb_build_object('ok', false, 'error', 'reason_required');
  end if;
  select * into w from winners where participant_id = p_participant_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_a_winner'); end if;
  select full_name into v_name from participants where id = p_participant_id;

  insert into draw_voids (tier, seq, participant_id, serial, tickets_held, reason)
  values (w.tier, w.seq, w.participant_id, w.serial, w.tickets_held, btrim(p_reason));

  delete from winners where participant_id = p_participant_id;

  v_new := xf_draw_pick(p_secret, false, w.tier);
  if (v_new->>'ok')::boolean is not true then return v_new; end if;

  return v_new || jsonb_build_object('voided', v_name,
    'tier_name', (select name from prizes where tier = w.tier));
end $$;

create or replace function xf_admin_reset_draw(p_secret text, p_confirm text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  if coalesce(p_confirm, '') <> 'RESET' then
    return jsonb_build_object('ok', false, 'error', 'confirm_required');
  end if;
  select count(*) into n from winners;
  delete from winners where true;      -- WHERE required: safeupdate
  delete from draw_voids where true;
  return jsonb_build_object('ok', true, 'cleared', n);
end $$;

create or replace function xf_admin_rehearse_reset(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select count(*) into n from rehearsal_winners;
  delete from rehearsal_winners where true;   -- WHERE required: safeupdate
  return jsonb_build_object('ok', true, 'cleared', n);
end $$;

create or replace function xf_rehearsal_results(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb; vt jsonb;
begin
  if not xf_admin_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'auth'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'tier', rw.tier, 'seq', rw.seq, 'prize', pz.name, 'subtitle', pz.subtitle,
           'qty', pz.qty, 'participant_id', rw.participant_id, 'name', p.full_name,
           'ic_last4', p.ic_last4, 'phone', p.phone, 'platform', p.platform,
           'handle', p.handle, 'tickets', rw.tickets_held, 'serial', rw.serial,
           'drawn_at', to_char(rw.drawn_at at time zone xf_tz(), 'DD Mon HH24:MI'))
           order by rw.tier, rw.seq), '[]'::jsonb)
    into v from rehearsal_winners rw
      join participants p on p.id = rw.participant_id
      join prizes pz on pz.tier = rw.tier;
  select coalesce(jsonb_agg(jsonb_build_object(
           'tier', pz.tier, 'name', pz.name, 'qty', pz.qty,
           'winners', (select count(*) from rehearsal_winners r where r.tier = pz.tier))
           order by pz.draw_seq), '[]'::jsonb)
    into vt from prizes pz;
  return jsonb_build_object('ok', true, 'rows', v, 'tiers', vt);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  GRANTS
--  Every admin function is reachable by anon — and gated by the password
--  check inside it. That is the intended design for a static console: the
--  endpoint is public, the data is not.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'xf_admin_%' or p.proname = 'xf_rehearsal_results')
  loop
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;

-- Internal helpers stay ungranted: xf_draw_pick and xf_draw_state are only
-- reachable through their xf_admin_* wrappers, which check the password.
revoke all on function xf_draw_pick(text, boolean, int) from public, anon, authenticated;
revoke all on function xf_draw_state(text, boolean)     from public, anon, authenticated;
revoke all on function xf_admin_ok(text)                from public, anon, authenticated;
revoke all on function xf_issue_tickets()               from public, anon, authenticated;
revoke all on function xf_me_payload(bigint)            from public, anon, authenticated;
revoke all on function xf_ticket_counts(bigint)         from public, anon, authenticated;
revoke all on function xf_cfg(text, text)               from public, anon, authenticated;
revoke all on function xf_cfg_int(text, integer)        from public, anon, authenticated;

notify pgrst, 'reload schema';
