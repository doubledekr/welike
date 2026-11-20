-- Tabs: Discover · Watch · Eat & Drink · Go Out · Trips (Dave, 19 Nov 2026, option 2).
--   Eat & Drink (p_deck 'dinner'): today's restaurants with a couple of bars between them, then food and drink finds.
--   Go Out (p_deck 'event', filters.goout): things to do (escape rooms, comedy, bowling, museums, events), never a
--     bar, never a food or drink find, never a hidden gem or one-of-a-kind spot (those stay Discover's), never a card
--     already in today's Discover pile. Half places to go, half what's on, alternating.
--   'drinks' still works for pages that haven't reloaded yet.
CREATE OR REPLACE FUNCTION public.start_bite(p_code text, p_member text, p_deck text, p_extra boolean, p_opts jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v uuid := _couple(p_code); sid uuid; d text := _today()::text; dk text := case when p_deck = 'drinks' then 'event' else p_deck end; dr boolean := p_deck = 'drinks';
  sh boolean := p_deck = 'movie' and coalesce((p_opts->>'series')::boolean, false); go boolean := p_deck = 'event'; mx int;
begin
  perform pg_advisory_xact_lock(hashtext(v::text || p_member || d || 'start_bite' || p_deck));
  if p_deck not in ('movie','dinner','event','drinks') then raise exception 'bad_deck'; end if;
  if not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_member'; end if;
  select id into sid from sessions where couple_id = v and from_member = p_member and deck = dk and filters->>'bite' = d and coalesce(filters->>'away', '') = ''
    and coalesce((filters->>'drinks')::boolean, false) = dr and coalesce((filters->>'series')::boolean, false) = sh
    and coalesce((filters->>'goout')::boolean, false) = go
    order by (select count(*) from swipes w where w.session_id = sessions.id) desc, created_at, id limit 1;
  if sid is null then
    insert into sessions (couple_id, deck, from_member, filters) values (v, dk, p_member, jsonb_build_object('solo', true, 'bite', d)
      || case when dr then '{"drinks":true,"types":["Bar","Night out"]}'::jsonb else '{}'::jsonb end
      || case when go then '{"goout":true,"notypes":["Bar"],"nolane":true}'::jsonb else '{}'::jsonb end
      || case when sh then '{"series":true}'::jsonb else '{}'::jsonb end) returning id into sid;
    perform _fill_session(sid, case when p_deck = 'dinner' then 3 when go then 5 else 10 end);
    if go then
      -- half places to go (escape rooms, comedy, bowling, arcades, museums, zoos), half what's on, alternating
      select coalesce(max(pos), 0) into mx from session_cards where session_id = sid;
      insert into session_cards (session_id, card_id, pos)
        select sid, q.id, mx + q.o from _pick(v, sid, 'event', jsonb_build_object('solo', true, 'bite', d, 'days', 10, 'nolane', true,
          'types', '["Night out","Games & fun","Bowling","Museum","Museums & sights","Gallery","Zoo","Garden","Aquarium"]'::jsonb), 5, p_member, true) with ordinality q(id, o)
        on conflict do nothing;
      update session_cards x set pos = r.np from (
        select sc.card_id, row_number() over (partition by c.data ? 'place' order by sc.pos) * 2 - case when c.data ? 'place' then 1 else 0 end np
        from session_cards sc join cards c on c.id = sc.card_id where sc.session_id = sid) r
        where x.session_id = sid and x.card_id = r.card_id;
    end if;
    if p_deck = 'dinner' then
      -- a couple of bars, one after each restaurant
      select coalesce(max(pos), 0) into mx from session_cards where session_id = sid;
      insert into session_cards (session_id, card_id, pos)
        select sid, q.id, mx + q.o from _pick(v, sid, 'event', jsonb_build_object('solo', true, 'bite', d, 'days', 10, 'types', '["Bar"]'::jsonb), 2, p_member, true) with ordinality q(id, o)
        on conflict do nothing;
      update session_cards x set pos = r.np from (
        select sc.card_id, row_number() over (partition by c.deck = 'dinner' order by sc.pos) * 2 - case when c.deck = 'dinner' then 1 else 0 end np
        from session_cards sc join cards c on c.id = sc.card_id where sc.session_id = sid) r
        where x.session_id = sid and x.card_id = r.card_id;
    end if;
    if p_deck in ('dinner', 'drinks', 'event') then
      delete from session_cards x where x.session_id = sid and x.card_id in (select oc.card_id from sessions m join session_cards oc on oc.session_id = m.id
        where m.couple_id = v and m.from_member = p_member and m.deck = 'mix' and m.filters->>'bite' = d);
    end if;
    if go then
      delete from session_cards x using cards c where x.session_id = sid and c.id = x.card_id and (c.data ? 'gem' or c.data ? 'unique');
    end if;
    if p_deck = 'dinner' then perform _lane_add(sid, 'eat'); perform _lane_add(sid, 'drinks');
    elsif dr then perform _lane_add(sid, 'drinks'); end if;
  elsif p_extra and not coalesce((select (filters->>'extra')::boolean from sessions where id = sid), false) then
    perform _fill_session(sid, case when p_deck = 'dinner' then 3 else 10 end);
    if go then delete from session_cards x using cards c where x.session_id = sid and c.id = x.card_id and (c.data ? 'gem' or c.data ? 'unique')
      and not exists (select 1 from swipes w where w.session_id = sid and w.card_id = x.card_id); end if;
    update sessions set filters = filters || '{"extra":true}'::jsonb where id = sid;
  end if;
  return jsonb_build_object('id', sid);
end $function$;
