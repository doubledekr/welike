-- Hamoody's plan feedback (Dave's go, 19 Nov 2026): surprise stops, swap suggestions, your own places (a cottage),
-- a "where" for the day, and side quests between stops.
alter table plans add column if not exists suggest jsonb not null default '{}'::jsonb;
alter table plans add column if not exists where_at jsonb;

-- items keep who hid a stop, and side quests are a slot of their own
create or replace function _plan_items_clean(p_couple uuid, p_items jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'slot', x->>'slot',
           'time', case when (x->>'time') ~ '^\d{2}:\d{2}$' then x->>'time' else null end,
           'card', case when c.id is not null then to_jsonb(c.id) else 'null'::jsonb end,
           'find', coalesce((x->>'find')::boolean, false) and c.id is null,
           'why', case when c.id is not null and (x->>'why') ~ '^(both|fav|new|one:.{1,40})$' then x->>'why' end)
         || case when c.id is not null and exists (select 1 from members m where m.couple_id = p_couple and m.name = x->>'hidden') then jsonb_build_object('hidden', x->>'hidden') else '{}'::jsonb end
         || case when coalesce((x->>'told')::boolean, false) then '{"told":true}'::jsonb else '{}'::jsonb end
         order by ord), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality e(x, ord)
  left join cards c on c.id = (case when (x->>'card') ~ '^[0-9a-f-]{36}$' then (x->>'card')::uuid end) and (c.couple_id = p_couple or c.couple_id is null)
  where x->>'slot' in ('day','drinks','drinks2','drinks3','dinner','evening','quest','quest2') and ord <= 10 $$;

-- when a surprise stop shows itself: an hour before it starts (local time)
create or replace function _plan_reveal_at(p_day date, p_time text) returns timestamptz language sql immutable as $$
  select ((p_day::text || ' ' || coalesce(nullif(p_time, ''), '12:00'))::timestamp at time zone 'America/New_York') - interval '1 hour' $$;

create or replace function _plan_json(p plans) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'day', p.day, 'by', p.by_member, 'status', p.status, 'mode', p.mode, 'ok', p.ok, 'went', p.went, 'updated_at', p.updated_at, 'closed', p.closed,
    'auto', p.auto, 'legs', coalesce(p.legs->'legs', '[]'::jsonb), 'weather', _wx_day(p.couple_id, p.day), 'weather_line', case when p.mode <> 'in' then _wx_line(p.couple_id, p.day) end, 'booked', coalesce(p.booked, '{}'::jsonb), 'bookable', coalesce(p.bookable, '[]'::jsonb),
    'where', p.where_at,
    'suggest', (select coalesce(jsonb_object_agg(s.key, jsonb_build_object('by', s.value->>'by', 'at', s.value->>'at', 'card', (select _card_json(c) from cards c where c.id = (s.value->>'card')::uuid))), '{}'::jsonb) from jsonb_each(coalesce(p.suggest, '{}')) s),
    'picks', (select coalesce(jsonb_object_agg(s.key, (select coalesce(jsonb_object_agg(m.key, case when m.key = 'tb' then m.value else (select _card_json(c) from cards c where c.id = (m.value #>> '{}')::uuid) end), '{}'::jsonb)
                                                       from jsonb_each(s.value) m)), '{}'::jsonb) from jsonb_each(p.picks) s),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('slot', x->>'slot', 'time', x->>'time', 'find', coalesce((x->>'find')::boolean, false), 'why', x->>'why',
                'hidden', x->>'hidden', 'reveal', case when x->>'hidden' is not null then _plan_reveal_at(p.day, x->>'time') end,
                'pair', case when jsonb_typeof(x->'card') <> 'string' and jsonb_array_length(coalesce(x->'pair', '[]'::jsonb)) = 2 then (select jsonb_agg(_card_json(c2) order by (x->'pair'->>0) = c2.id::text desc) from cards c2 where c2.id::text in (select jsonb_array_elements_text(x->'pair'))) end,
                'session', case when coalesce((x->>'find')::boolean, false) then (select s.id from sessions s where s.couple_id = p.couple_id and s.filters->>'plan' = p.id::text and s.filters->>'slot' = x->>'slot' order by s.created_at desc limit 1) end,
                'card', (select _card_json(c) from cards c where c.id = (case when jsonb_typeof(x->'card') = 'string' then (x->>'card')::uuid end))) order by ord), '[]'::jsonb)
              from jsonb_array_elements(p.items) with ordinality e(x, ord))) $$;

