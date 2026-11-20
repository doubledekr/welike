-- Tonight spin, Someday places, and group overlap (Dave, 19 Nov 2026). Beta and sim only for now: the live app never
-- calls these. Additive: two new tables, new functions, nothing existing changed.

-- ---------- Tonight: spin from what you both like ----------
create table if not exists spins (
  id uuid primary key default gen_random_uuid(), couple_id uuid not null references couples(id) on delete cascade,
  day date not null, kind text not null, by text not null, card uuid, pool uuid[] not null default '{}', history uuid[] not null default '{}',
  respins jsonb not null default '{}', ins jsonb not null default '{}', status text not null default 'open', session uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
alter table spins enable row level security;
create index if not exists spins_couple_day on spins (couple_id, day);

-- The pool: only things every one of you said yes to, that nobody has marked seen or never again, and that work tonight.
create or replace function _spin_pool(p_couple uuid, p_kind text) returns uuid[]
language sql stable security definer set search_path = public as $$
  with mc as (select greatest(count(*), 2) n from members where couple_id = p_couple),
  sv as (select coalesce(settings->'services', '[]'::jsonb) s from couples where id = p_couple),
  ok as (select l.card_id from _lv(p_couple) l group by l.card_id
         having count(*) filter (where l.verdict in ('yes', 'love')) >= (select n from mc) and count(*) filter (where l.verdict in ('seen', 'no')) = 0)
  select coalesce(array_agg(c.id), '{}') from ok join cards c on c.id = ok.card_id and c.active, sv
  where not _never(p_couple, c.id) and case p_kind
    when 'movie' then c.deck = 'movie' and (jsonb_array_length(sv.s) = 0 or jsonb_typeof(c.data->'services') <> 'array' or exists (select 1 from jsonb_array_elements_text(c.data->'services') x where sv.s ? x))
    when 'dinner' then c.deck = 'dinner' and c.kind <> 'cook' and (jsonb_typeof(c.data->'hours') not in ('array', 'string') or _open_ok(c.data->'hours', _today(), '19:00', 90))
    when 'out' then c.deck = 'event' and ((c.data ? 'place' and (jsonb_typeof(c.data->'hours') not in ('array', 'string') or _open_ok(c.data->'hours', _today(), '20:00', 60))) or c.event_date = _today())
    else false end;
$$;

create or replace function _spin_card(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'deck', deck, 'kind', kind, 'title', title, 'subtitle', subtitle, 'image', image, 'data', data, 'event_date', event_date) from cards where id = p_id;
$$;

create or replace function _spin_json(p_spin uuid, p_member text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', s.id, 'kind', s.kind, 'by', s.by, 'day', s.day, 'status', s.status, 'session', s.session,
    'card', _spin_card(s.card), 'left', cardinality(array(select unnest(s.pool) except select unnest(s.history))),
    'pool', cardinality(s.pool), 'respun', coalesce((s.respins->>p_member)::int, 0), 'respins', s.respins, 'ins', s.ins,
    'reel', (select coalesce(jsonb_agg(jsonb_build_object('title', c.title, 'image', c.image)), '[]') from (select unnest(s.pool) x limit 14) z join cards c on c.id = z.x))
  from spins s where s.id = p_spin;
$$;

create or replace function _spin_pick(p_spin uuid) returns uuid
language sql volatile security definer set search_path = public as $$
  select x from spins s, unnest(s.pool) x where s.id = p_spin and not (x = any(s.history)) order by random() limit 1;
$$;

create or replace function spin_start(p_code text, p_member text, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); s spins; pool uuid[]; pick uuid;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  if p_kind not in ('movie', 'dinner', 'out') then raise exception 'bad_kind'; end if;
  select * into s from spins where couple_id = v and day = _today() and kind = p_kind and status in ('open', 'challenge') order by created_at desc limit 1;
  if s.id is not null then return _spin_json(s.id, p_member); end if;
  pool := _spin_pool(v, p_kind);
  if cardinality(pool) < 2 then return jsonb_build_object('id', null, 'pool', cardinality(pool)); end if;
  pick := (select x from unnest(pool) x order by random() limit 1);
  insert into spins (couple_id, day, kind, by, card, pool, history, ins) values (v, _today(), p_kind, p_member, pick, pool, array[pick], jsonb_build_object(p_member, true)) returning * into s;
  return _spin_json(s.id, p_member);
end $$;

create or replace function spin_get(p_code text, p_member text, p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from spins s join members m on m.couple_id = s.couple_id and m.name = p_member where s.id = p_id and s.couple_id = _couple(p_code)) then _spin_json(p_id, p_member) end;
$$;

-- in: you're in on this one (it's on once everyone is in). respin: one each a night, shows a new one, and everyone is
-- asked again. challenge: a quick swipe round of five from the pool for everyone; the first one you all say yes to wins.
create or replace function spin_act(p_code text, p_member text, p_id uuid, p_act text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); s spins; n int; pick uuid; sid uuid; dk text;
begin
  select * into s from spins where id = p_id and couple_id = v for update;
  if s.id is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_spin'; end if;
  select count(*) into n from members where couple_id = v;
  if p_act = 'in' then
    update spins set ins = ins || jsonb_build_object(p_member, true), updated_at = now() where id = s.id returning * into s;
    if (select count(*) from jsonb_object_keys(s.ins)) >= n then update spins set status = 'on', updated_at = now() where id = s.id; end if;
  elsif p_act = 'respin' then
    if s.status = 'on' then raise exception 'decided'; end if;
    if coalesce((s.respins->>p_member)::int, 0) >= 1 then raise exception 'no_respins'; end if;
    pick := _spin_pick(s.id); if pick is null then raise exception 'pool_empty'; end if;
    update spins set card = pick, history = history || pick, ins = jsonb_build_object(p_member, true), status = 'open',
      respins = respins || jsonb_build_object(p_member, coalesce((respins->>p_member)::int, 0) + 1), updated_at = now() where id = s.id;
  elsif p_act = 'challenge' then
    if s.session is not null then return _spin_json(s.id, p_member); end if;
    dk := (select deck from cards where id = s.card);
    insert into sessions (couple_id, deck, from_member, note, filters) values (v, dk, p_member, 'Swipe challenge', jsonb_build_object('spin', s.id, 'matched', true, 'challenge', true)) returning id into sid;
    insert into session_cards (session_id, card_id, pos) select sid, x, row_number() over (order by x = s.card desc, random())
      from (select x from unnest(s.pool) x order by x = s.card desc, random() limit 5) z;
    update spins set status = 'challenge', session = sid, updated_at = now() where id = s.id;
  else raise exception 'bad_act'; end if;
  return _spin_json(s.id, p_member);
