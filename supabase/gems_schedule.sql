-- Hidden gems on a calmer clock (Dave, 18 Nov): look around 4 times a day, the big AI work overnight, the timed
-- notices every 15 minutes. p_mode: 'look' (find new areas, deal gems into decks), 'night' (the AI pipeline:
-- pick, write, match, local favourites; deals too once nothing is pending), 'notify' (scratch-card moments,
-- weather holds, trip and travel notices). 'all' (the default) does everything, as before, so the sim's clock
-- and any other caller behave exactly as they did.
drop function if exists public._gems_tick();
create or replace function public._gems_tick(p_mode text default 'all')
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare k record; h record; c text; m jsonb; t trip_cities; pend int; n int; dealt int := 0; i int; pushed int := 0; r record; d1 date; today date;
  u text := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/'; hd jsonb; kk text;
  look boolean := p_mode in ('all', 'look'); night boolean := p_mode in ('all', 'night'); tell boolean := p_mode in ('all', 'notify');
begin
  select value into kk from app_secrets where key = 'sync_key';
  hd := jsonb_build_object('Content-Type', 'application/json', 'x-sync-key', kk);
  if look then
    for k in select * from couples loop
      select * into h from _home_geo(k.settings);
      if h.lat is not null and not exists (select 1 from gem_areas a where _miles(a.lat, a.lng, h.lat, h.lng) < 8) then
        insert into gem_areas (lat, lng, label) values (h.lat, h.lng, 'ZIP code ' || coalesce(k.settings->>'zip', '') || ' and the towns and city around it');
      end if;
      for c in select jsonb_array_elements_text(coalesce(k.settings->'plans', '[]'::jsonb)) loop
        select * into t from trip_cities where city = c;   -- any trip a couple has started
        if t.city is not null and not exists (select 1 from gem_areas a where _miles(a.lat, a.lng, t.lat, t.lng) < 8) then
          insert into gem_areas (lat, lng, label) values (t.lat, t.lng, c);
        end if;
      end loop;
    end loop;
    for t in select tc.* from trip_cities tc where exists (select 1 from swipes w join cards cc on cc.id = w.card_id where cc.deck = 'trip' and cc.kind = tc.city and w.verdict in ('yes','love') group by w.couple_id having count(distinct w.member || w.card_id::text) > 5) loop
      if not exists (select 1 from gem_areas a where _miles(a.lat, a.lng, t.lat, t.lng) < 8) then insert into gem_areas (lat, lng, label) values (t.lat, t.lng, t.city); end if;
    end loop;
  end if;
  select (select count(*) from gem_areas where status = 'new') + (select count(*) from gems where keep is null) + (select count(*) from gems where keep and matched is null) into pend;
  if night then
    if exists (select 1 from gem_areas where status = 'new') and not exists (select 1 from gem_state gs where gs.k = 'pick' and gs.at > now() - interval '170 seconds') then
      insert into gem_state values ('pick', now()) on conflict on constraint gem_state_pkey do update set at = now();
      perform net.http_post(url := u || 'gems', headers := hd, body := '{"stage":"pick"}'::jsonb, timeout_milliseconds := 140000);
    end if;
    if exists (select 1 from gems where keep is null) and not exists (select 1 from gem_state gs where gs.k = 'write' and gs.at > now() - interval '170 seconds') then
      insert into gem_state values ('write', now()) on conflict on constraint gem_state_pkey do update set at = now();
      perform net.http_post(url := u || 'gems', headers := hd, body := '{"stage":"write"}'::jsonb, timeout_milliseconds := 140000);
    end if;
    if exists (select 1 from gems where keep and matched is null) then
      perform net.http_post(url := u || 'gems', headers := hd, body := '{"stage":"match"}'::jsonb, timeout_milliseconds := 50000);
    end if;
  end if;
  if pend = 0 and (look or night) and not (p_mode = 'night' and exists (select 1 from gem_state gs where gs.k = 'dealt' and gs.at > now() - interval '3 hours')) then
    if p_mode = 'night' then insert into gem_state values ('dealt', now()) on conflict on constraint gem_state_pkey do update set at = now(); end if;
    for k in select id from couples loop dealt := dealt + _gems_deal(k.id); perform _gems_eat(k.id); end loop; perform _gems_art();
    for k in select * from couples loop
      select * into h from _home_geo(k.settings);
      if h.lat is not null and k.settings->>'gem_wide' is null and (select count(*) from gems g where g.keep and g.matched and g.score >= 6 and _miles(h.lat, h.lng, g.lat, g.lng) <= 30) < 10 then
        update couples set settings = settings || '{"gem_wide":true}'::jsonb where id = k.id;
        for i in 0..5 loop
          insert into gem_areas (lat, lng, label)
          select p.la, p.ln, 'the wider area around ZIP code ' || coalesce(k.settings->>'zip', '') from (select h.lat + (40 / 111.0) * cos(i * pi() / 3) la, h.lng + (40 / (111.0 * cos(radians(h.lat)))) * sin(i * pi() / 3) ln) p
          where not exists (select 1 from gem_areas a where _miles(a.lat, a.lng, p.la, p.ln) < 8);
        end loop;
      end if;
    end loop;
    for c in select distinct a.label from gem_areas a join trip_cities tc on tc.city = a.label loop perform _gems_trip(c); end loop;
  end if;
  if night then
    -- local favourites for a trip city, once per city
    select a.label into c from gem_areas a join trip_cities tc on tc.city = a.label where not exists (select 1 from gem_state gs where gs.k = 'locals:' || a.label) limit 1;
    if c is not null then
      insert into gem_state values ('locals:' || c, now()) on conflict do nothing;
      perform net.http_post(url := u || 'locals', headers := hd, body := jsonb_build_object('city', c), timeout_milliseconds := 120000);
    end if;
  end if;
  if not tell then return jsonb_build_object('mode', p_mode, 'pending', pend, 'dealt', dealt); end if;
  update cards g set data = g.data || jsonb_build_object('drop_at', to_char(((g.data->>'drop_at')::timestamptz + interval '1 day') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'wx_held', coalesce((g.data->>'wx_held')::int, 0) + 1)
  where g.data->>'hold' = 'true' and g.data->>'pushed' is null and g.active and g.couple_id is not null and (g.data->>'drop_at')::timestamptz between now() - interval '6 hours' and now()
    and _io(g) = 'out' and coalesce((g.data->>'wx_held')::int, 0) < 4
    and _wx_bad(g.couple_id, (now() at time zone _zip_tz((select cp.settings->>'zip' from couples cp where cp.id = g.couple_id)))::date);
  -- the scratch card: one notice to both people when a held gem's moment arrives
  for r in select c.id, cp.code from cards c join couples cp on cp.id = c.couple_id where c.data->>'hold' = 'true' and c.data->>'pushed' is null and c.active
      and (c.data->>'drop_at')::timestamptz between now() - interval '6 hours' and now() loop
    update cards set data = data || '{"pushed":true}'::jsonb where id = r.id;
    perform net.http_post(url := u || 'nudge', timeout_milliseconds := 30000, headers := jsonb_build_object('Content-Type', 'application/json'), body := jsonb_build_object('code', r.code, 'member', '', 'kind', 'gem',
      'title', 'A hidden gem turned up', 'body', 'Scratch the card to see a place near you that most people walk past.', 'url', './?gem=1'));
    pushed := pushed + 1;
  end loop;
  -- before a trip: gems in that city, a few days ahead and never later than the day before when there is time
  for k in select * from couples where jsonb_array_length(coalesce(settings->'plans', '[]'::jsonb)) > 0 loop
    today := (now() at time zone _zip_tz(k.settings->>'zip'))::date;
    for c in select jsonb_array_elements_text(k.settings->'plans') loop
      m := k.settings->'plan_meta'->c; d1 := (m->>'from')::date;
      if d1 is not null and m->>'gems_pushed' is null and today between d1 - 3 and d1 and extract(hour from now() at time zone _zip_tz(k.settings->>'zip')) between 9 and 20 then
        select count(*) into n from cards where deck = 'trip' and couple_id is null and active and kind = c and data ? 'gem';
        if n > 0 then
          update couples set settings = jsonb_set(settings, array['plan_meta', c, 'gems_pushed'], 'true'::jsonb) where id = k.id;
          perform net.http_post(url := u || 'nudge', timeout_milliseconds := 30000, headers := jsonb_build_object('Content-Type', 'application/json'), body := jsonb_build_object('code', k.code, 'member', '', 'kind', 'gem',
            'title', 'Hidden gems in ' || c, 'body', n || ' places most visitors miss. Add any to your trip before you go.', 'url', './?tripplan=' || replace(c, ' ', '%20')));
          pushed := pushed + 1;
        end if;
      end if;
    end loop;
  end loop;
  for k in select * from couples where jsonb_array_length(coalesce(settings->'plans', '[]'::jsonb)) > 0 loop
    today := (now() at time zone _zip_tz(k.settings->>'zip'))::date;
    for c in select jsonb_array_elements_text(k.settings->'plans') loop
      m := k.settings->'plan_meta'->c;
      if m->>'from' is not null and m->>'to' is not null and today between (m->>'from')::date and (m->>'to')::date
         and coalesce(m->>'gem_day', '') <> today::text and extract(hour from now() at time zone _zip_tz(k.settings->>'zip')) between 9 and 12
         and exists (select 1 from cards where deck = 'trip' and couple_id is null and active and kind = c and (data ? 'gem' or data ? 'locals')) then
        update couples set settings = jsonb_set(settings, array['plan_meta', c, 'gem_day'], to_jsonb(today::text)) where id = k.id;
        perform net.http_post(url := u || 'nudge', timeout_milliseconds := 30000, headers := jsonb_build_object('Content-Type', 'application/json'), body := jsonb_build_object('code', k.code, 'member', '', 'kind', 'gem',
          'title', 'A hidden gem in ' || c, 'body', 'Scratch the card to see something near you that most visitors miss.', 'url', './?gem=1'));
        pushed := pushed + 1;
      end if;
    end loop;
  end loop;
  -- travel mode: gems around wherever a phone is for now, all kept for the morning scratch card
  for k in select * from couples where jsonb_typeof(settings->'away_now') = 'object' loop
    today := (now() at time zone _zip_tz(k.settings->>'zip'))::date;
    for r in select e.key mem, e.value aw from jsonb_each(k.settings->'away_now') e where (e.value->>'at')::timestamptz > now() - interval '36 hours' loop
      if pend = 0 then
        insert into cards (couple_id, deck, kind, title, subtitle, image, ext_id, event_date, created_by, data)
        select k.id, 'event', 'Hidden gem', left(g.title, 60), left(concat_ws(' · ', nullif(g.kind, ''), split_part(coalesce(g.address, ''), ',', 1)), 90), g.image, 'gem:' || g.pageid, '2099-01-01', 'gems',
          jsonb_strip_nulls(jsonb_build_object('gem', true, 'place', true, 'source', 'gem', 'away', r.aw->>'city', 'hold', true, 'notes', g.line, 'lat', g.lat, 'lng', g.lng,
            'miles', round(_miles((r.aw->>'lat')::double precision, (r.aw->>'lng')::double precision, g.lat, g.lng)::numeric, 1), 'hours', g.hours, 'hours_at', today, 'maps', g.maps, 'place_id', g.place_id, 'address', g.address, 'src', g.src, 'score', g.score))
        from gems g where g.keep and g.matched and g.image is not null and g.score >= 6 and _miles((r.aw->>'lat')::double precision, (r.aw->>'lng')::double precision, g.lat, g.lng) <= 15
        on conflict do nothing;
      end if;
      if coalesce(r.aw->>'gem_day', '') <> today::text and extract(hour from now() at time zone _zip_tz(k.settings->>'zip')) between 8 and 11
         and exists (select 1 from cards x where x.couple_id = k.id and x.data ? 'gem' and x.data->>'away' = r.aw->>'city' and not exists (select 1 from reveals rv where rv.couple_id = k.id and rv.member = r.mem and rv.card_id = x.id)) then
        update couples set settings = jsonb_set(settings, array['away_now', r.mem, 'gem_day'], to_jsonb(today::text)) where id = k.id;
        perform net.http_post(url := u || 'nudge', timeout_milliseconds := 30000, headers := jsonb_build_object('Content-Type', 'application/json'), body := jsonb_build_object('code', k.code,
          'member', coalesce((select name from members where couple_id = k.id and name <> r.mem limit 1), ''), 'kind', 'gem',
          'title', 'A hidden gem in ' || (r.aw->>'city'), 'body', 'Scratch the card to see something near you that most visitors miss.', 'url', './?gem=1'));
        pushed := pushed + 1;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('mode', p_mode, 'pending', pend, 'dealt', dealt, 'pushed', pushed);
end $function$;

revoke all on function public._gems_tick(text) from public, anon, authenticated;
select cron.unschedule('welike-gems-tick');
select cron.schedule('welike-gems-look', '20 3,12,17,22 * * *', $$select public._gems_tick('look')$$);     -- 10pm, 7am, 12pm, 5pm Eastern
select cron.schedule('welike-gems-night', '*/5 6-10 * * *', $$select public._gems_tick('night')$$);         -- every 5 min, 1am to 6am Eastern
select cron.schedule('welike-gems-notify', '7,22,37,52 * * * *', $$select public._gems_tick('notify')$$);   -- timed notices, every 15 min

-- 19 Nov 2026 (Dave: "we look for gems bi-weekly"), migration gems_biweekly_refresh on live:
-- at the top of the 'look' branch of _gems_tick, every area is looked at again after 14 days:
--   update gem_areas set status = 'new', tries = 0 where status in ('picked', 'empty') and done_at < now() - interval '14 days';
-- The gems pick stage skips pageids already in gems, so a re-look only makes an AI call when 5+ new Wikipedia places exist.
-- Same migration: the unique-spot push now says "Scratch the card to see an independent spot near you." (was "Wipe the window").
