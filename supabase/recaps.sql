-- After a plan or a Tonight spin happens: each person says how each stop was (Loved it / It was fine / Not again).
-- Private: a partner never sees the other's answer. Only "you both loved it" is ever shown, and both-loved places
-- become couple favorites, which the planner already brings back. "Not again" counts as never again for that person.
-- Then "Go again?": a place you both loved that sits close to a stop in an upcoming plan.

create table if not exists recaps (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null,
  plan uuid unique,
  spin uuid unique,
  day date not null,
  label text not null,
  asked_at timestamptz,
  closed jsonb not null default '{}'::jsonb,       -- member -> true once they finished or said it didn't happen
  created_at timestamptz not null default now()
);
create table if not exists stop_ratings (
  recap uuid not null references recaps(id) on delete cascade,
  couple_id uuid not null,
  card_id uuid not null,
  member text not null,
  verdict text not null check (verdict in ('loved', 'fine', 'nope', 'skip')),
  created_at timestamptz not null default now(),
  primary key (recap, card_id, member)
);
create index if not exists stop_ratings_couple on stop_ratings (couple_id, card_id);
create table if not exists again_seen (
  couple_id uuid not null, plan uuid not null, card_id uuid not null, member text not null,
  status text not null default 'shown', created_at timestamptz not null default now(),
  primary key (plan, card_id, member)
);
alter table recaps enable row level security;
alter table stop_ratings enable row level security;
alter table again_seen enable row level security;

-- Not again counts as never again for that person.
create or replace function _never(p_couple uuid, p_card uuid, p_member text default null) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from (select distinct on (w.member) w.member, w.verdict, w.feel from swipes w
                                where w.couple_id = p_couple and w.card_id = p_card and not w.rewatch order by w.member, w.created_at desc) l
                 where l.verdict = 'seen' and l.feel = 'no' and (p_member is null or l.member = p_member))
      or exists (select 1 from stop_ratings r where r.couple_id = p_couple and r.card_id = p_card and r.verdict = 'nope' and (p_member is null or r.member = p_member)) $$;

create or replace function _recap_label(p plans) returns text language sql stable as $$
  select case when p.mode = 'in' then 'night in'
              when exists (select 1 from jsonb_array_elements(p.items) x where x->>'time' >= '17:00') and not exists (select 1 from jsonb_array_elements(p.items) x where x->>'time' < '15:00') then 'date night'
              when extract(dow from p.day) in (0, 6) then to_char(p.day, 'FMDay') else 'day out' end $$;

create or replace function _both_loved(p_couple uuid, p_card uuid) returns date language sql stable security definer set search_path to 'public' as $$
  select max(rc.day) from recaps rc where rc.couple_id = p_couple
    and (select count(distinct r.member) from stop_ratings r where r.recap = rc.id and r.card_id = p_card and r.verdict = 'loved') >= 2 $$;

-- Makes recaps for plans both said yes to and spins both were in on, once the day is over. Pushes only where
-- settings.recap_push is true (sim: everyone; live: off until Dave turns it on).
create or replace function _recap_tick() returns integer language plpgsql security definer set search_path to 'public' as $$
declare r record; n int := 0; h int := extract(hour from now() at time zone _tz());
begin
  insert into recaps (couple_id, plan, day, label)
    select p.couple_id, p.id, p.day, _recap_label(p) from plans p
    where p.status in ('agreed', 'done') and p.day < _today() and p.day >= _today() - 10
      and exists (select 1 from jsonb_array_elements(p.items) x where x->>'card' is not null)
  on conflict (plan) do nothing;
  insert into recaps (couple_id, spin, day, label)
    select s.couple_id, s.id, s.day, case s.kind when 'movie' then 'movie night' when 'dinner' then 'dinner' else 'night out' end from spins s
    where s.status = 'on' and s.card is not null and s.day < _today() and s.day >= _today() - 10
  on conflict (spin) do nothing;
  if h between 10 and 19 then
    for r in select rc.id, rc.label, rc.day, cp.code, m.name from recaps rc join couples cp on cp.id = rc.couple_id join members m on m.couple_id = rc.couple_id
             where rc.asked_at is null and rc.day >= _today() - 3 and coalesce((select (settings->>'recap_push')::boolean from couples where id = rc.couple_id), false) loop
      perform net.http_post(url := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/nudge', timeout_milliseconds := 30000, headers := jsonb_build_object('Content-Type', 'application/json'),
        body := jsonb_build_object('code', r.code, 'member', r.name, 'title', 'How was ' || case when r.label ~ 'day$' then r.label else 'your ' || r.label end || '?',
          'body', 'Tap what you loved. Places you both love come back in future plans.', 'url', './?recap=' || r.id, 'tag', 'recap-' || r.id));
      n := n + 1;
    end loop;
    update recaps set asked_at = now() where asked_at is null and day >= _today() - 3;
  end if;
  return n;
end $$;

