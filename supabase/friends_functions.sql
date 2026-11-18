-- Friends, private groups and group plans: the functions as applied to the Let's Together project (18 Nov 2026).
create or replace function _fr_partner(p_uid uuid) returns table(pname text, puid uuid, code text, myname text, cid uuid)
language sql stable security definer set search_path = public as $$
  select o.name, o.user_id, c.code, m.name, m.couple_id from members m join couples c on c.id = m.couple_id
  left join lateral (select x.name, x.user_id from members x where x.couple_id = m.couple_id and x.name <> m.name order by x.created_at limit 1) o on true
  where m.user_id = p_uid order by m.created_at limit 1;
$$;

create or replace function _fr_ensure(p_uid uuid, p_name text) returns fr_people
language plpgsql security definer set search_path = public as $$
declare me fr_people; c text;
begin
  select * into me from fr_people where id = p_uid;
  if found then return me; end if;
  loop
    c := upper(substr(translate(encode(extensions.gen_random_bytes(9), 'base64'), '+/=0O1Iloi', ''), 1, 6));
    exit when length(c) = 6 and not exists (select 1 from fr_people where code = c);
  end loop;
  insert into fr_people(id, name, code) values (p_uid, left(trim(p_name), 24), c) on conflict (id) do nothing;
  select * into me from fr_people where id = p_uid;
  return me;
end $$;

create or replace function _fr_stage(p_plan uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when pl.flow = 'hub' then 'hub'
    when pl.flow = 'trip' then case
      when pl.day_from is null then 'weekend'
      when pl.city is null then 'city'
      when pl.data->'stay' is null then 'stay'
      else 'go' end
    when pl.data->'pick' is not null then 'decided'
    when exists (select 1 from fr_polls q where q.plan = pl.id and q.kind = 'pick' and q.state <> 'done') then 'vote'
    else 'swipe' end
  from fr_plans pl where pl.id = p_plan;
$$;

create or replace function _fr_plan_brief(p_plan uuid, p_uid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', pl.id, 'kind', pl.kind, 'flow', pl.flow, 'title', pl.title, 'city', pl.city, 'day', pl.day_from, 'parent', pl.parent,
    'owner', pl.owner = p_uid, 'stage', _fr_stage(pl.id),
    'n', (select count(*) from fr_plan_members m where m.plan = pl.id and m.status = 'in'),
    'status', me.status, 'role', me.role,
    'todo', me.status = 'invited'
      or exists (select 1 from fr_polls q where q.plan = pl.id and q.state in ('open', 'runoff') and not exists (select 1 from fr_votes v where v.poll = q.id and v.person = p_uid and v.round = q.round))
      or (cardinality(pl.deck) > 0 and pl.data->'pick' is null and not exists (select 1 from fr_swipes s where s.plan = pl.id and s.person = p_uid)))
  from fr_plans pl join fr_plan_members me on me.plan = pl.id and me.person = p_uid where pl.id = p_plan;
$$;

create or replace function _fr_wk_tally(p_poll uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(o->>'id', jsonb_build_object(
    'can', (select count(*) from fr_votes v where v.poll = q.id and v.v->>(o->>'id') = 'can'),
    'maybe', (select count(*) from fr_votes v where v.poll = q.id and v.v->>(o->>'id') = 'maybe'),
    'cant', (select count(*) from fr_votes v where v.poll = q.id and v.v->>(o->>'id') = 'cant'))), '{}'::jsonb)
  from fr_polls q, jsonb_array_elements(q.options) o where q.id = p_poll;
$$;

create or replace function _fr_deck_city(p_city text) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array(select id from cards where deck = 'trip' and kind = p_city and active
    order by case when data->>'rating' ~ '^[0-9]+(\.[0-9]+)?$' then (data->>'rating')::numeric end desc nulls last, created_at limit 30), '{}');
$$;

