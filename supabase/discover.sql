-- Discover package (19 Nov 2026). Built on the live database only; does not need the Friends package.
-- Tabs Discover · Watch · Eat · Drinks · Trips; unique spots; the 1-in-4 Discover mix; trip teasers; Close by;
-- the likes grid for an empty pile; the trip-booked job. Apply, then (sim only) select _sim_rewrite();

-- ---------- unique spots: independent, interesting places, found once per area and shared by every couple near them
create table if not exists public.spots (
  place_id text primary key, title text not null, kind text not null, line text, area text,
  lat double precision not null, lng double precision not null, address text, maps text, image text,
  hours jsonb, rating numeric, ratings int, minutes int not null default 30, score int not null default 6,
  keep boolean, created_at timestamptz not null default now());
alter table public.spots enable row level security;

-- Deal unique spots near a couple's home into their cards: a couple of new ones a day, the best one held back as a
-- pop-up scratch moment on the same schedule as hidden gems. Kinds the couple keeps passing on come later.
create or replace function public._spots_deal(p_couple uuid) returns int language plpgsql security definer set search_path to 'public' as $$
declare k couples; h record; tz text; today date; n int := 0; held boolean; drop0 timestamptz; r record;
begin
  select * into k from couples where id = p_couple; select * into h from _home_geo(k.settings);
  if h.lat is null then return 0; end if;
  tz := _zip_tz(k.settings->>'zip'); today := (now() at time zone tz)::date;
  held := not exists (select 1 from cards c where c.couple_id = p_couple and c.data ? 'unique' and c.data->>'hold' = 'true' and (c.data->>'drop_at')::timestamptz > now());
  select max((c.data->>'drop_at')::timestamptz) into drop0 from cards c where c.couple_id = p_couple and c.data->>'hold' = 'true';
  for r in
    select s.*, row_number() over (order by s.score + coalesce(t.w, 0) desc, random()) rn
    from spots s
    left join (select c.kind, sum(case when l.verdict in ('yes','love') then 1 when l.verdict = 'no' then -1 else 0 end) w
               from _lv(p_couple) l join cards c on c.id = l.card_id where c.data ? 'unique' group by c.kind) t on t.kind = s.kind
    where s.keep and _miles(h.lat, h.lng, s.lat, s.lng) <= 20
      and not exists (select 1 from cards c where c.couple_id = p_couple and c.ext_id in ('us:' || s.place_id, 'g:' || s.place_id, 'gp:' || s.place_id))
    order by rn limit 20 loop
    insert into cards (couple_id, deck, kind, title, subtitle, image, ext_id, event_date, created_by, data)
    values (p_couple, 'event', r.kind, left(r.title, 60), left(concat_ws(' · ', r.kind, r.area), 90), r.image, 'us:' || r.place_id, '2099-01-01', 'spots',
      jsonb_strip_nulls(jsonb_build_object('unique', true, 'place', true, 'source', 'spots', 'notes', r.line, 'lat', r.lat, 'lng', r.lng,
        'miles', round(_miles(h.lat, h.lng, r.lat, r.lng)::numeric, 1), 'hours', r.hours, 'hours_at', today, 'minutes', r.minutes,
        'rating', r.rating, 'ratings', r.ratings, 'address', r.address, 'maps', r.maps, 'place_id', r.place_id,
        'hold', case when held and r.rn = 1 then true end,
        'drop_at', case when held and r.rn = 1 then ((greatest(today + 1, (coalesce(drop0, now()) at time zone tz)::date + 4) + interval '11 hours' + random() * interval '8 hours') at time zone tz) end,
        'release', case when not (held and r.rn = 1) then today + ((r.rn - 1) / 2)::int end)))
    on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- trip teasers: a hidden gem or locals-love-it card from a city this person keeps liking on the Trips pile.
-- Only ever dealt into that person's own Discover pile, so a partner never learns about a one-sided like.
create or replace function public._teaser_pick(p_couple uuid, p_member text) returns uuid language sql stable security definer set search_path to 'public' as $$
  select c.id from cards c
  where c.deck = 'trip' and c.active and c.couple_id is null and (c.data ? 'gem' or c.data ? 'locals')
    and c.kind in (select k.kind from _lv(p_couple) l join cards k on k.id = l.card_id
                   where l.member = p_member and l.verdict in ('yes','love') and k.deck = 'trip' group by k.kind having count(*) >= 4)
    and not exists (select 1 from _lv(p_couple) l where l.card_id = c.id and l.member = p_member)
    and not exists (select 1 from sessions s join session_cards sc on sc.session_id = s.id join cards x on x.id = sc.card_id
                    where s.couple_id = p_couple and s.from_member = p_member and s.deck = 'mix' and s.created_at > now() - interval '3 days'
                      and x.deck = 'trip' and (x.data ? 'gem' or x.data ? 'locals'))
  order by random() limit 1 $$;

