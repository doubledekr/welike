-- Shows in Watch (19 Nov 2026). Held back on live: shows only reach a pile when the app asks for them
-- (the beta page /t and the sim pass {series: true}), and only reach an automatic plan for a couple with settings.shows = true.
-- Dave: "hold off on shows in live but put them in sim and push to live beta with friends".
--
-- A show is not a one-sitting thing like a movie, so plans treat it differently:
--   * a show stop lasts two episodes (data.minutes, set by watchmode-sync from the episode length; 60 when unknown)
--   * once a show you both liked has been in a night-in plan, later night-in plans offer it first as "Keep watching"
--     (why = 'keep'), for 30 days, instead of starting something new

-- the pile starters take options; the old two- and four-argument calls stay exactly as they were
create or replace function public.start_all(p_code text, p_member text, p_opts jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v uuid := _couple(p_code); sid uuid; d text := _today()::text; sh boolean := coalesce((p_opts->>'series')::boolean, false);
begin
  perform pg_advisory_xact_lock(hashtext(v::text || p_member || d || 'start_all'));
  if not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_member'; end if;
  select id into sid from sessions where couple_id = v and from_member = p_member and deck = 'mix' and filters->>'bite' = d and filters ? 'all'
    and coalesce((filters->>'series')::boolean, false) = sh order by created_at limit 1;
  if sid is null then
    insert into sessions (couple_id, deck, from_member, filters)
      values (v, 'mix', p_member, jsonb_build_object('solo', true, 'bite', d, 'all', true) || case when sh then '{"series":true}'::jsonb else '{}'::jsonb end) returning id into sid;
    perform _fill_all(sid);
  end if;
  return jsonb_build_object('id', sid);
end $$;
create or replace function public.start_all(p_code text, p_member text) returns jsonb language sql security definer set search_path to 'public' as $$
  select public.start_all(p_code, p_member, '{}'::jsonb) $$;

create or replace function public.start_bite(p_code text, p_member text, p_deck text, p_extra boolean, p_opts jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v uuid := _couple(p_code); sid uuid; d text := _today()::text; dk text := case when p_deck = 'drinks' then 'event' else p_deck end; dr boolean := p_deck = 'drinks';
  sh boolean := p_deck = 'movie' and coalesce((p_opts->>'series')::boolean, false);
begin
  perform pg_advisory_xact_lock(hashtext(v::text || p_member || d || 'start_bite' || p_deck));
  if p_deck not in ('movie','dinner','event','drinks') then raise exception 'bad_deck'; end if;
  if not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_member'; end if;
  select id into sid from sessions where couple_id = v and from_member = p_member and deck = dk and filters->>'bite' = d and coalesce(filters->>'away', '') = ''
    and coalesce((filters->>'drinks')::boolean, false) = dr and coalesce((filters->>'series')::boolean, false) = sh
    order by (select count(*) from swipes w where w.session_id = sessions.id) desc, created_at, id limit 1;
  if sid is null then
    insert into sessions (couple_id, deck, from_member, filters) values (v, dk, p_member, jsonb_build_object('solo', true, 'bite', d)
      || case when dr then '{"drinks":true,"types":["Bar","Night out"]}'::jsonb else '{}'::jsonb end
      || case when sh then '{"series":true}'::jsonb else '{}'::jsonb end) returning id into sid;
    perform _fill_session(sid, case when p_deck = 'dinner' then 3 else 10 end);
    if p_deck in ('dinner', 'drinks') then
      delete from session_cards x where x.session_id = sid and x.card_id in (select oc.card_id from sessions m join session_cards oc on oc.session_id = m.id
        where m.couple_id = v and m.from_member = p_member and m.deck = 'mix' and m.filters->>'bite' = d);
      perform _lane_add(sid, case when p_deck = 'dinner' then 'eat' else 'drinks' end);
    end if;
  elsif p_extra and not coalesce((select (filters->>'extra')::boolean from sessions where id = sid), false) then
    perform _fill_session(sid, case when p_deck = 'dinner' then 3 else 10 end);
    update sessions set filters = filters || '{"extra":true}'::jsonb where id = sid;
  end if;
  return jsonb_build_object('id', sid);
end $$;
create or replace function public.start_bite(p_code text, p_member text, p_deck text, p_extra boolean) returns jsonb language sql security definer set search_path to 'public' as $$
  select public.start_bite(p_code, p_member, p_deck, p_extra, '{}'::jsonb) $$;

do $$
declare d text; d2 text;
begin
  -- piles: a show only when the pile asked for shows
  d := pg_get_functiondef('public._pick(uuid,uuid,text,jsonb,integer,text,boolean)'::regprocedure);
  d2 := replace(d, $a$      and (p_deck <> 'movie' or coalesce(p_filters->>'actor', '') = ''$a$,
                   $a$      and (p_deck <> 'movie' or coalesce(c.data->>'type', '') <> 'series' or coalesce((p_filters->>'series')::boolean, false))
      and (p_deck <> 'movie' or coalesce(p_filters->>'actor', '') = ''$a$);
  if d2 = d then raise exception '_pick series anchor'; end if; d := d2;
  -- a pile that asks for shows gets about one in four (a handful of shows would otherwise drown among a thousand movies)
  d2 := replace(d, $a$(c.image is null and c.data ? 'photo') nophoto,$a$,
                   $a$(c.image is null and c.data ? 'photo') nophoto, row_number() over (partition by coalesce(c.data->>'type', '') = 'series' order by random()) srn, (c.data->>'type' = 'series') is_series,$a$);
  if d2 = d then raise exception '_pick series anchor 2'; end if; d := d2;
  d2 := replace(d, $a$  order by (case when p_deck = 'event' then event_date end),$a$,
                   $a$  order by (case when p_deck = 'event' then event_date end),
           (case when p_deck = 'movie' and coalesce((p_filters->>'series')::boolean, false) and is_series and srn <= greatest(1, p_n / 4) then 0 else 1 end),$a$);
  if d2 = d then raise exception '_pick series anchor 3'; end if;
  execute d2;
  -- automatic plans: shows only for couples with settings.shows; a show you both liked and already started comes first as "Keep watching"
  d := pg_get_functiondef('public._ap_pick'::regproc);
  d2 := replace(d, $a$        when 'movie' then c.deck = 'movie' and c.couple_id is null$a$,
                   $a$        when 'movie' then c.deck = 'movie' and c.couple_id is null
          and (coalesce(c.data->>'type', '') <> 'series' or coalesce((select (k2.settings->>'shows')::boolean from couples k2 where k2.id = p_couple), false))$a$);
  if d2 = d then raise exception '_ap_pick series anchor 1'; end if; d := d2;
  d2 := replace(d, $a$(fv.card_id is not null) is_fav,$a$,
                   $a$(fv.card_id is not null) is_fav,
      (c.data->>'type' = 'series' and exists (select 1 from plans pp, jsonb_array_elements(pp.items) px where pp.couple_id = p_couple and pp.day < p_day and pp.day > p_day - 30 and px->>'card' = c.id::text)) started,$a$);
  if d2 = d then raise exception '_ap_pick series anchor 2'; end if; d := d2;
  d2 := replace(d, $a$case when p_fav and c.is_fav then 1 when c.likes >= greatest(mc.n, 2) then 2$a$,
                   $a$case when c.started and c.likes >= greatest(mc.n, 2) then 1 when p_fav and c.is_fav then 1 when c.likes >= greatest(mc.n, 2) then 2$a$);
  if d2 = d then raise exception '_ap_pick series anchor 3'; end if; d := d2;
  d2 := replace(d, $a$case when p_fav and c.is_fav then 'fav' when c.likes >= greatest(mc.n, 2) then 'both'$a$,
                   $a$case when c.started and c.likes >= greatest(mc.n, 2) then 'keep' when p_fav and c.is_fav then 'fav' when c.likes >= greatest(mc.n, 2) then 'both'$a$);
  if d2 = d then raise exception '_ap_pick series anchor 4'; end if;
  execute d2;
end $$;

-- shows already in the catalog: two episodes long
update cards set data = data || jsonb_build_object('minutes', least(120, greatest(40, coalesce(nullif(data->>'runtime', '')::int, 30) * 2)))
where deck = 'movie' and couple_id is null and data->>'type' = 'series' and not (data ? 'minutes');