end $$;

-- ---------- Someday: places you'd love to go ----------
create table if not exists someday (couple_id uuid not null references couples(id) on delete cascade, member text not null, city text not null,
  created_at timestamptz not null default now(), primary key (couple_id, member, city));
alter table someday enable row level security;

-- A person's someday places: the ones they picked, plus any place where they liked two or more trip cards.
create or replace function _someday_mine(p_couple uuid, p_member text) returns setof text
language sql stable security definer set search_path = public as $$
  select city from someday where couple_id = p_couple and member = p_member
  union select c.kind from _lv(p_couple) l join cards c on c.id = l.card_id and c.deck = 'trip'
    where l.member = p_member and l.verdict in ('yes', 'love') group by c.kind having count(*) >= 2;
$$;

create or replace function someday_get(p_code text, p_member text) returns jsonb
language sql stable security definer set search_path = public as $$
  with v as (select _couple(p_code) id), ok as (select 1 from members, v where couple_id = v.id and name = p_member),
  ms as (select name from members, v where couple_id = v.id),
  mine as (select x city from v, _someday_mine(v.id, p_member) x),
  picked as (select city from someday, v where couple_id = v.id and member = p_member),
  both_ as (select m.city from mine m where (select count(*) from ms) >= 2 and not exists (select 1 from ms, v where ms.name <> p_member and not (m.city in (select _someday_mine(v.id, ms.name)))))
  select case when exists (select 1 from ok) then jsonb_build_object(
    'places', coalesce((select jsonb_agg(k order by k) from (select kind k from cards where deck = 'trip' and active and couple_id is null group by kind having count(*) >= 8) z), '[]'),
    'picked', coalesce((select jsonb_agg(city order by city) from picked), '[]'),
    'mine', coalesce((select jsonb_agg(city order by city) from mine), '[]'),
    'both', coalesce((select jsonb_agg(city order by city) from both_), '[]')) end;
$$;

create or replace function someday_set(p_code text, p_member text, p_city text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code);
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  if p_on then insert into someday (couple_id, member, city) values (v, p_member, left(p_city, 60)) on conflict do nothing;
  else delete from someday where couple_id = v and member = p_member and city = p_city; end if;
  return someday_get(p_code, p_member);
end $$;

-- A group's someday places: only where every person in it (and you) wants to go. Friends only; nothing about who
-- wants what is returned, just the places you all share.
create or replace function fr_someday(p_people uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); everyone uuid[]; cities text[]; p uuid; mine text[]; pr record;
begin
  if me is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  if exists (select 1 from unnest(p_people) x where x <> me and not exists (select 1 from fr_friends f where (f.a = me and f.b = x) or (f.b = me and f.a = x))) then
    return jsonb_build_object('ok', false, 'why', 'friends'); end if;
  everyone := array(select distinct x from unnest(p_people || me) x);
  foreach p in array everyone loop
    select * into pr from _fr_partner(p);
    if pr.cid is null then return jsonb_build_object('ok', true, 'cities', '[]'::jsonb, 'n', cardinality(everyone), 'missing', true); end if;
    mine := array(select _someday_mine(pr.cid, pr.myname));
    cities := case when cities is null then mine else array(select unnest(cities) intersect select unnest(mine)) end;
  end loop;
  return jsonb_build_object('ok', true, 'cities', coalesce(to_jsonb(array(select x from unnest(cities) x order by x)), '[]'::jsonb), 'n', cardinality(everyone));
end $$;

grant execute on function spin_start(text, text, text), spin_get(text, text, uuid), spin_act(text, text, uuid, text), someday_get(text, text), someday_set(text, text, text, boolean) to anon, authenticated;
grant execute on function fr_someday(uuid[]) to authenticated;
