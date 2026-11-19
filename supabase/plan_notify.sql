-- Plan notifications that stay relevant (Nov 18): hold queue, relevance gate, small edits keep a yes, ideas skip what a plan covers.
create table if not exists public.push_later (
  plan uuid not null, member text not null, couple_id uuid not null, code text not null, sender text not null,
  title text, body text, url text, need text, due_at timestamptz not null, primary key (plan, member));
alter table public.push_later enable row level security;
create index if not exists push_later_due on public.push_later (due_at);

-- Is a push about this plan still worth sending to this person, and if so, now or at 9am?
create or replace function public.push_plan_gate(p_couple uuid, p_member text, p_plan uuid, p_need text)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare r plans; tz text; lt timestamp; d date; h int; later timestamptz;
begin
  select * into r from plans where id = p_plan and couple_id = p_couple;
  if r.id is null then return '{"go":false,"why":"gone"}'; end if;
  select _zip_tz(settings->>'zip') into tz from couples where id = p_couple;
  lt := now() at time zone tz; d := lt::date; h := extract(hour from lt);
  if r.day < d then return '{"go":false,"why":"past"}'; end if;
  if r.status not in ('sent', 'agreed') then return '{"go":false,"why":"closed"}'; end if;
  if p_need = 'answer' and (r.status <> 'sent' or coalesce((r.ok->>p_member)::boolean, false)) then return '{"go":false,"why":"done"}'; end if;
  -- late at night, anything not about today or tomorrow waits for 9am
  if (h >= 21 or h < 9) and r.day > d + 1 then later := ((case when h >= 21 then d + 1 else d end) + time '09:00') at time zone tz; end if;
  return jsonb_build_object('go', true, 'later', later);
end $f$;
revoke all on function public.push_plan_gate(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.push_plan_gate(uuid, text, uuid, text) to service_role;

create or replace function public._push_later_tick() returns integer language plpgsql security definer set search_path to 'public' as $f$
declare r record; n int := 0;
begin
  for r in delete from push_later where due_at <= now() returning * loop
    perform net.http_post(url := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/nudge', timeout_milliseconds := 30000,
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object('code', r.code, 'member', r.sender, 'to', r.member, 'title', r.title, 'body', r.body, 'url', r.url,
                                 'plan', r.plan, 'need', r.need, 'noinbox', true, 'queued', true));
    n := n + 1;
  end loop;
  return n;
end $f$;
revoke all on function public._push_later_tick() from public, anon, authenticated;

-- An idea built around something already in a plan this week isn't news.
create or replace function public._idea_in_plan(p_couple uuid, p_cards uuid[]) returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists (
    select 1 from plans p, jsonb_array_elements(p.items) x, cards pc, cards ic
    where p.couple_id = p_couple and p.status in ('sent', 'agreed') and p.day between current_date - 1 and current_date + 7
      and jsonb_typeof(x->'card') = 'string' and pc.id::text = x->>'card'
      and ic.id = any(coalesce(p_cards, '{}'))
      and (ic.id = pc.id or (length(trim(split_part(pc.title, ',', 1))) >= 8 and length(trim(split_part(ic.title, ',', 1))) >= 8
           and (lower(ic.title) like lower(trim(split_part(pc.title, ',', 1))) || '%' or lower(pc.title) like lower(trim(split_part(ic.title, ',', 1))) || '%'))))
$f$;
revoke all on function public._idea_in_plan(uuid, uuid[]) from public, anon, authenticated;

-- Saving a plan. A small edit (same day and kind of day, same places, times moved 30 minutes or less, open spots
-- taken out) keeps the other person's yes and comes back with minor = true, so the app doesn't ask them again.
create or replace function public.plan_save(p_code text, p_member text, p_id uuid, p_day date, p_mode text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare v uuid := _couple(p_code); r plans; o plans; it jsonb; m text := case when p_mode = 'in' then 'in' else 'out' end; minor boolean := false;
begin
  if not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_member'; end if;
  if p_day is null or p_day < _today() or p_day > _today() + 60 then raise exception 'bad_day'; end if;
  it := _plan_items_clean(v, p_items);
  if jsonb_array_length(it) = 0 then raise exception 'empty_plan'; end if;
  if p_id is null then
    insert into plans (couple_id, day, by_member, mode, items, ok) values (v, p_day, p_member, m, it, jsonb_build_object(p_member, true)) returning * into r;
    return _plan_json(r);
  end if;
  select * into o from plans where id = p_id and couple_id = v and status in ('sent','agreed');
  if o.id is null then raise exception 'bad_plan'; end if;
  minor := o.day = p_day and o.mode = m
    and (select coalesce(array_agg(x->>'card' order by x->>'card'), '{}') from jsonb_array_elements(o.items) x where jsonb_typeof(x->'card') = 'string')
      = (select coalesce(array_agg(x->>'card' order by x->>'card'), '{}') from jsonb_array_elements(it) x where jsonb_typeof(x->'card') = 'string')
    and not exists (select 1 from jsonb_array_elements(o.items) a join jsonb_array_elements(it) b on a->>'card' = b->>'card'
                    where jsonb_typeof(a->'card') = 'string' and abs(extract(epoch from ((b->>'time')::time - (a->>'time')::time))) > 1800)
    and not exists (select 1 from jsonb_array_elements(it) b where (b->>'find')::boolean is true
                      and not exists (select 1 from jsonb_array_elements(o.items) a where a->>'slot' = b->>'slot' and (a->>'find')::boolean is true));
  if minor then
    update plans set items = it, updated_at = now(), checked_at = null,
      picks = coalesce((select jsonb_object_agg(k, val) from jsonb_each(coalesce(picks, '{}')) e(k, val) where exists (select 1 from jsonb_array_elements(it) x where x->>'slot' = k)), '{}')
      where id = o.id returning * into r;
    return _plan_json(r) || '{"minor":true}';
  end if;
  update plans set day = p_day, mode = m, items = it, ok = jsonb_build_object(p_member, true),
    by_member = case when by_member = 'auto' then p_member else by_member end, status = 'sent', updated_at = now(),
    closed = '[]'::jsonb, checked_at = null, picks = '{}'::jsonb
    where id = o.id returning * into r;
  return _plan_json(r);
end $f$;

do $d$ declare s text := pg_get_functiondef('public._ideas_tick'::regproc);
  a text := 'if i.id is not null and not exists (select 1 from push_log';
begin
  if position('_idea_in_plan' in s) = 0 then
    if position(a in s) = 0 then raise exception 'anchor missing in _ideas_tick'; end if;
    execute replace(s, a, 'if i.id is not null and not (i.kind = ''idea'' and _idea_in_plan(c.id, i.cards)) and not exists (select 1 from push_log');
  end if;
end $d$;