-- what one person may see: someone else's surprise stop stays a surprise until an hour before
create or replace function _plan_mask(j jsonb, p_member text) returns jsonb
language sql stable as $$
  select j || jsonb_build_object('items', (select coalesce(jsonb_agg(case when x->>'hidden' is not null and x->>'hidden' <> p_member and now() < (x->>'reveal')::timestamptz
      then x || jsonb_build_object('card', jsonb_build_object('id', 'hid:' || (x->>'slot'), 'deck', x->'card'->>'deck', 'kind', 'surprise', 'title', 'A surprise from ' || (x->>'hidden'),
             'subtitle', 'Shows itself an hour before', 'image', null, 'data', jsonb_build_object('surprise', true)))
      else x end order by ord), '[]'::jsonb) from jsonb_array_elements(j->'items') with ordinality e(x, ord))) $$;

create or replace function plan_list(p_code text, p_member text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return (select coalesce(jsonb_agg(_plan_mask(x, p_member) order by ord), '[]'::jsonb) from jsonb_array_elements(plan_list(p_code)) with ordinality e(x, ord));
end $$;
grant execute on function plan_list(text, text) to anon, authenticated;

-- an edit by the person who can't see the surprise keeps it as it was
create or replace function _plan_unmask(p_id uuid, p_items jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(case when x->>'card' like 'hid:%'
      then coalesce((select a || jsonb_build_object('time', coalesce(x->>'time', a->>'time')) from plans pl, jsonb_array_elements(pl.items) a where pl.id = p_id and a->>'slot' = substr(x->>'card', 5) limit 1), x)
      else x end order by ord), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality e(x, ord) $$;
do $$ declare d text := pg_get_functiondef('plan_save'::regproc); a text := '  it := _plan_items_clean(v, p_items);';
begin
  if position(a in d) = 0 then raise exception 'plan_save anchor'; end if;
  execute replace(d, a, '  it := _plan_items_clean(v, case when p_id is not null then _plan_unmask(p_id, p_items) else p_items end);');
end $$;

-- notifications never name a surprise stop
create or replace function _plan_names(p_items jsonb) returns text
language sql stable security definer set search_path = public as $$
  select string_agg(case when x->>'hidden' is not null then 'a surprise'
    when jsonb_typeof(x->'card') = 'string' then (select split_part(c.title, ',', 1) from cards c where c.id = (x->>'card')::uuid)
    when jsonb_array_length(coalesce(x->'pair', '[]'::jsonb)) = 2 then (select split_part(c.title, ',', 1) from cards c where c.id = (x->'pair'->>0)::uuid) || ' or ' || (select split_part(c.title, ',', 1) from cards c where c.id = (x->'pair'->>1)::uuid)
    else case x->>'slot' when 'evening' then 'a movie you pick together' when 'dinner' then 'dinner you pick together' when 'day' then 'something you pick together' else 'a bar you pick together' end end, ', then ' order by ord)
  from jsonb_array_elements(p_items) with ordinality e(x, ord) $$;

-- the other person suggests a different stop; the planner swaps it in or keeps theirs
create or replace function plan_suggest(p_code text, p_member text, p_plan uuid, p_slot text, p_card uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); p plans;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  select * into p from plans where id = p_plan and couple_id = v and status in ('sent', 'agreed'); if p.id is null then raise exception 'bad_plan'; end if;
  if not exists (select 1 from jsonb_array_elements(p.items) x where x->>'slot' = p_slot) then raise exception 'bad_slot'; end if;
  if p_card is null then update plans set suggest = suggest - p_slot where id = p.id returning * into p;
  else
    if not exists (select 1 from cards c where c.id = p_card and (c.couple_id = v or c.couple_id is null)) then raise exception 'bad_card'; end if;
    update plans set suggest = coalesce(suggest, '{}') || jsonb_build_object(p_slot, jsonb_build_object('card', p_card, 'by', p_member, 'at', now())) where id = p.id returning * into p;
  end if;
  return _plan_mask(_plan_json(p), p_member);
end $$;
create or replace function plan_suggest_answer(p_code text, p_member text, p_plan uuid, p_slot text, p_take boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); p plans; sg jsonb;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  select * into p from plans where id = p_plan and couple_id = v; if p.id is null then raise exception 'bad_plan'; end if;
  sg := p.suggest->p_slot; if sg is null then return _plan_mask(_plan_json(p), p_member); end if;
  if sg->>'by' = p_member then raise exception 'own_suggestion'; end if;
  if p_take then
    -- taking a suggestion counts as a yes from both: one of you suggested it, the other took it
    update plans set items = (select jsonb_agg(case when x->>'slot' = p_slot then (x - 'hidden' - 'pair') || jsonb_build_object('card', sg->>'card', 'find', false, 'why', 'both') else x end order by ord) from jsonb_array_elements(items) with ordinality e(x, ord)),
      suggest = suggest - p_slot, updated_at = now(), checked_at = null, ok = coalesce(ok, '{}') || jsonb_build_object(p_member, true, sg->>'by', true)
      where id = p.id returning * into p;
  else
    update plans set suggest = suggest - p_slot where id = p.id returning * into p;
  end if;
  return _plan_mask(_plan_json(p), p_member);
end $$;
grant execute on function plan_suggest(text, text, uuid, text, uuid), plan_suggest_answer(text, text, uuid, text, boolean) to anon, authenticated;

-- your own places (a cottage, family's house): saved for the couple, usable as a stop and as where the day happens
create or replace function place_save(p_code text, p_member text, p_name text, p_address text, p_lat double precision, p_lng double precision) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); cid uuid; nm text := left(btrim(p_name), 40);
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  if nm = '' or p_lat is null or p_lng is null or abs(p_lat) > 90 or abs(p_lng) > 180 then raise exception 'bad_place'; end if;
  insert into cards (couple_id, deck, kind, title, subtitle, active, created_by, ext_id, data)
  values (v, 'event', 'Your place', nm, left(coalesce(p_address, ''), 90), true, p_member, 'own:' || md5(v::text || lower(nm)),
    jsonb_build_object('place', true, 'saved', true, 'lat', p_lat, 'lng', p_lng, 'address', p_address, 'hours', 'always', 'own', true))
  on conflict do nothing returning id into cid;
  if cid is null then
    select id into cid from cards where couple_id = v and ext_id = 'own:' || md5(v::text || lower(nm));
    update cards set active = true, subtitle = left(coalesce(p_address, ''), 90), data = data || jsonb_build_object('lat', p_lat, 'lng', p_lng, 'address', p_address) where id = cid;
  end if;
  return place_list(p_code);
end $$;
create or replace function place_list(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(_card_json(c) order by c.created_at), '[]'::jsonb) from cards c where c.couple_id = _couple(p_code) and c.active and c.ext_id like 'own:%' $$;
create or replace function place_remove(p_code text, p_member text, p_card uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code);
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  update cards set active = false where id = p_card and couple_id = v and ext_id like 'own:%';
  return place_list(p_code);
end $$;
-- where the day happens (null: around home)
create or replace function plan_where(p_code text, p_member text, p_plan uuid, p_where jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); p plans;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  update plans set where_at = case when p_where is null or jsonb_typeof(p_where->'lat') <> 'number' then null else jsonb_build_object('name', left(p_where->>'name', 40), 'lat', (p_where->>'lat')::float8, 'lng', (p_where->>'lng')::float8) end
    where id = p_plan and couple_id = v returning * into p;
  if p.id is null then raise exception 'bad_plan'; end if;
  return _plan_mask(_plan_json(p), p_member);
end $$;
grant execute on function place_save(text, text, text, text, double precision, double precision), place_list(text), place_remove(text, text, uuid), plan_where(text, text, uuid, jsonb) to anon, authenticated;

-- a side quest goes in between two stops; it keeps both yeses (it's an extra, not a change of plan)
create or replace function quest_add(p_code text, p_member text, p_plan uuid, p_place jsonb, p_time text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); p plans; cid uuid; sl text; ext text := 'g:' || (p_place->>'id');
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  select * into p from plans where id = p_plan and couple_id = v and status in ('sent', 'agreed'); if p.id is null then raise exception 'bad_plan'; end if;
  if coalesce(p_place->>'id', '') !~ '^[A-Za-z0-9_-]{10,}$' or jsonb_typeof(p_place->'lat') <> 'number' or p_time !~ '^\d{2}:\d{2}$' then raise exception 'bad_place'; end if;
  sl := case when not exists (select 1 from jsonb_array_elements(p.items) x where x->>'slot' = 'quest') then 'quest'
             when not exists (select 1 from jsonb_array_elements(p.items) x where x->>'slot' = 'quest2') then 'quest2' end;
  if sl is null then raise exception 'two_quests'; end if;
  select id into cid from cards where couple_id = v and ext_id in (ext, 'gp:' || (p_place->>'id')) limit 1;
  if cid is null then
    insert into cards (couple_id, deck, kind, title, subtitle, image, active, created_by, ext_id, data)
    values (v, 'event', coalesce(left(p_place->>'type', 30), 'Side quest'), left(p_place->>'name', 60), left(concat_ws(' · ', p_place->>'type', p_place->>'address'), 90), p_place->>'image', true, 'quest', ext,
      jsonb_strip_nulls(jsonb_build_object('place', true, 'quest', true, 'place_id', p_place->>'id', 'lat', (p_place->>'lat')::float8, 'lng', (p_place->>'lng')::float8, 'rating', p_place->'rating', 'ratings', p_place->'ratings',
        'maps', p_place->>'maps', 'url', p_place->>'url', 'address', p_place->>'address', 'ptype', p_place->>'ptype')))
    returning id into cid;
  end if;
  update plans set items = items || jsonb_build_array(jsonb_build_object('slot', sl, 'time', p_time, 'card', cid, 'find', false, 'why', 'new')), updated_at = now(), checked_at = null
    where id = p.id returning * into p;
  return _plan_mask(_plan_json(p), p_member);
end $$;
grant execute on function quest_add(text, text, uuid, jsonb, text) to anon, authenticated;

-- the moment a surprise shows itself, the other person hears what it is (once)
create or replace function _plan_reveal_tick() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select p.id, p.day, cp.code, x->>'slot' slot, x->>'time' tm, x->>'hidden' hider, (select title from cards c where c.id = (x->>'card')::uuid) title
           from plans p join couples cp on cp.id = p.couple_id, jsonb_array_elements(p.items) x
           where p.status in ('sent', 'agreed') and p.day between _today() and _today() + 1 and x->>'hidden' is not null and coalesce((x->>'told')::boolean, false) = false
             and _plan_reveal_at(p.day, x->>'time') <= now() and _plan_reveal_at(p.day, x->>'time') > now() - interval '2 hours' loop
    update plans set items = (select jsonb_agg(case when e.x->>'slot' = r.slot then e.x || '{"told":true}' else e.x end order by ord) from jsonb_array_elements(items) with ordinality e(x, ord)) where id = r.id;
    perform net.http_post(url := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/nudge', timeout_milliseconds := 30000, headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object('code', r.code, 'member', r.hider, 'title', 'Your surprise: ' || split_part(r.title, ',', 1), 'body', r.hider || ' kept this one secret. See you there at ' || to_char(('2000-01-01 ' || r.tm)::timestamp, 'FMHH12:MIam') || '.', 'url', './?plan=' || r.id, 'plan', r.id));
    n := n + 1;
  end loop;
  return n;
end $$;
select cron.schedule('welike-plan-reveal', '*/5 * * * *', 'select public._plan_reveal_tick()');

-- options for a stop: your own places first, and restaurants found around a place away from home count there
do $$ declare d text := pg_get_functiondef('plan_options(text,text,date,text,text,text,double precision,double precision,uuid[])'::regprocedure);
  a1 text := 'and coalesce(c.data->>''away'', '''') = '''' and not _never(v.id, c.id)';
  a2 text := 'case when c.likes >= greatest((select n from mc), 2) then ''both''';
  a3 text := 'row_number() over (order by case why when ''both'' then 0';
begin
  if position(a1 in d) = 0 or position(a2 in d) = 0 or position(a3 in d) = 0 then raise exception 'plan_options anchors'; end if;
  d := replace(d, a1, 'and (coalesce(c.data->>''away'', '''') = '''' or (p_lat is not null and c.data->>''lat'' is not null and _miles((c.data->>''lat'')::float8, (c.data->>''lng'')::float8, p_lat, p_lng) <= 3)) and not _never(v.id, c.id)');
  d := replace(d, a2, 'case when c.data->>''own'' = ''true'' then ''yours'' when c.likes >= greatest((select n from mc), 2) then ''both''');
  d := replace(d, a3, 'row_number() over (order by case why when ''yours'' then -1 when ''both'' then 0');
  execute d;
end $$;