-- ---------- the Discover pile (was All): about one discovery card in four, never two covered cards in a row.
-- Discovery = hidden gems, unique spots, museums, games, experiences, dated things to do, and now and then a trip teaser.
-- The rest = movies and shows, places to eat, trips, and one drinks spot. No art.
create or replace function public._fill_all(p_session uuid) returns integer language plpgsql security definer set search_path to 'public' as $$
declare s sessions; pos int; f jsonb; base uuid[]; disc uuid[]; t uuid; outv uuid[] := '{}'; bi int := 1; di int := 1; k int := 0; prevcov boolean := false; cid uuid; cov boolean;
  dr jsonb := '["Bar","Night out"]';
begin
  select * into s from sessions where id = p_session;
  select coalesce(max(sc.pos), 0) into pos from session_cards sc where sc.session_id = p_session;
  f := s.filters || jsonb_build_object('days', 10);
  base := array(select q from _pick(s.couple_id, p_session, 'movie', f, 5, s.from_member, true) q)
       || array(select q from _eat_pick(s.couple_id, s.from_member, p_session, s.filters, 3) q)
       || array(select q from _pick(s.couple_id, p_session, 'trip', f, 3, s.from_member, true) q)
       || array(select q from _pick(s.couple_id, p_session, 'event', f || jsonb_build_object('types', dr), 1, s.from_member, true) q);
  base := array(select x from unnest(base) x order by random());
  disc := array(select q from _pick(s.couple_id, p_session, 'event', f || jsonb_build_object('notypes', dr), 4, s.from_member, true) q);
  t := _teaser_pick(s.couple_id, s.from_member);
  if t is not null and not (t = any(base)) and random() < 0.5 then disc := array[t] || disc[1:3]; end if;
  while bi <= coalesce(array_length(base, 1), 0) or di <= coalesce(array_length(disc, 1), 0) loop
    k := k + 1;
    if (k % 4 = 2 or bi > coalesce(array_length(base, 1), 0)) and di <= coalesce(array_length(disc, 1), 0) then
      cid := disc[di]; di := di + 1;
      select (c.data ? 'gem' or c.data ? 'unique') into cov from cards c where c.id = cid;
      if cov and prevcov then continue; end if;   -- never two covered cards in a row
    else
      cid := base[bi]; bi := bi + 1; cov := false;
    end if;
    outv := outv || cid; prevcov := cov;
  end loop;
  insert into session_cards (session_id, card_id, pos) select p_session, x.id, pos + x.o from unnest(outv) with ordinality x(id, o) on conflict do nothing;
  return coalesce(array_length(outv, 1), 0);
end $$;

-- ---------- Drinks: its own pile (bars and nights out). Everything else that is a place lives in Discover.
create or replace function public.start_bite(p_code text, p_member text, p_deck text, p_extra boolean) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v uuid := _couple(p_code); sid uuid; d text := _today()::text; dk text := case when p_deck = 'drinks' then 'event' else p_deck end; dr boolean := p_deck = 'drinks';
begin
  perform pg_advisory_xact_lock(hashtext(v::text || p_member || d || 'start_bite' || p_deck));
  if p_deck not in ('movie','dinner','event','drinks') then raise exception 'bad_deck'; end if;
  if not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_member'; end if;
  select id into sid from sessions where couple_id = v and from_member = p_member and deck = dk and filters->>'bite' = d and coalesce(filters->>'away', '') = ''
    and coalesce((filters->>'drinks')::boolean, false) = dr order by (select count(*) from swipes w where w.session_id = sessions.id) desc, created_at, id limit 1;
  if sid is null then
    insert into sessions (couple_id, deck, from_member, filters) values (v, dk, p_member, jsonb_build_object('solo', true, 'bite', d)
      || case when dr then '{"drinks":true,"types":["Bar","Night out"]}'::jsonb else '{}'::jsonb end) returning id into sid;
    perform _fill_session(sid, case when p_deck = 'dinner' then 3 else 10 end);
  elsif p_extra and not coalesce((select (filters->>'extra')::boolean from sessions where id = sid), false) then
    perform _fill_session(sid, case when p_deck = 'dinner' then 3 else 10 end);
    update sessions set filters = filters || '{"extra":true}'::jsonb where id = sid;
  end if;
  return jsonb_build_object('id', sid);
