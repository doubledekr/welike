-- Plans never place somewhere that might be closed, and an open or closed spot becomes "This or That" (Dave, 19 Nov).
alter table public.plans add column if not exists told_at timestamptz;
update public.plans set told_at = created_at where auto is not null and told_at is null;

-- 1. The planner only uses a place whose opening hours are known (weekly hours, or open around the clock).
do $d$ declare s text := pg_get_functiondef('public._ap_pick(uuid,text,date,text,integer,uuid[],double precision,double precision,double precision,double precision,jsonb,boolean,text)'::regprocedure);
  a text := 'or _open_ok(c.data->''hours'', p_day, p_time, p_stay))';
begin
  if position('jsonb_typeof(c.data->''hours'') in' in s) = 0 then
    if position(a in s) = 0 then raise exception 'anchor missing in _ap_pick'; end if;
    execute replace(s, a, 'or (jsonb_typeof(c.data->''hours'') in (''array'', ''string'') and _open_ok(c.data->''hours'', p_day, p_time, p_stay)))');
  end if;
end $d$;

-- 2. Two good options for one spot of a plan, near the rest of it and open at that time.
create or replace function public._plan_pair(p_plan uuid, p_slot text, p_skip uuid[] default '{}')
returns uuid[] language plpgsql security definer set search_path to 'public' as $f$
declare pl plans; st jsonb; it jsonb; k text; t text; stay int; used uuid[]; la double precision; ln double precision; rad double precision; a record; b record; res uuid[] := '{}';
begin
  select * into pl from plans where id = p_plan; if pl.id is null then return res; end if;
  select settings into st from couples where id = pl.couple_id;
  select x into it from jsonb_array_elements(pl.items) x where x->>'slot' = p_slot limit 1;
  if it is null then return res; end if;
  k := case when p_slot like 'drinks%' then 'bar' when p_slot = 'dinner' then case when pl.mode = 'in' then 'dinner_in' else 'dinner' end
            when p_slot = 'day' then 'day' when p_slot = 'evening' and pl.mode <> 'in' then 'bar' end;
  if k is null then return res; end if;   -- movies keep their swipe round
  t := coalesce(nullif(it->>'time', ''), case p_slot when 'day' then '13:00' when 'dinner' then '19:30' else '17:00' end);
  stay := case p_slot when 'day' then 120 when 'dinner' then 90 else 60 end;
  used := coalesce(p_skip, '{}') || array(select (x->>'card')::uuid from jsonb_array_elements(pl.items) x where jsonb_typeof(x->'card') = 'string')
          || array(select (v #>> '{}')::uuid from jsonb_array_elements(coalesce(pl.closed, '[]'::jsonb)) v);
  -- the nearest other stop in time that is going ahead, so both options sit close to the rest of the plan
  select (c.data->>'lat')::double precision, (c.data->>'lng')::double precision into la, ln
    from jsonb_array_elements(pl.items) x join cards c on c.id::text = x->>'card'
    where x->>'slot' <> p_slot and c.data ? 'lat' and not (coalesce(pl.closed, '[]'::jsonb) ? c.id::text)
    order by abs(extract(epoch from (coalesce(nullif(x->>'time', ''), t)::time - t::time))) limit 1;
  rad := greatest(coalesce((st->>'radius_mi')::double precision, 2), 3);
  select * into a from _ap_pick(pl.couple_id, k, pl.day, t, stay, used, la, ln, case when la is null then rad else 1.5 end, rad, st, false);
  if a.card is null and la is not null then select * into a from _ap_pick(pl.couple_id, k, pl.day, t, stay, used, la, ln, 3, rad, st, false); end if;
  if a.card is null then return res; end if;
  res := array[a.card];
  select * into b from _ap_pick(pl.couple_id, k, pl.day, t, stay, used || a.card, la, ln, case when la is null then rad else 1.5 end, rad, st, false);
  if b.card is null and la is not null then select * into b from _ap_pick(pl.couple_id, k, pl.day, t, stay, used || a.card, la, ln, 3, rad, st, false); end if;
  if b.card is not null then res := res || b.card; end if;
  return res;
end $f$;
revoke all on function public._plan_pair(uuid, text, uuid[]) from public, anon, authenticated;

-- 3. Before a plan is announced: a closed stop is swapped (two options become This or That, one option goes straight in,
--    none and the stop is dropped), and an open spot on an automatic plan becomes This or That when there are two options.
create or replace function public._plan_fix(p_plan uuid) returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare pl plans; x jsonb; o bigint; pr uuid[]; v_items jsonb := '[]'::jsonb; taken uuid[] := '{}'; fixed int := 0; paired int := 0; dropped int := 0; cl jsonb; shut boolean;
begin
  select * into pl from plans where id = p_plan for update;
  if pl.id is null or pl.status not in ('sent', 'agreed') then return null; end if;
  cl := coalesce(pl.closed, '[]'::jsonb);
  for x, o in select e.x, e.o from jsonb_array_elements(pl.items) with ordinality e(x, o) loop
    shut := jsonb_typeof(x->'card') = 'string' and cl ? (x->>'card');
    if shut or (pl.auto is not null and jsonb_typeof(x->'card') <> 'string' and coalesce((x->>'find')::boolean, false)) then
      pr := _plan_pair(p_plan, x->>'slot', taken);
      if coalesce(array_length(pr, 1), 0) = 2 then
        v_items := v_items || jsonb_build_array(jsonb_build_object('slot', x->>'slot', 'time', x->>'time', 'card', null, 'find', false, 'why', null, 'pair', to_jsonb(pr::text[])));
        taken := taken || pr; paired := paired + 1;
        delete from sessions s where s.couple_id = pl.couple_id and s.filters->>'plan' = p_plan::text and s.filters->>'slot' = x->>'slot'
          and not exists (select 1 from swipes w where w.session_id = s.id);
      elsif shut and coalesce(array_length(pr, 1), 0) = 1 then
        v_items := v_items || jsonb_build_array(x || jsonb_build_object('card', pr[1], 'find', false, 'why', null));
        taken := taken || pr; fixed := fixed + 1;
      elsif shut then
        dropped := dropped + 1;
      else
        v_items := v_items || jsonb_build_array(x);
      end if;
    else
      v_items := v_items || jsonb_build_array(x);
    end if;
  end loop;
  if not exists (select 1 from jsonb_array_elements(v_items) y where jsonb_typeof(y->'card') = 'string' or y ? 'pair') then return jsonb_build_object('skipped', true); end if;
  update plans set items = v_items, updated_at = now(),
    closed = (select coalesce(jsonb_agg(v), '[]'::jsonb) from jsonb_array_elements(cl) v where exists (select 1 from jsonb_array_elements(v_items) y where y->>'card' = v #>> '{}'))
    where id = p_plan;
  return jsonb_build_object('fixed', fixed, 'paired', paired, 'dropped', dropped);
end $f$;
revoke all on function public._plan_fix(uuid) from public, anon, authenticated;

-- 4. Names in notifications: a This or That spot reads "Stadt Garten or Side Hustle Lounge".
create or replace function public._plan_names(p_items jsonb) returns text language sql stable security definer set search_path to 'public' as $f$
  select string_agg(case when jsonb_typeof(x->'card') = 'string' then (select split_part(c.title, ',', 1) from cards c where c.id = (x->>'card')::uuid)
    when jsonb_array_length(coalesce(x->'pair', '[]'::jsonb)) = 2 then (select split_part(c.title, ',', 1) from cards c where c.id = (x->'pair'->>0)::uuid) || ' or ' || (select split_part(c.title, ',', 1) from cards c where c.id = (x->'pair'->>1)::uuid)
    else case x->>'slot' when 'evening' then 'a movie you pick together' when 'dinner' then 'dinner you pick together' when 'day' then 'something you pick together' else 'a bar you pick together' end end, ', then ' order by ord)
  from jsonb_array_elements(p_items) with ordinality e(x, ord)
$f$;

-- 5. The plan carries the two options for a This or That spot.
do $d$ declare s text := pg_get_functiondef('public._plan_json(plans)'::regprocedure);
  a text := '''why'', x->>''why'', ''session'',';
begin
  if position('''pair''' in s) = 0 then
    if position(a in s) = 0 then raise exception 'anchor missing in _plan_json'; end if;
    execute replace(s, a, '''why'', x->>''why'', ''pair'', case when jsonb_typeof(x->''card'') <> ''string'' and jsonb_array_length(coalesce(x->''pair'', ''[]''::jsonb)) = 2 then (select jsonb_agg(_card_json(c2) order by (x->''pair''->>0) = c2.id::text desc) from cards c2 where c2.id::text in (select jsonb_array_elements_text(x->''pair''))) end, ''session'',');
  end if;
end $d$;

-- 6. An automatic plan stays out of sight until it has been checked and announced.
do $d$ declare s text := pg_get_functiondef('public.plan_list(text)'::regprocedure);
  a text := 'where p.couple_id = v and p.status <> ''dropped'' and';
begin
  if position('told_at' in s) = 0 then
    if position(a in s) = 0 then raise exception 'anchor missing in plan_list'; end if;
    execute replace(s, a, 'where p.couple_id = v and p.status <> ''dropped'' and (p.auto is null or p.told_at is not null) and');
  end if;
end $d$;

-- 7. Weekend plans: drafted an hour early and checked against real hours for that date, then fixed and announced.
create or replace function public._plan_tick()
 returns integer language plpgsql security definer set search_path to 'public' as $function$
declare r record; w record; m2 record; n int := 0; lt timestamp; h int; dw int; pid uuid; bk text;
  u text := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/nudge'; hd jsonb := jsonb_build_object('Content-Type', 'application/json');
  chk text := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/placeinfo'; hk jsonb;
begin
  hk := hd || jsonb_build_object('x-sync-key', (select value from app_secrets where key = 'sync_key'));
  for r in select cp.id couple_id, cp.code, cp.settings st, _zip_tz(cp.settings->>'zip') tz, (select count(*) from members m where m.couple_id = cp.id) k from couples cp
           where exists (select 1 from members m where m.couple_id = cp.id) loop
    lt := now() at time zone r.tz; h := extract(hour from lt); dw := extract(isodow from lt);

    -- ===== Weekend plans (solo couples too). Sunday is left alone. =====
    if coalesce(r.st->>'plans_off', '') <> 'true' then
      -- Wednesday 4pm: draft Saturday's plan out of sight, and check every stop's real hours for that date.
      if dw = 3 and h = 16 and not exists (select 1 from plans p where p.couple_id = r.couple_id and p.day = lt::date + 3) then
        begin pid := _auto_plan(r.couple_id, 'sat', lt::date + 3); exception when others then pid := null; end;
        if pid is not null then
          perform net.http_post(url := chk, timeout_milliseconds := 60000, headers := hk, body := jsonb_build_object('plan', pid));
          n := n + 1;
        end if;
      end if;
      -- Wednesday 5pm: anything closed is swapped, open spots become This or That, then both people hear about it.
      if dw = 3 and h = 17 then
        if not exists (select 1 from plans p where p.couple_id = r.couple_id and p.day = lt::date + 3) then
          begin pid := _auto_plan(r.couple_id, 'sat', lt::date + 3); exception when others then pid := null; end;
        end if;
        for pid in select p.id from plans p where p.couple_id = r.couple_id and p.day = lt::date + 3 and p.auto = 'sat' and p.status = 'sent' and p.told_at is null loop
          begin perform _plan_fix(pid); exception when others then null; end;
          select _plan_names(p.items), (select string_agg(split_part(c.title, ',', 1), ' and ') from cards c where c.id::text in (select jsonb_array_elements_text(p.bookable))) into w from plans p where p.id = pid;
          perform net.http_post(url := u, timeout_milliseconds := 30000, headers := hd, body := jsonb_build_object('code', r.code, 'member', '-', 'kind', 'plan',
            'title', 'Saturday’s plan is ready',
            'body', left(w._plan_names || case when w.string_agg is not null then '. Book ahead: ' || w.string_agg || '.' else '. Swap anything you like.' end, 125) || coalesce(' ' || _wx_line(r.couple_id, lt::date + 3), ''),
            'url', './?plan=' || pid));
          update plans set told_at = now() where id = pid;
          n := n + 1;
        end loop;
      end if;
      -- Thursday 5pm: only if Saturday is still waiting on someone, or something bookable isn't booked yet.
      if dw = 4 and h = 17 then
        for w in select p.id, p.ok, (select string_agg(split_part(c.title, ',', 1), ' and ') from cards c
                                      where c.id::text in (select jsonb_array_elements_text(p.bookable)) and not (coalesce(p.booked, '{}'::jsonb) ? c.id::text)) unbooked
                 from plans p where p.couple_id = r.couple_id and p.day = lt::date + 2 and p.auto = 'sat' and p.status in ('sent', 'agreed') and p.told_at is not null limit 1 loop
          if w.unbooked is not null or (select count(*) from jsonb_object_keys(w.ok)) < r.k then
            perform net.http_post(url := u, timeout_milliseconds := 30000, headers := hd, body := jsonb_build_object('code', r.code, 'member', '-', 'kind', 'plan',
              'title', case when w.unbooked is not null then 'Saturday: book ' || left(w.unbooked, 50) else 'Saturday’s still open' end,
              'body', case when w.unbooked is not null then 'Grab it before it fills up, then tap Booked so you both know.' else 'One tap to say yes, or swap something you’d rather do.' end,
              'url', './?plan=' || w.id));
            n := n + 1;
          end if;
        end loop;
      end if;
      -- Friday 2pm: draft tonight's plan out of sight and check real hours; 3pm: fix and announce.
      if dw = 5 and h = 14 and not exists (select 1 from plans p where p.couple_id = r.couple_id and p.day = lt::date) then
        begin pid := _auto_plan(r.couple_id, 'fri', lt::date); exception when others then pid := null; end;
        if pid is not null then
          perform net.http_post(url := chk, timeout_milliseconds := 60000, headers := hk, body := jsonb_build_object('plan', pid));
          n := n + 1;
        end if;
      end if;
      if dw = 5 and h = 15 then
        if not exists (select 1 from plans p where p.couple_id = r.couple_id and p.day = lt::date) then
          begin pid := _auto_plan(r.couple_id, 'fri', lt::date); exception when others then pid := null; end;
        end if;
        for pid in select p.id from plans p where p.couple_id = r.couple_id and p.day = lt::date and p.auto = 'fri' and p.status = 'sent' and p.told_at is null loop
          begin perform _plan_fix(pid); exception when others then null; end;
          perform net.http_post(url := u, timeout_milliseconds := 30000, headers := hd, body := jsonb_build_object('code', r.code, 'member', '-', 'kind', 'plan',
            'title', (select case when p.mode = 'in' and exists (select 1 from jsonb_array_elements(p.items) x where x->>'slot' = 'drinks') then 'Tonight: a drink, then a movie'
                                  when p.mode = 'in' then 'Tonight: dinner in and a movie' else 'Tonight: a new bar, then dinner' end from plans p where p.id = pid),
            'body', left((select _plan_names(items) from plans where id = pid), 125) || coalesce(' ' || replace(_wx_line(r.couple_id, lt::date), 'that day', 'tonight'), ''),
            'url', './?plan=' || pid));
          update plans set told_at = now() where id = pid;
          n := n + 1;
        end loop;
      end if;
      -- Monday noon: would you go back? Favorites come back in future plans.
      if dw = 1 and h = 12 then
        for w in select p.id from plans p where p.couple_id = r.couple_id and p.day between lt::date - 3 and lt::date - 2 and p.auto is not null and p.status in ('agreed', 'done')
                   and exists (select 1 from jsonb_array_elements(p.items) x where jsonb_typeof(x->'card') = 'string' and not exists (select 1 from favorites f where f.couple_id = r.couple_id and f.card_id::text = x->>'card'))
                 order by p.day desc limit 1 loop
          perform net.http_post(url := u, timeout_milliseconds := 30000, headers := hd, body := jsonb_build_object('code', r.code, 'member', '-', 'kind', 'plan',
            'title', 'Would you go back?', 'body', 'Star a place from the weekend and it can come back in a future plan, next to something new.',
            'url', './?plan=' || w.id || '&fav=1'));
          n := n + 1;
        end loop;
      end if;
    end if;

    if r.k < 2 then continue; end if;
    -- ===== Existing reminders (couples) =====
    if h = 18 then
      for w in select c.id, c.title from cards c
               where c.couple_id = r.couple_id and c.deck = 'event' and c.active and not (c.data ? 'place') and c.event_date = lt::date + 1
                 and (select count(distinct l.member) from _lv(r.couple_id) l where l.card_id = c.id and l.verdict in ('yes','love')) >= 2
                 and not exists (select 1 from plans p where p.couple_id = r.couple_id and p.day = lt::date + 1)
                 and not exists (select 1 from surprises z where z.couple_id = r.couple_id and z.status <> 'cancelled' and (z.card_id = c.id or z.day = lt::date + 1))
               order by c.title limit 1 loop
        perform net.http_post(url := u, timeout_milliseconds := 30000, headers := hd, body := jsonb_build_object('code', r.code, 'member', '-', 'kind', 'plan',
          'title', 'Tomorrow: ' || left(w.title, 60),
          'body', 'You both liked this. Make a day of it? Add dinner or a drink from the places you both like.' || coalesce(' ' || replace(_wx_line(r.couple_id, lt::date + 1), 'that day', 'tomorrow'), ''),
          'url', './?planfor=' || w.id));
        n := n + 1;
      end loop;
    end if;
    if h = 9 then
      for w in select p.id from plans p where p.couple_id = r.couple_id and p.day = lt::date + 1 and p.status in ('sent','agreed') and p.mode = 'out' loop
        perform net.http_post(url := chk, timeout_milliseconds := 30000, headers := hk, body := jsonb_build_object('plan', w.id, 'notify', true));
        n := n + 1;
      end loop;
    end if;
    if h = 10 then
      for w in select p.id, p.mode, p.status, _plan_names(p.items) names,
                      (select c.title from jsonb_array_elements(p.items) x join cards c on c.id::text = x->>'card' where c.deck = 'movie' limit 1) movie,
                      (select min(x->>'time') from jsonb_array_elements(p.items) x) t0
               from plans p where p.couple_id = r.couple_id and p.day = lt::date and (p.status = 'agreed' or (p.auto = 'sat' and p.status = 'sent')) limit 1 loop
        for m2 in select a.name me, b.name other from members a join members b on b.couple_id = a.couple_id and b.name <> a.name where a.couple_id = r.couple_id loop
          perform net.http_post(url := u, timeout_milliseconds := 30000, headers := hd, body := jsonb_build_object('code', r.code, 'member', m2.other, 'kind', 'plan',
            'title', case when w.mode = 'in' or coalesce(w.t0, '19:00') >= '16:00' then 'Date night tonight!' else 'Date day today!' end,
            'body', left(case when w.mode = 'in' and w.movie is not null then 'Enjoy watching “' || w.movie || '” with ' || m2.other || '.'
                              else 'You and ' || m2.other || ': ' || coalesce(w.names, 'open it for the details.') end, 125)
                    || case when w.mode <> 'in' then coalesce(' ' || replace(_wx_line(r.couple_id, lt::date), 'that day', 'today'), '') else '' end,
            'url', './?plan=' || w.id));
          n := n + 1;
        end loop;
      end loop;
    end if;
    if h = 11 and dw <> 7 then
      for w in select p.id, (select m.name from members m where m.couple_id = p.couple_id and m.name <> p.by_member order by m.created_at limit 1) other
               from plans p where p.couple_id = r.couple_id and p.day = lt::date - 1 and p.status = 'agreed' and p.auto is null limit 1 loop
        perform net.http_post(url := u, timeout_milliseconds := 30000, headers := hd, body := jsonb_build_object('code', r.code, 'member', coalesce(w.other, '-'), 'kind', 'plan',
          'title', 'How was yesterday?', 'body', 'Did the plan happen? One tap, and it helps the next one fit better.', 'url', './?plan=' || w.id));
        n := n + 1;
      end loop;
    end if;
  end loop;
  return n;
end $function$;
