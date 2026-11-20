-- Sparing hints (Dave, 19 Nov 2026): now and then, show one person something their partner (or a friend) liked that they
-- haven't, but only with a reason: it connects to two or more of their own likes (same cuisine, same kind of place, the
-- same genres, or around the corner from two places they liked). For a surprise: the person who liked it never sees that
-- anyone was shown it.
--   * partner: at most one a week per person; only likes at least 3 days old; never something you passed on or said
--     never again to, never something already matched or in a plan.
--   * friends: at most one a month per person, only friends who share matches (on by default now).
-- Also: "Match with friends" is on by default (Dave: a like-sharing app shares likes). People can still turn it off.
alter table fr_people alter column share set default true;
update fr_people set share = true where not share;

create table if not exists hints (id uuid primary key default gen_random_uuid(), couple_id uuid references couples(id) on delete cascade, member text,
  person uuid, friend uuid, about text not null, card uuid not null, why jsonb not null default '{}', status text not null default 'new', created_at timestamptz not null default now());
alter table hints enable row level security;
create index if not exists hints_member on hints (couple_id, member, created_at);
create index if not exists hints_person on hints (person, created_at);

-- how a card connects to someone's likes: the two best of their liked cards, and the reason
create or replace function _hint_why(p_card uuid, p_cid uuid, p_member text) returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (select * from cards where id = p_card),
  mine as (select m.* from _lv(p_cid) l join cards m on m.id = l.card_id and m.active where l.member = p_member and l.verdict in ('yes', 'love') and m.id <> p_card),
  hit as (select m.title, case
      when m.deck = 'dinner' and c.deck = 'dinner' and _cuisine(m.subtitle) is not null and _cuisine(m.subtitle) = _cuisine(c.subtitle) then 'like'
      when m.deck = 'event' and c.deck = 'event' and m.data ? 'place' and c.data ? 'place' and m.kind = c.kind and m.kind not in ('Bar', 'Shops') then 'like'
      when m.deck = 'movie' and c.deck = 'movie' and jsonb_typeof(m.data->'genres') = 'array' and jsonb_typeof(c.data->'genres') = 'array'
        and (select count(*) from jsonb_array_elements_text(m.data->'genres') g where c.data->'genres' ? g) >= 2 then 'like'
      when m.deck in ('dinner', 'event') and c.deck in ('dinner', 'event') and (m.data->>'lat') is not null and (c.data->>'lat') is not null
        and _miles((m.data->>'lat')::float8, (m.data->>'lng')::float8, (c.data->>'lat')::float8, (c.data->>'lng')::float8) <= 0.5 then 'near'
      end how from mine m, c)
  select case when count(*) filter (where how is not null) >= 2 then jsonb_build_object('how', (array_agg(how order by how = 'near') filter (where how is not null))[1],
    'titles', to_jsonb((array_agg(title order by how = 'near') filter (where how is not null))[1:2])) end from hit;
$$;

create or replace function _hint_text(p_who text, p_title text, p_why jsonb) returns text
language sql immutable as $$
  select p_who || ' liked ' || p_title || '. ' || case when p_why->>'how' = 'near' then 'It’s around the corner from ' else 'It’s a lot like ' end
    || (p_why->'titles'->>0) || ' and ' || (p_why->'titles'->>1) || ', which you liked.';
$$;

create or replace function hint_get(p_code text, p_member text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); h hints; p text; pick uuid; w jsonb;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then return null; end if;
  select * into h from hints where couple_id = v and member = p_member and created_at > now() - interval '7 days' order by created_at desc limit 1;
  if h.id is null then
    select name into p from members where couple_id = v and name <> p_member order by created_at limit 1;
    if p is null then return null; end if;
    select c.id, _hint_why(c.id, v, p_member) into pick, w from _lv(v) l join cards c on c.id = l.card_id and c.active
      where l.member = p and l.verdict in ('yes', 'love') and l.created_at < now() - interval '3 days' and c.deck in ('movie', 'dinner', 'event')
        and (c.deck <> 'event' or c.data ? 'place' or c.event_date >= _today())
        and not exists (select 1 from _lv(v) x where x.card_id = c.id and x.member = p_member)
        and not _never(v, c.id)
        and not exists (select 1 from plans pl where pl.couple_id = v and pl.items::text like '%' || c.id::text || '%')
        and not exists (select 1 from hints o where o.couple_id = v and o.card = c.id)
        and _hint_why(c.id, v, p_member) is not null
      order by random() limit 1;
    if pick is null then return null; end if;
    insert into hints (couple_id, member, about, card, why) values (v, p_member, p, pick, w) returning * into h;
  end if;
  if h.status <> 'new' then return null; end if;
  return jsonb_build_object('id', h.id, 'about', h.about, 'card', _spin_card(h.card), 'text', _hint_text(h.about, (select title from cards where id = h.card), h.why));
end $$;

create or replace function hint_act(p_code text, p_member text, p_id uuid, p_act text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code);
begin
  update hints set status = case when p_act = 'plan' then 'planned' else 'kept' end where id = p_id and couple_id = v and member = p_member;
  return jsonb_build_object('ok', found);
end $$;

-- a friend's like, once a month, with the same kind of reason. Signed-in check is auth.uid() (LTbeta: public._uid()).
create or replace function fr_hint() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); mp record; h hints; f record; pr record; pick uuid; w jsonb;
begin
  if me is null or not coalesce((select share from fr_people where id = me), false) then return null; end if;
  select * into mp from _fr_partner(me); if mp.cid is null then return null; end if;
  select * into h from hints where person = me and created_at > now() - interval '30 days' order by created_at desc limit 1;
  if h.id is null then
    for f in select p.id, p.name from fr_friends x join fr_people p on p.id = x.b where x.a = me and p.share order by random() loop
      select * into pr from _fr_partner(f.id); if pr.cid is null or pr.cid = mp.cid then continue; end if;
      select c.id, _hint_why(c.id, mp.cid, mp.myname) into pick, w from _lv(pr.cid) l join cards c on c.id = l.card_id and c.active
        where l.member = pr.myname and l.verdict in ('yes', 'love') and l.created_at < now() - interval '3 days' and c.deck in ('movie', 'dinner', 'event')
          and (c.deck <> 'event' or c.data ? 'place')
          and not exists (select 1 from _lv(mp.cid) x join cards y on y.id = x.card_id where x.member = mp.myname
            and (case when y.deck = 'movie' then y.id::text else coalesce(nullif(y.data->>'place_id', ''), lower(y.title)) end) = (case when c.deck = 'movie' then c.id::text else coalesce(nullif(c.data->>'place_id', ''), lower(c.title)) end))
          and _hint_why(c.id, mp.cid, mp.myname) is not null
        order by random() limit 1;
      if pick is not null then insert into hints (person, friend, about, card, why) values (me, f.id, f.name, pick, w) returning * into h; exit; end if;
    end loop;
    if h.id is null then return null; end if;
  end if;
  if h.status <> 'new' then return null; end if;
  return jsonb_build_object('id', h.id, 'about', h.about, 'friend', true, 'card', _spin_card(h.card), 'text', _hint_text(h.about, (select title from cards where id = h.card), h.why));
end $$;

create or replace function fr_hint_act(p_id uuid, p_act text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update hints set status = case when p_act = 'plan' then 'planned' else 'kept' end where id = p_id and person = auth.uid();
  return jsonb_build_object('ok', found);
end $$;

grant execute on function hint_get(text, text), hint_act(text, text, uuid, text) to anon, authenticated;
grant execute on function fr_hint(), fr_hint_act(uuid, text) to authenticated;