end $$;

-- ---------- reasons shown on Discover cards, worked out for the person looking (never from a partner's likes)
create or replace function public.disc_why(p_code text, p_member text, p_session uuid) returns jsonb language sql stable security definer set search_path to 'public' as $$
  -- the trip line only when it is true: this member has liked 4+ trip cards in that city (a teaser); never the partner's likes
  select coalesce(jsonb_object_agg(c.id, case
      when c.deck = 'trip' then format('You’ve liked %s things in %s. Stop by here when you go.', n.liked, c.kind)
      else c.data->>'notes' end), '{}'::jsonb)
  from session_cards sc join sessions s on s.id = sc.session_id join cards c on c.id = sc.card_id
  cross join lateral (select count(*) liked from _lv(_couple(p_code)) l join cards k on k.id = l.card_id
                      where c.deck = 'trip' and l.member = p_member and l.verdict in ('yes','love') and k.deck = 'trip' and k.kind = c.kind) n
  where sc.session_id = p_session and s.couple_id = _couple(p_code) and s.from_member = p_member
    and ((c.deck = 'trip' and (c.data ? 'gem' or c.data ? 'locals') and s.deck = 'mix' and n.liked >= 4)
         or (c.deck <> 'trip' and c.data ? 'unique' and coalesce(c.data->>'notes', '') <> '')) $$;

-- ---------- Close by: your other likes (and the ones you both like) a short walk from a place, with walk times;
-- now and then a hidden gem there too. Never a partner's one-sided like.
create or replace function public.close_by(p_code text, p_member text, p_card uuid) returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v uuid := _couple(p_code); c0 cards; la double precision; lo double precision; mc int; res jsonb;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  select * into c0 from cards where id = p_card and (couple_id = v or couple_id is null);
  la := nullif(c0.data->>'lat', '')::double precision; lo := nullif(c0.data->>'lng', '')::double precision;
  if c0.id is null or la is null then return jsonb_build_object('list', '[]'::jsonb); end if;
  select greatest(count(*), 2) into mc from members where couple_id = v;
  with cand as (
    select x.*, _miles(la, lo, (x.data->>'lat')::double precision, (x.data->>'lng')::double precision) mi,
      (select count(distinct l.member) from _lv(v) l where l.card_id = x.id and l.verdict in ('yes','love')) likes,
      exists (select 1 from _lv(v) l where l.card_id = x.id and l.member = p_member and l.verdict in ('yes','love')) mine,
      exists (select 1 from _lv(v) l where l.card_id = x.id and l.member = p_member) seen_me
    from cards x
    where x.active and x.id <> c0.id and x.couple_id = v and x.deck in ('event','dinner') and x.data->>'lat' is not null
      and coalesce(x.data->>'away', '') = coalesce(c0.data->>'away', '') and not _never(v, x.id)
      and _miles(la, lo, (x.data->>'lat')::double precision, (x.data->>'lng')::double precision) <= 1.0),
  pick as (
    select cand.*, case when likes >= mc then 'both' when mine then 'mine' else 'gem' end why from cand where likes >= mc or mine
    union all
    (select cand.*, 'gem' from cand where data ? 'gem' and not seen_me and mi <= 0.6
       and (coalesce(data->>'hold', '') <> 'true' or exists (select 1 from reveals r where r.couple_id = v and r.member = p_member and r.card_id = cand.id))
       and coalesce((data->>'release')::date, _today()) <= _today()
     order by mi limit 1))
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'deck', p.deck, 'kind', p.kind, 'title', p.title, 'subtitle', p.subtitle, 'image', p.image, 'data', p.data,
      'mi', round(p.mi::numeric, 2), 'why', p.why,
      'walk', coalesce((select ceil(rc.seconds / 60.0)::int from route_cache rc where rc.mode = 'WALK' and rc.seconds is not null
                        and ((rc.o = c0.data->>'place_id' and rc.d = p.data->>'place_id') or (rc.d = c0.data->>'place_id' and rc.o = p.data->>'place_id')) limit 1),
                       greatest(2, round(p.mi * 20)::int)))
      order by case p.why when 'both' then 0 when 'mine' then 1 else 2 end, p.mi), '[]'::jsonb) into res
  from (select * from pick order by case why when 'both' then 0 when 'mine' then 1 else 2 end, mi limit 6) p;
  return jsonb_build_object('from', jsonb_build_object('id', c0.id, 'title', c0.title), 'list', res);
end $$;