create or replace function _fr_deck_local(p_uid uuid, p_kind text) returns uuid[]
language sql volatile security definer set search_path = public as $$
  select coalesce(array(select c.id from cards c where c.active and c.couple_id = (select cid from _fr_partner(p_uid))
      and ((p_kind in ('dinner', 'double') and c.deck = 'dinner' and c.kind = 'restaurant')
        or (p_kind in ('night', 'double', 'bach') and c.deck = 'event' and c.kind in ('Bar', 'Night out', 'Games & fun')))
    order by (c.image is null), random() limit 24), '{}');
$$;

create or replace function _fr_apply(p_poll uuid, p_win text, p_tally jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare q fr_polls; opt jsonb;
begin
  select * into q from fr_polls where id = p_poll;
  select o into opt from jsonb_array_elements(q.options) o where o->>'id' = p_win limit 1;
  update fr_polls set state = 'done', result = p_win, tally = coalesce(p_tally, tally) where id = p_poll;
  if q.kind = 'weekend' then update fr_plans set day_from = p_win::date where id = q.plan;
  elsif q.kind = 'city' then
    update fr_plans set city = opt->>'label', deck = _fr_deck_city(opt->>'label') where id = q.plan;
    if not exists (select 1 from fr_polls where plan = q.plan and kind = 'stay') then insert into fr_polls(plan, kind, state) values (q.plan, 'stay', 'collect'); end if;
  elsif q.kind = 'stay' then update fr_plans set data = data || jsonb_build_object('stay', opt) where id = q.plan;
  elsif q.kind = 'pick' then update fr_plans set data = data || jsonb_build_object('pick', opt) where id = q.plan;
  end if;
end $$;

create or replace function _fr_tally(p_poll uuid, p_force boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare q fr_polls; n int; nv int; win text; ids text[]; ps numeric[]; tl jsonb;
begin
  select * into q from fr_polls where id = p_poll for update;
  if q.state not in ('open', 'runoff') then return; end if;
  select count(*) into n from fr_plan_members where plan = q.plan and status = 'in';
  select count(*) into nv from fr_votes v join fr_plan_members m on m.plan = q.plan and m.person = v.person and m.status = 'in' where v.poll = q.id and v.round = q.round;
  if nv = 0 or (not p_force and nv < n) then return; end if;
  if q.kind = 'weekend' then
    select o->>'id' into win from jsonb_array_elements(q.options) with ordinality t(o, i)
      left join lateral (select count(*) filter (where v.v->>(o->>'id') = 'cant') cant,
        coalesce(sum(case v.v->>(o->>'id') when 'can' then 2 when 'maybe' then 1 else 0 end), 0) sc from fr_votes v where v.poll = q.id) s on true
      order by s.cant, s.sc desc, i limit 1;
    perform _fr_apply(q.id, win, _fr_wk_tally(q.id)); return;
  end if;
  if q.state = 'runoff' then
    select o into win from jsonb_array_elements_text(q.runoff) with ordinality t(o, i)
      left join lateral (select count(*) c from fr_votes v where v.poll = q.id and v.round = 2 and v.v #>> '{}' = o) s on true
      order by s.c desc, i limit 1;
    perform _fr_apply(q.id, win); return;
  end if;
  select array_agg(id order by pts desc, firsts desc, i), array_agg(pts order by pts desc, firsts desc, i), jsonb_object_agg(id, pts) into ids, ps, tl from (
    select o->>'id' id, i,
      coalesce((select sum(4 - r.pos) from fr_votes fv, jsonb_array_elements_text(fv.v) with ordinality r(val, pos) where fv.poll = q.id and fv.round = 1 and r.val = o->>'id' and r.pos <= 3), 0) pts,
      (select count(*) from fr_votes fv where fv.poll = q.id and fv.round = 1 and fv.v->>0 = o->>'id') firsts
    from jsonb_array_elements(q.options) with ordinality t(o, i)) z;
  if array_length(ids, 1) >= 3 and nv >= 2 and ps[1] - ps[2] <= 1 then
    update fr_polls set state = 'runoff', round = 2, runoff = jsonb_build_array(ids[1], ids[2]), tally = tl where id = q.id; return;
  end if;
  perform _fr_apply(q.id, ids[1], tl);
end $$;

create or replace function _fr_plan_json(p_plan uuid, p_uid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pl fr_plans; n int; cp record; res jsonb;
begin
  select * into pl from fr_plans where id = p_plan;
  select count(*) into n from fr_plan_members where plan = p_plan and status = 'in';
  select * into cp from _fr_partner(p_uid);
  res := _fr_plan_brief(p_plan, p_uid) || jsonb_build_object('ok', true, 'at', pl.at_time, 'data', pl.data,
    'surprise', (select name from fr_people where id = pl.surprise_for),
    'members', (select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', m.role, 'status', m.status, 'me', p.id = p_uid, 'host', p.id = pl.owner,
        'arrive_at', m.arrive_at, 'arrive_how', m.arrive_how, 'booked', m.booked, 'mine', m.via = p_uid) order by (p.id <> pl.owner), m.created_at, lower(p.name))
      from fr_plan_members m join fr_people p on p.id = m.person where m.plan = p_plan and m.status <> 'out'),
    'polls', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'state', q.state, 'round', q.round, 'options', q.options, 'runoff', q.runoff, 'result', q.result,
        'tally', case when q.kind = 'weekend' then _fr_wk_tally(q.id) when q.state = 'done' then q.tally end,
        'mine', (select v.v from fr_votes v where v.poll = q.id and v.person = p_uid and v.round = q.round),
        'voted', (select count(*) from fr_votes v join fr_plan_members m on m.plan = q.plan and m.person = v.person and m.status = 'in' where v.poll = q.id and v.round = q.round)) order by q.created_at)
      from fr_polls q where q.plan = p_plan), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(x.j order by x.o) from (
        select jsonb_build_object('id', c.id, 'title', c.title, 'sub', c.subtitle, 'img', c.image, 'kind', case when c.deck = 'trip' then 'Do' when c.deck = 'dinner' then 'Eat' when c.kind = 'Bar' then 'Drink' else 'Do' end,
          'url', c.data->>'url', 'mine', (select s.yes from fr_swipes s where s.plan = p_plan and s.card = c.id and s.person = p_uid)) j, array_position(pl.deck, c.id) o
        from cards c where c.id = any(pl.deck)
        union all
        select jsonb_build_object('id', i.id, 'title', i.title, 'sub', 'Idea from ' || (select name from fr_people where id = i.by), 'kind', 'Idea',
          'mine', (select s.yes from fr_swipes s where s.plan = p_plan and s.card = i.id and s.person = p_uid)), 1000 + (row_number() over (order by i.created_at))::int
        from fr_ideas i where i.plan = p_plan) x), '[]'::jsonb),
    'swiped', (select count(distinct s.person) from fr_swipes s join fr_plan_members m on m.plan = s.plan and m.person = s.person and m.status = 'in' where s.plan = p_plan),
    'allin', coalesce((select jsonb_agg(y.card) from (select s.card, count(*) filter (where s.yes) yes from fr_swipes s join fr_plan_members m on m.plan = s.plan and m.person = s.person and m.status = 'in' where s.plan = p_plan group by s.card) y where n >= 2 and y.yes = n), '[]'::jsonb),
    'most', coalesce((select jsonb_agg(jsonb_build_object('id', y.card, 'yes', y.yes) order by y.yes desc) from (select s.card, count(*) filter (where s.yes) yes from fr_swipes s join fr_plan_members m on m.plan = s.plan and m.person = s.person and m.status = 'in' where s.plan = p_plan group by s.card) y where n >= 3 and y.yes * 2 > n and y.yes < n), '[]'::jsonb),
    'kids', coalesce((select jsonb_agg(_fr_plan_brief(k.id, p_uid) order by k.day_from nulls last, k.created_at) from fr_plans k join fr_plan_members km on km.plan = k.id and km.person = p_uid and km.status <> 'out' where k.parent = p_plan), '[]'::jsonb),
    'up', (select jsonb_build_object('id', u.id, 'title', u.title) from fr_plans u join fr_plan_members um on um.plan = u.id and um.person = p_uid and um.status <> 'out' where u.id = pl.parent),
    'partner', case when cp.code is null or cp.pname is null then null else jsonb_build_object('name', cp.pname, 'has', cp.puid is not null,
        'in', cp.puid is not null and exists (select 1 from fr_plan_members m where m.plan = p_plan and m.person = cp.puid and m.status <> 'out')) end);
  return res;