create or replace function _recap_json(p_recap uuid, p_member text) returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('id', rc.id, 'label', rc.label, 'day', rc.day,
    'stops', (select coalesce(jsonb_agg(jsonb_build_object('card', _spin_card(c.id),
        'mine', (select verdict from stop_ratings r where r.recap = rc.id and r.card_id = c.id and r.member = p_member),
        'both', exists (select 1 from stop_ratings r where r.recap = rc.id and r.card_id = c.id and r.verdict = 'loved' and r.member <> p_member)
                and exists (select 1 from stop_ratings r where r.recap = rc.id and r.card_id = c.id and r.verdict = 'loved' and r.member = p_member)) order by z.ord), '[]'::jsonb)
      from (select (x->>'card')::uuid cid, ord from plans p, jsonb_array_elements(p.items) with ordinality e(x, ord) where p.id = rc.plan and x->>'card' is not null
            union all select s.card, 1 from spins s where s.id = rc.spin) z join cards c on c.id = z.cid))
  from recaps rc where rc.id = p_recap $$;

-- The newest recap this person hasn't finished (last 7 days).
create or replace function recap_get(p_code text, p_member text, p_id uuid default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v uuid := _couple(p_code); rid uuid;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then return null; end if;
  if p_id is not null then select id into rid from recaps where id = p_id and couple_id = v;
  else select rc.id into rid from recaps rc where rc.couple_id = v and rc.day >= _today() - 7 and rc.day < _today() and not (rc.closed ? p_member)
         order by rc.day desc limit 1; end if;
  if rid is null then return null; end if;
  return _recap_json(rid, p_member);
end $$;

create or replace function recap_rate(p_code text, p_member text, p_id uuid, p_card uuid, p_verdict text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v uuid := _couple(p_code); rc recaps; j jsonb;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  select * into rc from recaps where id = p_id and couple_id = v; if rc.id is null then raise exception 'bad_recap'; end if;
  if p_verdict = 'gone' then   -- "It didn't happen"
    insert into stop_ratings (recap, couple_id, card_id, member, verdict)
      select rc.id, v, (s->'card'->>'id')::uuid, p_member, 'skip' from jsonb_array_elements(_recap_json(rc.id, p_member)->'stops') s
    on conflict do nothing;
    update recaps set closed = closed || jsonb_build_object(p_member, true) where id = rc.id;
    update plans set status = 'skipped', went = jsonb_build_object('by', p_member, 'at', now()) where id = rc.plan and status = 'agreed';
    return _recap_json(rc.id, p_member);
  end if;
  if p_verdict not in ('loved', 'fine', 'nope', 'skip') then raise exception 'bad_verdict'; end if;
  j := _recap_json(rc.id, p_member);
  if not exists (select 1 from jsonb_array_elements(j->'stops') s where s->'card'->>'id' = p_card::text) then raise exception 'bad_card'; end if;
  insert into stop_ratings (recap, couple_id, card_id, member, verdict) values (rc.id, v, p_card, p_member, p_verdict)
    on conflict (recap, card_id, member) do update set verdict = excluded.verdict, created_at = now();
  if p_verdict in ('loved', 'fine') then
    update plans set status = 'done', went = jsonb_build_object('by', p_member, 'at', now()) where id = rc.plan and status = 'agreed';
  end if;
  if _both_loved(v, p_card) is not null and (select deck from cards where id = p_card) <> 'movie' then
    insert into favorites (couple_id, card_id, by_member) values (v, p_card, 'both') on conflict do nothing;
  end if;
  j := _recap_json(rc.id, p_member);
  if not exists (select 1 from jsonb_array_elements(j->'stops') s where s->>'mine' is null) then
    update recaps set closed = closed || jsonb_build_object(p_member, true) where id = rc.id;
  end if;
  return j;
end $$;

-- "Go again?": one both-loved place within a mile of a stop in an upcoming plan (next 14 days).
create or replace function again_get(p_code text, p_member text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v uuid := _couple(p_code); r record; ago text; wk text;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then return null; end if;
  select p.id plan, p.day, near.title near_title, near.tm, c.id card, c.title, _both_loved(v, c.id) loved_day,
         _miles((c.data->>'lat')::float8, (c.data->>'lng')::float8, near.lat, near.lng) mi
    into r
    from plans p
    cross join lateral (select cc.title, x->>'time' tm, (cc.data->>'lat')::float8 lat, (cc.data->>'lng')::float8 lng
                        from jsonb_array_elements(p.items) x join cards cc on cc.id = (x->>'card')::uuid
                        where cc.data ? 'lat' and x->>'hidden' is null) near
    join cards c on c.couple_id = v and c.active and c.data ? 'lat' and c.deck <> 'movie'
    where p.couple_id = v and p.status in ('sent', 'agreed') and p.day between _today() and _today() + 14
      and _both_loved(v, c.id) is not null and not _never(v, c.id)
      and p.items::text not like '%' || c.id::text || '%'
      and not exists (select 1 from again_seen a where a.plan = p.id and a.card_id = c.id and a.status <> 'shown')
      and not exists (select 1 from again_seen a where a.couple_id = v and a.member = p_member and a.status = 'no' and a.card_id = c.id and a.created_at > now() - interval '30 days')
      and _miles((c.data->>'lat')::float8, (c.data->>'lng')::float8, near.lat, near.lng) <= 1
    order by p.day, _miles((c.data->>'lat')::float8, (c.data->>'lng')::float8, near.lat, near.lng) limit 1;
  if r.plan is null then return null; end if;
  insert into again_seen (couple_id, plan, card_id, member) values (v, r.plan, r.card, p_member) on conflict do nothing;
  ago := case when date_trunc('month', r.loved_day) = date_trunc('month', _today()) then case when r.loved_day >= _today() - 8 then 'last week' else 'earlier this month' end
              when date_trunc('month', r.loved_day) = date_trunc('month', _today()) - interval '1 month' then 'last month'
              else 'in ' || to_char(r.loved_day, 'FMMonth') end;
  wk := case when r.day = _today() then 'tonight' when r.day = _today() + 1 then 'tomorrow' when r.day < _today() + 7 then 'this ' || to_char(r.day, 'FMDay') else 'next ' || to_char(r.day, 'FMDay') end;
  return jsonb_build_object('plan', r.plan, 'day', r.day, 'card', _spin_card(r.card), 'near', r.near_title,
    'text', 'You both loved ' || split_part(r.title, ',', 1) || ' from your ' ||
      coalesce((select rc.label from recaps rc where rc.couple_id = v and rc.day = r.loved_day order by rc.created_at limit 1), 'last outing') || ' ' || ago ||
      ', and it’s ' || case when r.mi <= 0.6 then greatest(2, round(r.mi * 20))::int || ' min on foot' else 'a short ride' end || ' from ' || split_part(r.near_title, ',', 1) || ' ' || wk || '. Go again?');
end $$;

-- Add it next to the stop it's close to (before an evening or set-start stop, after a daytime one), or pass.
create or replace function again_act(p_code text, p_member text, p_plan uuid, p_card uuid, p_act text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v uuid := _couple(p_code); p plans; sl text; tm text; nr record;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  select * into p from plans where id = p_plan and couple_id = v and status in ('sent', 'agreed'); if p.id is null then raise exception 'bad_plan'; end if;
  if _both_loved(v, p_card) is null then raise exception 'bad_card'; end if;
  if p_act = 'no' then
    insert into again_seen (couple_id, plan, card_id, member, status) values (v, p.id, p_card, p_member, 'no')
      on conflict (plan, card_id, member) do update set status = 'no', created_at = now();
    return null;
  end if;
  if p.items::text like '%' || p_card::text || '%' then return _plan_mask(_plan_json(p), p_member); end if;
  sl := case when not exists (select 1 from jsonb_array_elements(p.items) x where x->>'slot' = 'quest') then 'quest'
             when not exists (select 1 from jsonb_array_elements(p.items) x where x->>'slot' = 'quest2') then 'quest2' end;
  if sl is null then raise exception 'two_quests'; end if;
  select x->>'time' t, cc.deck, cc.event_date into nr from jsonb_array_elements(p.items) x join cards cc on cc.id = (x->>'card')::uuid, cards c
    where c.id = p_card and cc.data ? 'lat' and c.data ? 'lat'
    order by _miles((c.data->>'lat')::float8, (c.data->>'lng')::float8, (cc.data->>'lat')::float8, (cc.data->>'lng')::float8) limit 1;
  tm := to_char(('2000-01-01 ' || coalesce(nr.t, '18:00'))::timestamp + case when coalesce(nr.t, '18:00') >= '17:00' or nr.event_date is not null then interval '-90 minutes' else interval '2 hours' end, 'HH24:MI');
  update plans set items = (select jsonb_agg(x order by x->>'time' nulls last) from jsonb_array_elements(items || jsonb_build_array(jsonb_build_object('slot', sl, 'time', tm, 'card', p_card, 'find', false, 'why', 'again'))) x),
         updated_at = now(), checked_at = null where id = p.id returning * into p;
  insert into again_seen (couple_id, plan, card_id, member, status) values (v, p.id, p_card, p_member, 'added')
    on conflict (plan, card_id, member) do update set status = 'added';
  return _plan_mask(_plan_json(p), p_member);
end $$;

grant execute on function recap_get(text, text, uuid), recap_rate(text, text, uuid, uuid, text), again_get(text, text), again_act(text, text, uuid, uuid, text) to anon, authenticated;

-- Plan saves keep the "again" reason.
do $do$ begin
  execute replace(pg_get_functiondef('_plan_items_clean'::regproc), '(both|fav|new|one:', '(both|fav|new|again|one:');
end $do$;

select cron.schedule('welike-recap', '20 * * * *', 'select _recap_tick()');