-- ---------- the likes grid shown when a pile runs out: what you both like first, then your own likes. Never a partner's.
create or replace function public.lib_grid(p_code text, p_member text, p_deck text) returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v uuid := _couple(p_code); mc int;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  select greatest(count(*), 2) into mc from members where couple_id = v;
  return (select coalesce(jsonb_agg(_card_json(c) || jsonb_build_object('who', case when x.n >= mc then 'both' else 'me' end) order by (x.n >= mc) desc, x.last desc), '[]'::jsonb)
    from (select l.card_id, count(*) filter (where l.verdict in ('yes','love')) n, bool_or(l.member = p_member and l.verdict in ('yes','love')) mine,
                 bool_or(l.verdict = 'seen') seen, max(l.created_at) last from _lv(v) l group by l.card_id) x
    join cards c on c.id = x.card_id and c.active
    where x.mine and not (x.seen and c.deck = 'movie')
      and (case p_deck when 'movie' then c.deck = 'movie' when 'dinner' then c.deck = 'dinner' and c.couple_id = v when 'trip' then c.deck = 'trip'
             when 'drinks' then c.deck = 'event' and c.couple_id = v and c.kind in ('Bar', 'Night out')
             when 'all' then c.deck = 'event' and c.couple_id = v and coalesce(c.kind, '') not in ('Bar', 'Night out')
             else false end)
      and (c.deck <> 'event' or c.data ? 'place' or c.event_date >= _today())
    limit 60);
end $$;

-- ---------- the trip job: once a trip is booked (stay or flights) or its dates are agreed, look for that city's hidden
-- gems, unique spots, locals' favourites and events during the stay. Once per trip.
create or replace function public._trip_disc_tick() returns int language plpgsql security definer set search_path to 'public' as $$
declare k record; c text; m jsonb; t trip_cities; n int := 0; u text := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/'; hd jsonb;
begin
  hd := jsonb_build_object('Content-Type', 'application/json', 'x-sync-key', (select value from app_secrets where key = 'sync_key'));
  for k in select * from couples where jsonb_array_length(coalesce(settings->'plans', '[]'::jsonb)) > 0 loop
    for c in select jsonb_array_elements_text(k.settings->'plans') loop
      m := k.settings->'plan_meta'->c;
      continue when m is null or m->>'disc_at' is not null;
      continue when not (coalesce((m->'items'->>'stay')::boolean, false) or coalesce((m->'items'->>'flights')::boolean, false) or coalesce((m->>'dates_ok')::boolean, false));
      select * into t from trip_cities where city = c;
      continue when t.city is null;
      update couples set settings = jsonb_set(settings, array['plan_meta', c, 'disc_at'], to_jsonb(now()::text)) where id = k.id;
      if not exists (select 1 from gem_areas a where _miles(a.lat, a.lng, t.lat, t.lng) < 8) then insert into gem_areas (lat, lng, label) values (t.lat, t.lng, c); end if;
      perform net.http_post(url := u || 'spots', timeout_milliseconds := 120000, headers := hd, body := jsonb_build_object('lat', t.lat, 'lng', t.lng, 'area', c, 'trip', c));
      if not exists (select 1 from gem_state gs where gs.k = 'locals:' || c) then
        insert into gem_state values ('locals:' || c, now()) on conflict do nothing;
        perform net.http_post(url := u || 'locals', timeout_milliseconds := 120000, headers := hd, body := jsonb_build_object('city', c));
      end if;
      if m->>'from' is not null then
        perform net.http_post(url := u || 'tmevents', timeout_milliseconds := 60000, headers := hd, body := jsonb_build_object('city', c, 'lat', t.lat, 'lng', t.lng, 'from', m->>'from', 'to', coalesce(m->>'to', m->>'from'), 'code', k.code));
      end if;
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;

-- ---------- one entry point for the scheduled job: deal unique spots on the look runs, check booked trips hourly
create or replace function public._disc_tick(p_mode text default 'all') returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare cp record; a record; dealt int := 0; trips int := 0; looked int := 0;
begin
  if p_mode in ('all', 'look') then
    -- find unique spots around where couples live: two areas a run, each looked at again after 60 days
    for a in select distinct round(h.lat::numeric, 1)::double precision lat, round(h.lng::numeric, 1)::double precision lng
             from couples c cross join lateral _home_geo(c.settings) h where h.lat is not null loop
      exit when looked >= 2;
      continue when exists (select 1 from gem_state gs where gs.k = format('spots:%s,%s', a.lat, a.lng) and gs.at > now() - interval '60 days');
      insert into gem_state values (format('spots:%s,%s', a.lat, a.lng), now()) on conflict on constraint gem_state_pkey do update set at = excluded.at;
      perform net.http_post(url := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/spots', timeout_milliseconds := 150000,
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-key', (select value from app_secrets where key = 'sync_key')),
        body := jsonb_build_object('lat', a.lat, 'lng', a.lng));
      looked := looked + 1;
    end loop;
    for cp in select id from couples loop dealt := dealt + _spots_deal(cp.id); end loop;
  end if;
  trips := _trip_disc_tick();
  return jsonb_build_object('dealt', dealt, 'trips', trips, 'areas_looked', looked);