end $$;

create or replace function fr_me(p_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); me fr_people; nm text := nullif(left(trim(coalesce(p_name, '')), 24), ''); cp record;
begin
  if uid is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  select * into me from fr_people where id = uid;
  if not found then
    if nm is null then return jsonb_build_object('ok', false, 'why', 'name', 'hint', (select m.name from members m where m.user_id = uid order by m.created_at limit 1)); end if;
    me := _fr_ensure(uid, nm);
  elsif nm is not null and nm <> me.name then update fr_people set name = nm where id = uid returning * into me;
  end if;
  select * into cp from _fr_partner(uid);
  return jsonb_build_object('ok', true, 'me', jsonb_build_object('id', me.id, 'name', me.name, 'code', me.code),
    'couple', case when cp.code is null then null else jsonb_build_object('code', cp.code, 'name', cp.myname, 'partner', cp.pname, 'partner_in', cp.puid is not null) end,
    'friends', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by lower(p.name)) from fr_friends f join fr_people p on p.id = f.b where f.a = uid), '[]'::jsonb),
    'groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'members', to_jsonb(g.members)) order by g.created_at) from fr_groups g where g.owner = uid), '[]'::jsonb),
    'plans', coalesce((select jsonb_agg(_fr_plan_brief(pl.id, uid) order by pl.created_at desc) from fr_plans pl join fr_plan_members pm on pm.plan = pl.id and pm.person = uid and pm.status <> 'out'), '[]'::jsonb));
