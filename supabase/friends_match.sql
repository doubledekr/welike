-- Planning helper, second version: finds matched to what the group agreed on, each with a written reason.
-- Applied to the live project as migration friends_plan_match (18 Nov 2026). Beta only: nothing here is read by the live app.
--
-- Privacy, by construction:
--   * The only taste signal is _fr_agreed: cards that show in the plan as "Everyone's in" (two or more people, all yes) or
--     "Most are in" (three or more people, more than half yes). Every member already sees those lists.
--   * Nothing here reads who said yes, and nothing reads a pass. One person's yes never counts for anything.
--   * Ideas people typed are left out; only real cards are used.
--   * The reason is put together here, not by the AI. The AI supplies a short phrase about the find (checked against the
--     find's own description before it gets here) and which agreed cards it resembles; this function re-checks that those
--     cards are still agreed and writes the sentence.

alter table fr_finds add column if not exists why text;
alter table fr_plans add column if not exists matched_at timestamptz;

create or replace function _fr_agreed(p_plan uuid) returns table(card uuid, allin boolean)
language sql stable security definer set search_path to 'public' as $$
  with n as (select count(*)::int n from fr_plan_members where plan = p_plan and status = 'in'),
  y as (select s.card, (count(*) filter (where s.yes))::int yes from fr_swipes s
        join fr_plan_members m on m.plan = s.plan and m.person = s.person and m.status = 'in' where s.plan = p_plan group by s.card)
  select y.card, y.yes = n.n from y cross join n
  where ((n.n >= 2 and y.yes = n.n) or (n.n >= 3 and y.yes * 2 > n.n)) and exists (select 1 from cards c where c.id = y.card);
$$;

create or replace function _fr_has_taste(p_plan uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$ select (select count(*) from _fr_agreed(p_plan)) >= 2; $$;

-- is a matched find due? (a trip with its place set, enough agreed cards, room for a find, and not tried in the last six hours)
create or replace function _fr_match_due(p_plan uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from fr_plans p where p.id = p_plan and p.flow = 'trip' and p.city is not null
      and (p.matched_at is null or p.matched_at < now() - interval '6 hours'))
    and (select count(*) from fr_finds where plan = p_plan and status = 'new') < 2
    and _fr_has_taste(p_plan);
$$;

-- the first version's pick, kept as the fallback: a hidden gem, or the best-rated thing not yet in the pile
create or replace function _fr_scout_pick(p_plan uuid) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare pl fr_plans; c cards; fid uuid;
begin
  select * into pl from fr_plans where id = p_plan;
  if pl.city is null or (select count(*) from fr_finds where plan = p_plan and status = 'new') >= 2 then return null; end if;
  select * into c from cards x where x.deck = 'trip' and x.kind = pl.city and x.active and x.couple_id is null and not x.id = any(pl.deck)
      and not exists (select 1 from fr_finds f where f.plan = p_plan and f.card = x.id)
    order by (x.data ? 'gem') desc, case when x.data->>'score' ~ '^\d+$' then (x.data->>'score')::int end desc nulls last,
      case when x.data->>'rating' ~ '^[0-9]+(\.[0-9]+)?$' then (x.data->>'rating')::numeric end desc nulls last limit 1;
  if c.id is null then return null; end if;
  insert into fr_finds(plan, kind, title, body, card) values (p_plan, case when c.data ? 'gem' then 'gem' else 'pick' end, c.title, coalesce(nullif(c.data->>'notes', ''), c.subtitle), c.id) returning id into fid;
  return fid;
end $$;

-- what the matcher is given: the agreed cards and the candidates, as plain descriptions. No people, no counts, no passes.
create or replace function _fr_match_brief(p_plan uuid, p_uid uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare pl fr_plans;
begin
  if not exists (select 1 from fr_plan_members where plan = p_plan and person = p_uid and status = 'in') then return jsonb_build_object('ok', false, 'why', 'gone'); end if;
  if not _fr_match_due(p_plan) then return jsonb_build_object('ok', false, 'why', 'not_due'); end if;
  update fr_plans set matched_at = now() where id = p_plan and (matched_at is null or matched_at < now() - interval '6 hours') returning * into pl;
  if pl.id is null then return jsonb_build_object('ok', false, 'why', 'not_due'); end if;
  return jsonb_build_object('ok', true, 'city', pl.city,
    'liked', (select jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'type', nullif(trim(split_part(c.subtitle, '·', 2)), ''), 'about', nullif(c.data->>'notes', '')) order by a.allin desc, c.title)
      from (select * from _fr_agreed(p_plan) order by allin desc limit 12) a join cards c on c.id = a.card),
    'cands', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'type', nullif(trim(split_part(x.subtitle, '·', 2)), ''), 'about', nullif(x.data->>'notes', '')))
      from (select c.* from cards c where c.deck = 'trip' and c.kind = pl.city and c.active and c.couple_id is null and not c.id = any(pl.deck)
          and not exists (select 1 from fr_finds f where f.plan = p_plan and f.card = c.id)
        order by (c.data ? 'gem') desc, case when c.data->>'score' ~ '^\d+$' then (c.data->>'score')::int end desc nulls last,
          case when c.data->>'rating' ~ '^[0-9]+(\.[0-9]+)?$' then (c.data->>'rating')::numeric end desc nulls last limit 24) x), '[]'::jsonb));