end $$;

-- ---------- patches to existing functions (anchors checked; each must match once)
do $$
declare d text; d2 text;
begin
  -- _pick: a "notypes" filter for the Discover pile; unique spots are released and held back the same way hidden gems are
  d := pg_get_functiondef('public._pick(uuid,uuid,text,jsonb,integer,text,boolean)'::regprocedure);
  d2 := replace(d, $a$and (p_deck <> 'event' or not (c.data ? 'gem') or (case when c.data->>'hold' = 'true'$a$,
                   $a$and (p_deck <> 'event' or not (c.data ? 'gem' or c.data ? 'unique') or (case when c.data->>'hold' = 'true'$a$);
  if d2 = d then raise exception '_pick anchor 1'; end if; d := d2;
  d2 := replace(d, $a$or c.kind in (select jsonb_array_elements_text(p_filters->'types'))))$a$,
                   $a$or c.kind in (select jsonb_array_elements_text(p_filters->'types')))
      and (p_deck <> 'event' or jsonb_typeof(p_filters->'notypes') is distinct from 'array' or not (coalesce(c.kind, '') in (select jsonb_array_elements_text(p_filters->'notypes')))))$a$);
  if d2 = d then raise exception '_pick anchor 2'; end if; d := d2;
  -- a released unique spot goes near the front of the Discover slots, like a hidden gem
  d2 := replace(d, $a$(p_deck = 'event' and c.data ? 'gem' and not coalesce(a.mine, false)) gemfirst$a$,
                   $a$(p_deck = 'event' and (c.data ? 'gem' or c.data ? 'unique') and not coalesce(a.mine, false)) gemfirst$a$);
  if d2 = d then raise exception '_pick anchor 3'; end if;
  execute d2;
  -- auto plans: a hidden gem or unique spot that is still held or not yet released never goes into a plan before someone has swiped it
  d := pg_get_functiondef('public._ap_pick'::regproc);
  d2 := replace(d, $a$where c.active and not (c.id = any(p_used)) and coalesce(c.data->>'away', '') = '' and not _never(p_couple, c.id)$a$,
                   $a$where c.active and not (c.id = any(p_used)) and coalesce(c.data->>'away', '') = '' and not _never(p_couple, c.id)
      and (not (c.data ? 'gem' or c.data ? 'unique') or coalesce(k.seen, 0) > 0
           or (coalesce(c.data->>'hold', '') <> 'true' and coalesce((c.data->>'release')::date, _today()) <= _today()))$a$);
  if d2 = d then raise exception '_ap_pick anchor'; end if;
  execute d2;
  -- the daily cards push names the new piles
  d := pg_get_functiondef('public._daily_cards_tick()'::regprocedure);
  d2 := replace(d, 'A fresh handful in Movies, Eat, Go out, Trips and Art.', 'A fresh handful in Discover, Watch, Eat, Drinks and Trips.');
  if d2 = d then raise exception '_daily_cards_tick anchor'; end if;
  execute d2;
  -- the timed scratch moment: a held unique spot says so (hidden gems keep their words)
  d := pg_get_functiondef((select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = '_gems_tick' order by p.pronargs desc limit 1));
  d2 := replace(d, $a$for r in select c.id, cp.code from cards c join couples cp on cp.id = c.couple_id where c.data->>'hold' = 'true'$a$,
                   $a$for r in select c.id, cp.code, (c.data ? 'unique') u from cards c join couples cp on cp.id = c.couple_id where c.data->>'hold' = 'true'$a$);
  if d2 = d then raise exception '_gems_tick anchor 1'; end if; d := d2;
  d2 := replace(d, $a$'title', 'A hidden gem turned up', 'body', 'Scratch the card to see a place near you that most people walk past.'$a$,
                   $a$'title', case when r.u then 'A one-of-a-kind spot turned up' else 'A hidden gem turned up' end, 'body', case when r.u then 'Wipe the window to see an independent spot near you.' else 'Scratch the card to see a place near you that most people walk past.' end$a$);
  if d2 = d then raise exception '_gems_tick anchor 2'; end if;
  execute d2;
end $$;