end $$;

create or replace function fr_add(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); f fr_people;
begin
  if uid is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  if not exists (select 1 from fr_people where id = uid) then return jsonb_build_object('ok', false, 'why', 'name'); end if;
  select * into f from fr_people where code = upper(trim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('ok', false, 'why', 'nocode'); end if;
  if f.id = uid then return jsonb_build_object('ok', false, 'why', 'self'); end if;
  insert into fr_friends(a, b) values (uid, f.id), (f.id, uid) on conflict do nothing;
  return jsonb_build_object('ok', true, 'name', f.name, 'id', f.id);
end $$;

create or replace function fr_unfriend(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  delete from fr_friends where (a = uid and b = p_id) or (a = p_id and b = uid);
  update fr_groups set members = array_remove(members, p_id) where owner = uid;
  return jsonb_build_object('ok', true);
end $$;

create or replace function fr_group_save(p_id uuid, p_name text, p_members uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := nullif(left(trim(coalesce(p_name, '')), 30), ''); ms uuid[];
begin
  if uid is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  if p_id is not null and nm is null then delete from fr_groups where id = p_id and owner = uid; return jsonb_build_object('ok', true); end if;
  if nm is null then return jsonb_build_object('ok', false, 'why', 'name'); end if;
  ms := coalesce(array(select f.b from fr_friends f where f.a = uid and f.b = any(coalesce(p_members, '{}'))), '{}');
  if p_id is null then
    if (select count(*) from fr_groups where owner = uid) >= 20 then return jsonb_build_object('ok', false, 'why', 'max'); end if;
    insert into fr_groups(owner, name, members) values (uid, nm, ms);
  else update fr_groups set name = nm, members = ms where id = p_id and owner = uid;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function fr_cities() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then '[]'::jsonb else coalesce((select jsonb_agg(k order by k) from (select kind k from cards where deck = 'trip' and active and couple_id is null group by kind having count(*) >= 8) z), '[]'::jsonb) end;
$$;

create or replace function fr_plan_new(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); kind text := p->>'kind'; ttl text := nullif(left(trim(coalesce(p->>'title', '')), 60), ''); flow text; pid uuid; par fr_plans;
  inv uuid[]; x uuid; cp record; cities text[]; wks text[]; sf uuid := nullif(p->>'surprise_for', '')::uuid; okc jsonb := fr_cities(); pp fr_people;
begin
  if uid is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  if not exists (select 1 from fr_people where id = uid) then return jsonb_build_object('ok', false, 'why', 'name'); end if;
  if kind is null or kind not in ('trip', 'double', 'dinner', 'bach', 'night', 'wedding') or ttl is null then return jsonb_build_object('ok', false, 'why', 'bad'); end if;
  if (select count(*) from fr_plans where owner = uid) >= 40 then return jsonb_build_object('ok', false, 'why', 'max'); end if;
  cities := coalesce(array(select distinct c from jsonb_array_elements_text(coalesce(p->'cities', '[]'::jsonb)) c where okc ? c limit 5), '{}');
  wks := coalesce(array(select distinct d from jsonb_array_elements_text(coalesce(p->'weekends', '[]'::jsonb)) d where d ~ '^\d{4}-\d\d-\d\d$' and d::date >= current_date order by d limit 6), '{}');
  flow := case when kind = 'wedding' then 'hub' when kind = 'trip' or (kind = 'bach' and cardinality(cities) > 0) then 'trip' else 'pick' end;
  if flow = 'trip' and (cardinality(cities) = 0 or cardinality(wks) = 0) then return jsonb_build_object('ok', false, 'why', 'trip'); end if;
  if p->>'parent' is not null then
    select * into par from fr_plans where id = (p->>'parent')::uuid;
    if not found or not exists (select 1 from fr_plan_members where plan = par.id and person = uid and status = 'in') then return jsonb_build_object('ok', false, 'why', 'parent'); end if;
  end if;
  -- invitees: my friends, or people already in the parent plan
  inv := coalesce(array(select distinct i::uuid from jsonb_array_elements_text(coalesce(p->'invite', '[]'::jsonb)) i
    where i::uuid <> uid and (exists (select 1 from fr_friends f where f.a = uid and f.b = i::uuid) or (par.id is not null and exists (select 1 from fr_plan_members m where m.plan = par.id and m.person = i::uuid and m.status <> 'out')))), '{}');
  if sf is not null then inv := array_remove(inv, sf); if sf = uid then sf := null; end if; end if;
  insert into fr_plans(owner, kind, flow, title, parent, surprise_for, day_from, at_time)
    values (uid, kind, flow, ttl, par.id, sf, case when flow <> 'trip' and p->>'day' ~ '^\d{4}-\d\d-\d\d$' then (p->>'day')::date end, nullif(left(coalesce(p->>'time', ''), 12), ''))
    returning id into pid;
  insert into fr_plan_members(plan, person, status, role) values (pid, uid, 'in', nullif(left(coalesce(p->'roles'->>(uid::text), ''), 24), ''));
  foreach x in array inv loop
    insert into fr_plan_members(plan, person, status, role) values (pid, x, 'invited', nullif(left(coalesce(p->'roles'->>(x::text), ''), 24), '')) on conflict do nothing;
    if kind = 'double' then   -- a couple comes as a unit; each partner still votes as themselves
      select * into cp from _fr_partner(x);
      if cp.puid is not null and cp.puid <> uid and cp.puid is distinct from sf then pp := _fr_ensure(cp.puid, cp.pname); insert into fr_plan_members(plan, person, status, via) values (pid, cp.puid, 'invited', x) on conflict do nothing; end if;
    end if;
  end loop;
  if coalesce((p->>'partner')::boolean, false) then
    select * into cp from _fr_partner(uid);
    if cp.puid is not null and cp.puid is distinct from sf then pp := _fr_ensure(cp.puid, cp.pname); insert into fr_plan_members(plan, person, status, via) values (pid, cp.puid, 'invited', uid) on conflict do nothing; end if;
  end if;
  if flow = 'trip' then
    if cardinality(wks) = 1 then update fr_plans set day_from = wks[1]::date where id = pid;
    else insert into fr_polls(plan, kind, options) values (pid, 'weekend', (select jsonb_agg(jsonb_build_object('id', d) order by d) from unnest(wks) d)); end if;
    if cardinality(cities) = 1 then
      update fr_plans set city = cities[1], deck = _fr_deck_city(cities[1]) where id = pid;
      insert into fr_polls(plan, kind, state) values (pid, 'stay', 'collect');
    else insert into fr_polls(plan, kind, options, created_at) values (pid, 'city', (select jsonb_agg(jsonb_build_object('id', md5(c), 'label', c) order by c) from unnest(cities) c), now() + interval '1 second'); end if;
  elsif flow = 'pick' then update fr_plans set deck = _fr_deck_local(uid, p->>'kind') where id = pid;
  end if;
  return jsonb_build_object('ok', true, 'id', pid);
end $$;

create or replace function fr_plan(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  if not exists (select 1 from fr_plan_members where plan = p_id and person = uid and status <> 'out') then return jsonb_build_object('ok', false, 'why', 'gone'); end if;
  return _fr_plan_json(p_id, uid);
end $$;

create or replace function fr_plan_act(p_id uuid, p_kind text, p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); pl fr_plans; me fr_plan_members; q fr_polls; d jsonb := coalesce(p_data, '{}'::jsonb); cp record; pp fr_people; n int; ids jsonb; x uuid; t text;
begin
  if uid is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  select * into pl from fr_plans where id = p_id;
  select * into me from fr_plan_members where plan = p_id and person = uid and status <> 'out';
  if pl.id is null or me.plan is null then return jsonb_build_object('ok', false, 'why', 'gone'); end if;
  if p_kind = 'respond' then
    update fr_plan_members set status = case when coalesce((d->>'in')::boolean, false) then 'in' else 'out' end where plan = p_id and person = uid and person <> pl.owner;
    if not coalesce((d->>'in')::boolean, false) then
      delete from fr_votes v using fr_polls qq where qq.id = v.poll and qq.plan = p_id and v.person = uid and qq.state <> 'done';
      perform _fr_tally(qq.id) from fr_polls qq where qq.plan = p_id and qq.state in ('open', 'runoff');
      return jsonb_build_object('ok', true, 'left', true);
    end if;
  elsif me.status <> 'in' then return jsonb_build_object('ok', false, 'why', 'respond');
  elsif p_kind = 'vote' then
    select * into q from fr_polls where id = (d->>'poll')::uuid and plan = p_id;
    if not found or q.state not in ('open', 'runoff') then return jsonb_build_object('ok', false, 'why', 'closed'); end if;
    if q.state = 'runoff' then
      if not (q.runoff ? (d->>'v')) then return jsonb_build_object('ok', false, 'why', 'bad'); end if;
      ids := to_jsonb(d->>'v');
    elsif q.kind = 'weekend' then
      select jsonb_object_agg(o->>'id', d->'v'->>(o->>'id')) into ids from jsonb_array_elements(q.options) o where d->'v'->>(o->>'id') in ('can', 'maybe', 'cant');
      if ids is null or (select count(*) from jsonb_object_keys(ids)) < jsonb_array_length(q.options) then return jsonb_build_object('ok', false, 'why', 'all'); end if;
    else
      select jsonb_agg(val order by pos) into ids from (select distinct on (val) val, pos from jsonb_array_elements_text(d->'v') with ordinality r(val, pos)
        where exists (select 1 from jsonb_array_elements(q.options) o where o->>'id' = val) order by val, pos) z where pos <= 3;
      if ids is null then return jsonb_build_object('ok', false, 'why', 'bad'); end if;
    end if;
    insert into fr_votes(poll, person, round, v) values (q.id, uid, q.round, ids) on conflict (poll, person, round) do update set v = excluded.v, created_at = now();
    perform _fr_tally(q.id);
  elsif p_kind = 'close' then
    select * into q from fr_polls where id = (d->>'poll')::uuid and plan = p_id;
    if not found or pl.owner <> uid then return jsonb_build_object('ok', false, 'why', 'host'); end if;
    perform _fr_tally(q.id, true);
  elsif p_kind = 'swipe' then
    x := (d->>'card')::uuid;
    if x is null or not (x = any(pl.deck) or exists (select 1 from fr_ideas i where i.id = x and i.plan = p_id)) then return jsonb_build_object('ok', false, 'why', 'bad'); end if;
    insert into fr_swipes(plan, card, person, yes) values (p_id, x, uid, coalesce((d->>'yes')::boolean, false)) on conflict (plan, card, person) do update set yes = excluded.yes;
    return jsonb_build_object('ok', true);
  elsif p_kind = 'idea' then
    t := nullif(left(trim(coalesce(d->>'title', '')), 60), '');
    if t is null or (select count(*) from fr_ideas where plan = p_id) >= 30 then return jsonb_build_object('ok', false, 'why', 'bad'); end if;
    insert into fr_ideas(plan, title, by) values (p_id, t, uid) returning id into x;
    insert into fr_swipes(plan, card, person, yes) values (p_id, x, uid, true);
  elsif p_kind = 'shortlist' then
    if pl.owner <> uid or pl.flow <> 'pick' or pl.data->'pick' is not null or exists (select 1 from fr_polls where plan = p_id and kind = 'pick' and state <> 'done') then return jsonb_build_object('ok', false, 'why', 'host'); end if;
    select count(*) into n from fr_plan_members where plan = p_id and status = 'in';
    if n < 2 then return jsonb_build_object('ok', false, 'why', 'alone'); end if;
    select jsonb_agg(jsonb_build_object('id', z.card, 'label', z.title, 'sub', z.sub, 'img', z.img, 'url', z.url) order by z.yes desc, z.title) into ids from (
      select y.card, y.yes, coalesce(c.title, i.title) title, c.subtitle sub, c.image img, c.data->>'url' url
      from (select s.card, count(*) filter (where s.yes) yes from fr_swipes s join fr_plan_members m on m.plan = s.plan and m.person = s.person and m.status = 'in' where s.plan = p_id group by s.card) y
      left join cards c on c.id = y.card left join fr_ideas i on i.id = y.card
      where y.yes * 2 > n or (n <= 2 and y.yes = n) order by y.yes desc limit 5) z;
    if ids is null then return jsonb_build_object('ok', false, 'why', 'none'); end if;
    delete from fr_polls where plan = p_id and kind = 'pick';
    insert into fr_polls(plan, kind, options) values (p_id, 'pick', ids) returning * into q;
    if jsonb_array_length(ids) = 1 then perform _fr_apply(q.id, ids->0->>'id'); end if;
  elsif p_kind = 'stayopt' then
    select * into q from fr_polls where plan = p_id and kind = 'stay' and state = 'collect';
    t := nullif(left(trim(coalesce(d->>'label', '')), 60), '');
    if not found or t is null or jsonb_array_length(q.options) >= 6 then return jsonb_build_object('ok', false, 'why', 'bad'); end if;
    update fr_polls set options = options || jsonb_build_array(jsonb_build_object('id', md5(t || clock_timestamp()::text), 'label', t, 'sub', nullif(left(trim(coalesce(d->>'sub', '')), 80), ''),
      'url', case when d->>'url' ~* '^https://[^\s<>"'']+$' then left(d->>'url', 400) end, 'by', (select name from fr_people where id = uid))) where id = q.id;
  elsif p_kind = 'startvote' then
    select * into q from fr_polls where plan = p_id and kind = 'stay' and state = 'collect';
    if not found or pl.owner <> uid or jsonb_array_length(q.options) = 0 then return jsonb_build_object('ok', false, 'why', 'host'); end if;
    if jsonb_array_length(q.options) = 1 then perform _fr_apply(q.id, q.options->0->>'id'); else update fr_polls set state = 'open' where id = q.id; end if;
  elsif p_kind = 'arrive' then
    update fr_plan_members set arrive_at = case when d->>'at' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' then (d->>'at')::timestamptz end, arrive_how = nullif(left(trim(coalesce(d->>'how', '')), 40), '') where plan = p_id and person = uid;
  elsif p_kind = 'booked' then update fr_plan_members set booked = coalesce((d->>'on')::boolean, false) where plan = p_id and person = uid;
  elsif p_kind = 'role' then
    if pl.owner <> uid then return jsonb_build_object('ok', false, 'why', 'host'); end if;
    update fr_plan_members set role = nullif(left(trim(coalesce(d->>'role', '')), 24), '') where plan = p_id and person = (d->>'person')::uuid;
  elsif p_kind = 'partner' then
    select * into cp from _fr_partner(uid);
    if cp.puid is null then return jsonb_build_object('ok', false, 'why', 'nopartner'); end if;
    if cp.puid = pl.surprise_for then return jsonb_build_object('ok', false, 'why', 'surprise'); end if;
    if coalesce((d->>'on')::boolean, false) then
      pp := _fr_ensure(cp.puid, cp.pname);
      insert into fr_plan_members(plan, person, status, via) values (p_id, cp.puid, 'invited', uid) on conflict (plan, person) do update set status = 'invited', via = uid where fr_plan_members.status = 'out';
    else delete from fr_plan_members where plan = p_id and person = cp.puid and via = uid and person <> pl.owner;
    end if;
  elsif p_kind = 'invite' then
    if pl.owner <> uid then return jsonb_build_object('ok', false, 'why', 'host'); end if;
    insert into fr_plan_members(plan, person, status) select p_id, f.b, 'invited' from fr_friends f
      where f.a = uid and f.b in (select i::uuid from jsonb_array_elements_text(coalesce(d->'ids', '[]'::jsonb)) i) and f.b is distinct from pl.surprise_for
      on conflict (plan, person) do update set status = 'invited' where fr_plan_members.status = 'out';
  elsif p_kind = 'cancel' then
    if pl.owner <> uid then return jsonb_build_object('ok', false, 'why', 'host'); end if;
    delete from fr_plans where id = p_id; return jsonb_build_object('ok', true, 'left', true);
  else return jsonb_build_object('ok', false, 'why', 'kind');
  end if;
  return _fr_plan_json(p_id, uid);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and (p.proname like 'fr\_%' or p.proname like '\_fr\_%') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'fr\_%' then execute format('grant execute on function %s to authenticated', f.sig); end if;
  end loop; end $$;

-- 18 Nov 2026, second pass: weekly reveal (fr_people.share, fr_reveals, _fr_loves, _fr_reveal, fr_share), a seed card for plans
-- started from a reveal, and the 'shirts' action. Applied as migration friends_weekly_reveal_shirts; see the project for the live text.
-- 18 Nov 2026, third pass: who owes what (fr_costs, fr_payments, fr_plan_members.plus, fr_people.pay, _fr_money, fr_pay and the
-- plus / cost / costdel / claim / paid actions). Applied as migration friends_costs_split.