end $$;

-- save a matched find. With no usable match it falls back to the first version's pick, with no reason shown.
create or replace function _fr_match_save(p_plan uuid, p_card uuid, p_link text, p_like uuid[]) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare pl fr_plans; c cards; names text[]; allin boolean; lk text; why text; fid uuid;
begin
  select * into pl from fr_plans where id = p_plan;
  if pl.id is null or pl.city is null or (select count(*) from fr_finds where plan = p_plan and status = 'new') >= 2 then return jsonb_build_object('ok', true, 'added', false); end if;
  lk := trim(regexp_replace(coalesce(p_link, ''), '[\s.,;:!]+$', ''));
  if p_card is not null and lk <> '' and length(lk) <= 80 and lk !~ '[\n\r"]' then
    select * into c from cards x where x.id = p_card and x.deck = 'trip' and x.kind = pl.city and x.active and x.couple_id is null and not x.id = any(pl.deck)
      and not exists (select 1 from fr_finds f where f.plan = p_plan and f.card = x.id);
    -- the cards it is said to resemble must be agreed right now
    select array_agg(k.title order by k.ord), bool_and(k.allin) into names, allin from (
      select cc.title, a.allin, u.ord from unnest(p_like[1:2]) with ordinality u(id, ord) join _fr_agreed(p_plan) a on a.card = u.id join cards cc on cc.id = u.id) k;
    if c.id is not null and coalesce(array_length(names, 1), 0) >= 1 and coalesce(array_length(names, 1), 0) = least(coalesce(array_length(p_like, 1), 0), 2) then
      why := format('%s, like %s, which %s said yes to.', upper(left(lk, 1)) || substr(lk, 2), array_to_string(names, ' and '), case when allin then 'everyone' else 'most of you' end);
      insert into fr_finds(plan, kind, title, body, card, why) values (p_plan, 'match', c.title, coalesce(nullif(c.data->>'notes', ''), c.subtitle), c.id, why) returning id into fid;
      return jsonb_build_object('ok', true, 'added', true, 'matched', true, 'id', fid, 'why', why);
    end if;
  end if;
  fid := _fr_scout_pick(p_plan);
  return jsonb_build_object('ok', true, 'added', fid is not null, 'matched', false, 'id', fid);
end $$;

revoke all on function _fr_agreed(uuid), _fr_has_taste(uuid), _fr_match_due(uuid), _fr_scout_pick(uuid), _fr_match_brief(uuid, uuid), _fr_match_save(uuid, uuid, text, uuid[]) from public, anon, authenticated;
grant execute on function _fr_agreed(uuid), _fr_has_taste(uuid), _fr_match_due(uuid), _fr_scout_pick(uuid), _fr_match_brief(uuid, uuid), _fr_match_save(uuid, uuid, text, uuid[]) to service_role;

-- Two small edits to beta-only functions, made in place so the rest of each stays exactly as it was:
--   _fr_scout: once a group has agreed on two or more cards, the plain pick steps aside for the matcher.
--   _fr_plan_json: each find carries its reason, and the plan says whether a matched find is due.
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('_fr_scout(uuid)'::regprocedure);
  if position('_fr_has_taste' in d) = 0 then
    n := replace(d, E'  if pl.city is not null then\n    select * into c from cards x', E'  if pl.city is not null and not _fr_has_taste(p_plan) then\n    select * into c from cards x');
    if n = d then raise exception '_fr_scout: the line to change was not found'; end if;
    execute n;
  end if;
  d := pg_get_functiondef('_fr_plan_json(uuid, uuid)'::regprocedure);
  if position('match_due' in d) = 0 then
    n := replace(d, $a$'status', f.status, 'card', f.card,$a$, $a$'status', f.status, 'card', f.card, 'why', f.why,$a$);
    if n = d then raise exception '_fr_plan_json: finds line not found'; end if;
    d := n;
    n := replace(d, $a$    'swiped', (select count(distinct s.person)$a$, $a$    'match_due', _fr_match_due(p_plan),
    'swiped', (select count(distinct s.person)$a$);
    if n = d then raise exception '_fr_plan_json: swiped line not found'; end if;
    execute n;
  end if;
end $$;

-- Follow-ups applied the same evening (migrations friends_plan_match_tidy and friends_plan_match_plain_reason). The live
-- text of _fr_match_brief and _fr_match_save is the source of truth; in short:
--   * _fr_card_type(subtitle): the words after the dot in a card's subtitle, unless that is a price ("from $35"). The
--     brief uses it for each card's type.
--   * _fr_short_title(title): a long title is named by its part before the colon in a reason.
--   * _fr_match_save: a matched find with no usable phrase still gets a true reason,
--     "Fits with A and B, which everyone said yes to."
create or replace function _fr_card_type(p_sub text) returns text language sql immutable set search_path to 'public' as $$
  select case when t = '' or t ~ '[$€£0-9]' then null else t end from (select trim(split_part(coalesce(p_sub, ''), '·', 2)) t) x;
$$;
create or replace function _fr_short_title(p text) returns text language sql immutable set search_path to 'public' as $$
  select case when length(p) > 36 and length(trim(split_part(p, ':', 1))) between 8 and 36 then trim(split_part(p, ':', 1)) else p end;
$$;

-- 18 Nov 2026, later (migration friends_plan_match_live_reason): a matched find's reason is worked out each time the
-- plan loads, from the cards that are agreed right then, so it cannot go stale when someone joins, leaves or swipes later.
--   * fr_finds.link (the phrase) and fr_finds.likes (the one or two agreed cards it resembles) are stored with the find.
--   * _fr_find_why(plan, link, likes) writes the sentence from whichever of those cards are still agreed: "everyone" only
--     if all of them are unanimous now, otherwise "most of you". If none is still agreed, no reason is shown.
--   * _fr_match_save stores link and likes; _fr_plan_json calls _fr_find_why for finds that have likes.
alter table fr_finds add column if not exists link text;
alter table fr_finds add column if not exists likes uuid[];
create or replace function _fr_find_why(p_plan uuid, p_link text, p_likes uuid[]) returns text
language sql stable security definer set search_path to 'public' as $$
  select case when count(*) = 0 then null
    when coalesce(p_link, '') <> '' then format('%s, like %s, which %s said yes to.', upper(left(p_link, 1)) || substr(p_link, 2), string_agg(_fr_short_title(k.title), ' and ' order by k.ord), case when bool_and(k.allin) then 'everyone' else 'most of you' end)
    else format('Fits with %s, which %s said yes to.', string_agg(_fr_short_title(k.title), ' and ' order by k.ord), case when bool_and(k.allin) then 'everyone' else 'most of you' end) end
  from (select cc.title, a.allin, u.ord from unnest(p_likes[1:2]) with ordinality u(id, ord) join _fr_agreed(p_plan) a on a.card = u.id join cards cc on cc.id = u.id) k;
$$;
