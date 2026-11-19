-- Trivia night on one shared clock (Dave's go, 19 Nov 2026).
-- Every couple gets question n at the same second. 3-5 s to read, 4 s to answer, 2 / 1 / 0 points.
alter table trivia_events add column if not exists mode text not null default 'paced';
create table if not exists trivia_custom (event_id text references trivia_events(id) on delete cascade, couple_id uuid, qid text, q jsonb not null, primary key (event_id, couple_id, qid));
create table if not exists trivia_buzz (event_id text references trivia_events(id) on delete cascade, couple_id uuid, member text, on_at timestamptz not null default now(), primary key (event_id, couple_id, member));
alter table trivia_custom enable row level security;
alter table trivia_buzz enable row level security;

create or replace function _tv_read_s(t text) returns int language sql immutable as $$
  select case when length(coalesce(t, '')) <= 90 then 3 when length(t) <= 150 then 4 else 5 end $$;

-- the night's clock: 3 min welcome, a question every 100 s, a 3 min board after each round
create or replace function _tv_sched(p_event text)
returns table(n int, qid text, rnd int, show_at timestamptz, open_at timestamptz, close_at timestamptz, mine boolean)
language sql stable security definer set search_path = public as $$
  select t.i::int, t.x->>'id', ((t.i - 1) / e.per_round)::int + 1,
    e.starts_at + make_interval(secs => 180 + (t.i - 1) * 100 + ((t.i - 1) / e.per_round) * 180),
    e.starts_at + make_interval(secs => 180 + (t.i - 1) * 100 + ((t.i - 1) / e.per_round) * 180 + _tv_read_s(t.x->>'q')),
    e.starts_at + make_interval(secs => 180 + (t.i - 1) * 100 + ((t.i - 1) / e.per_round) * 180 + _tv_read_s(t.x->>'q') + 4),
    coalesce((t.x->>'mine')::boolean, false)
  from trivia_events e, jsonb_array_elements(e.q) with ordinality t(x, i)
  where e.id = p_event and (e.max_q is null or t.i <= e.max_q) $$;

-- a "your movies" question: three movies both of you said yes to; which came out first. Only matched movies, so nothing one-sided.
create or replace function _tv_mine(p_event text, v uuid, p_qid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb; r record; ts text[]; ys int[]; o text[]; first text;
begin
  select tc.q into q from trivia_custom tc where tc.event_id = p_event and tc.couple_id = v and tc.qid = p_qid;
  if q is not null then return q; end if;
  select array_agg(title order by rnd), array_agg(y order by rnd) into ts, ys from (select * from (
    select distinct on (y) title, y, random() rnd from (
      select c.title, (c.data->>'year')::int y from swipes s join cards c on c.id = s.card_id
      where s.couple_id = v and s.verdict in ('yes', 'love') and c.deck = 'movie' and c.data->>'year' ~ '^\d{4}$'
        and not exists (select 1 from trivia_custom tc, jsonb_array_elements_text(tc.q->'o') used where tc.event_id = p_event and tc.couple_id = v and used = c.title)
      group by c.id, c.title, c.data->>'year' having count(distinct s.member) >= 2
    ) m order by y, random()) d order by rnd limit 3) z;
  if coalesce(array_length(ts, 1), 0) < 3 then return null; end if;
  first := ts[array_position(ys, (select min(z) from unnest(ys) z))];
  select array_agg(t order by md5(t || p_qid)) into o from unnest(ts) t;
  q := jsonb_build_object('q', 'Which of these came out first?', 'o', to_jsonb(o), 'a', array_position(o, first) - 1,
    'f', (select string_agg(t || ' (' || y || ')', ', ' order by y) from unnest(ts, ys) u(t, y)), 'mine', true);
  insert into trivia_custom (event_id, couple_id, qid, q) values (p_event, v, p_qid, q) on conflict do nothing;
  return q;
end $$;

-- the answer key for one couple (their own movie question when they have one)
create or replace function _tv_key(p_event text, v uuid, p_qid text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select tc.q from trivia_custom tc where tc.event_id = p_event and tc.couple_id = v and tc.qid = p_qid),
                  (select x from trivia_events e, jsonb_array_elements(e.q) x where e.id = p_event and x->>'id' = p_qid)) $$;

-- points per closed question: both right on the same answer 2, one right 1, solo right 1, else 0
create or replace function _tv_score(p_event text, v uuid)
returns table(n int, qid text, rnd int, pts int, sync boolean, hit boolean, ms numeric)
language sql stable security definer set search_path = public as $$
  with mem as (select count(*)::int k from members where couple_id = v)
  select s.n, s.qid, s.rnd,
    case when a.k >= 2 and mem.k >= 2 and a.rightn = a.k then 2 when a.rightn >= 1 then 1 else 0 end,
    coalesce(a.k >= 2 and mem.k >= 2 and a.rightn = a.k, false), coalesce(a.rightn >= 1, false), a.ms
  from _tv_sched(p_event) s cross join mem
  cross join lateral (select (_tv_key(p_event, v, s.qid)->>'a')::int ans) key
  left join lateral (select count(*)::int k, count(*) filter (where ta.choice = key.ans)::int rightn,
      avg(extract(epoch from ta.at - s.open_at) * 1000) filter (where ta.choice = key.ans) ms
    from trivia_answers ta where ta.event_id = p_event and ta.couple_id = v and ta.qid = s.qid) a on true
  where s.close_at + interval '0.7 seconds' < now() $$;

-- standings after question p_upto. Host and test couples are never listed; solo players sit apart and can't win.
create or replace function _tv_board(p_event text, v uuid, p_upto int) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (
    select cp.id, coalesce(cp.settings->'team'->>'name', case when m.k >= 2 then 'A mystery couple' else 'A solo player' end) nm, m.k mem,
      (_is_test(cp.id) or coalesce((cp.settings->>'trivia_host')::boolean, false)) hidden, sc.pts, sc.sy, sc.ms
    from couples cp
    cross join lateral (select count(*)::int k from members where couple_id = cp.id) m
    cross join lateral (select coalesce(sum(x.pts), 0)::int pts, count(*) filter (where x.sync)::int sy, avg(x.ms) ms from _tv_score(p_event, cp.id) x where x.n <= p_upto) sc
    where exists (select 1 from trivia_answers ta where ta.event_id = p_event and ta.couple_id = cp.id) or cp.id = v),
  r as (select s.*, row_number() over (order by pts desc, sy desc, coalesce(ms, 1e9), nm) rk from s where mem >= 2 and not hidden)
  select jsonb_build_object(
    'upto', p_upto,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('rank', rk, 'name', nm, 'pts', pts, 'sync', sy, 'me', id = v) order by rk) from r where rk <= 5 or id = v), '[]'::jsonb),
    'solo', coalesce((select jsonb_agg(jsonb_build_object('name', nm, 'pts', pts, 'me', id = v) order by pts desc, nm) from s where mem < 2 and not hidden), '[]'::jsonb),
    'teams', (select count(*) from r),
    'me', (select jsonb_build_object('pts', s.pts, 'sync', s.sy, 'hidden', s.hidden, 'solo', s.mem < 2,
             'rank', (select rk from r where r.id = v),
             'as_if', case when s.hidden then 1 + (select count(*) from r where r.pts > s.pts) end) from s where s.id = v),
    'lead', (select pts from r where rk = 1))
$$;

create or replace function _tv_state(p_event text, v uuid, p_member text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e trivia_events; ph text; last_close timestamptz; sc record; upto int; sched jsonb;
begin
  select * into e from trivia_events where id = p_event;
  select jsonb_agg(jsonb_build_object('n', n, 'qid', qid, 'r', rnd, 's', show_at, 'o', open_at, 'c', close_at, 'mine', mine) order by n), max(close_at) into sched, last_close from _tv_sched(e.id);
  ph := case when now() < e.starts_at then 'before' when now() < e.ends_at then 'live' else 'after' end;
  select coalesce(sum(pts), 0)::int pts, count(*) filter (where sync)::int sy, count(*)::int done into sc from _tv_score(e.id, v);
  select coalesce(max(n), 0) into upto from _tv_sched(e.id) where close_at + interval '0.7 seconds' < now();
  return jsonb_build_object('id', e.id, 'mode', 'clock', 'title', e.title, 'starts', e.starts_at, 'ends', e.ends_at, 'now', now(), 'phase', ph,
    'test', e.status = 'test', 'prize', e.prize, 'movie', e.movie, 'sched', sched, 'questions', jsonb_array_length(sched), 'per', e.per_round,
    'rounds', (select max(rnd) from _tv_sched(e.id)), 'done', sc.done, 'score', sc.pts, 'sync', sc.sy,
    'solo', (select count(*) from members where couple_id = v) < 2,
    'host', coalesce((select (settings->>'trivia_host')::boolean from couples where id = v), false) or _is_test(v),
    'team', (select settings->'team'->>'name' from couples where id = v),
    'buzz', exists (select 1 from trivia_buzz b where b.event_id = e.id and b.couple_id = v and b.member = p_member),
    'played', exists (select 1 from trivia_answers ta where ta.event_id = e.id and ta.couple_id = v),
    'board', case when upto > 0 and (upto % e.per_round = 0 or ph = 'after') then _tv_board(e.id, v, upto) end);
end $$;

-- one question for one couple, from the moment it shows
create or replace function trivia_q(p_code text, p_member text, p_event text, p_qid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); s record; q jsonb;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  select * into s from _tv_sched(p_event) x where x.qid = p_qid;
  if s.qid is null or now() < s.show_at - interval '1 second' then raise exception 'not_open'; end if;
  if s.mine then q := _tv_mine(p_event, v, p_qid); end if;
  if q is null then select x into q from trivia_events e, jsonb_array_elements(e.q) x where e.id = p_event and x->>'id' = p_qid; end if;
  return jsonb_build_object('qid', p_qid, 'n', s.n, 'r', s.rnd, 'text', q->>'q', 'o', q->'o', 'mine', coalesce((q->>'mine')::boolean, false),
    'cat', q->>'cat', 's', s.show_at, 'open', s.open_at, 'close', s.close_at, 'now', now(),
    'mine_pick', (select choice from trivia_answers where event_id = p_event and couple_id = v and qid = p_qid and member = p_member));
end $$;

-- the clock-mode branches of the existing calls
create or replace function trivia_answer(p_code text, p_member text, p_event text, p_qid text, p_choice integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); pl trivia_plays; s record;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  if (select mode from trivia_events where id = p_event) = 'clock' then
    select * into s from _tv_sched(p_event) x where x.qid = p_qid;
    if s.qid is null or now() < s.open_at - interval '0.4 seconds' then raise exception 'not_open'; end if;
    if now() > s.close_at + interval '0.6 seconds' or p_choice not between 0 and 2 then return jsonb_build_object('ok', false, 'late', true); end if;
    insert into trivia_answers (event_id, couple_id, qid, member, choice) values (p_event, v, p_qid, p_member, p_choice)
      on conflict (event_id, couple_id, qid, member) do update set choice = excluded.choice, at = now();
    return jsonb_build_object('ok', true);
  end if;
  select * into pl from trivia_plays where event_id = p_event and couple_id = v and qid = p_qid;
  if pl.open_at is null or now() < pl.open_at - interval '0.5 seconds' then raise exception 'not_open'; end if;
  if now() > pl.open_at + interval '5.5 seconds' or p_choice not between 0 and 3 then return jsonb_build_object('ok', false, 'late', true); end if;
  insert into trivia_answers (event_id, couple_id, qid, member, choice) values (p_event, v, p_qid, p_member, p_choice) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

create or replace function trivia_reveal(p_code text, p_member text, p_event text, p_qid text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v uuid := _couple(p_code); c record; e trivia_events; x jsonb; pl trivia_plays; s record; k jsonb; rate numeric; nt int;
begin
  if v is null then raise exception 'bad_code'; end if;
  select * into e from trivia_events where id = p_event;
  if e.mode = 'clock' then
    select * into s from _tv_sched(p_event) z where z.qid = p_qid;
    if s.qid is null then raise exception 'not_open'; end if;
    if now() < s.close_at + interval '0.7 seconds' then return jsonb_build_object('wait', true, 'ms', greatest(150, (extract(epoch from (s.close_at + interval '0.75 seconds') - now()) * 1000)::int)); end if;
    k := _tv_key(p_event, v, p_qid);
    select * into c from _tv_score(p_event, v) z where z.qid = p_qid;
    if not coalesce((k->>'mine')::boolean, false) then
      select count(distinct ta.couple_id), avg((ta.choice = (x2->>'a')::int)::int) into nt, rate
      from trivia_answers ta join couples cp on cp.id = ta.couple_id, jsonb_array_elements(e.q) x2
      where ta.event_id = p_event and ta.qid = p_qid and x2->>'id' = p_qid and not _is_test(cp.id) and coalesce((cp.settings->>'trivia_host')::boolean, false) = false
        and not exists (select 1 from trivia_custom tc where tc.event_id = p_event and tc.couple_id = ta.couple_id and tc.qid = p_qid);
    end if;
    return jsonb_build_object('qid', p_qid, 'n', s.n, 'a', (k->>'a')::int, 'text', k->>'q', 'o', k->'o', 'fact', k->>'f', 'mine', coalesce((k->>'mine')::boolean, false),
      'pts', coalesce(c.pts, 0), 'sync', coalesce(c.sync, false), 'hit', coalesce(c.hit, false),
      'rate', case when nt >= 3 then round(rate * 100) end,
      'picks', (select coalesce(jsonb_object_agg(member, choice), '{}'::jsonb) from trivia_answers where event_id = p_event and couple_id = v and qid = p_qid),
      'state', _tv_state(p_event, v, p_member));
  end if;
  select * into c from _trivia_closed(p_event, v) z where z.qid = p_qid;
  if not found then select * into pl from trivia_plays where event_id = p_event and couple_id = v and qid = p_qid;
    return jsonb_build_object('wait', true, 'ms', greatest(200, (extract(epoch from (pl.open_at + interval '5.6 seconds') - now()) * 1000)::int)); end if;
  select t.x into x from jsonb_array_elements(e.q) t(x) where t.x->>'id' = p_qid;
  return jsonb_build_object('a', (x->>'a')::int, 'text', x->>'q', 'o', x->'o', 'fact', x->>'f', 'pts', c.pts, 'sync', c.sync, 'hit', c.hit,
    'picks', (select coalesce(jsonb_object_agg(member, choice), '{}'::jsonb) from trivia_answers where event_id = p_event and couple_id = v and qid = p_qid),
    'state', trivia_state(p_code, p_member, p_event));
end $$;

-- "Buzz me before each question": per person, opt-in, stops by itself after 3 missed questions
create or replace function trivia_buzz_set(p_code text, p_member text, p_event text, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code);
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  if p_on then insert into trivia_buzz (event_id, couple_id, member) values (p_event, v, p_member) on conflict (event_id, couple_id, member) do update set on_at = now();
  else delete from trivia_buzz where event_id = p_event and couple_id = v and member = p_member; end if;
  return p_on;
end $$;
grant execute on function trivia_q(text, text, text, text), trivia_buzz_set(text, text, text, boolean) to anon, authenticated;

do $$ declare d text := pg_get_functiondef('trivia_state(text,text,text)'::regprocedure); a text := 'then return null; end if;'; begin
  if position('_tv_state' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception 'trivia_state anchor missing'; end if;
  execute regexp_replace(d, 'then return null; end if;\n  nq :=', 'then return null; end if;' || E'\n  if e.mode = ''clock'' then return _tv_state(e.id, v, p_member); end if;\n  nq :=');
  if position('_tv_state' in pg_get_functiondef('trivia_state(text,text,text)'::regprocedure)) = 0 then raise exception 'trivia_state not patched'; end if;
end $$;

-- build a clock night from the picked bank questions (easiest first, so rounds get harder)
create or replace function _tv_build(p_id text, p_title text, p_starts timestamptz, p_prize boolean, p_max int, p_status text, p_movie jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q jsonb; ends timestamptz; mine int[];
begin
  mine := case when coalesce(p_max, 30) <= 10 then array[5] else array[5, 15, 25] end;
  select jsonb_agg(jsonb_build_object('id', 'b' || b.pick_order, 'q', b.question, 'o', to_jsonb(o.arr), 'a', array_position(o.arr, b.answer) - 1,
      'cat', b.category, 'rate', b.correct_rate, 'mine', b.pick_order = any(mine)) order by b.pick_order)
    into q
  from trivia_bank b
  cross join lateral (select array_agg(t order by md5(t || b.id)) arr from unnest(array[b.answer, b.opts->>0, b.opts->>1]) t) o
  where b.pick_order is not null and b.pick_order <= coalesce(p_max, 30) and jsonb_array_length(b.opts) >= 2;
  if q is null or jsonb_array_length(q) < coalesce(p_max, 30) then raise exception 'not enough questions picked'; end if;
  insert into trivia_events (id, title, starts_at, ends_at, movie, per_round, gap_min, q, status, prize, max_q, mode, pushed)
  values (p_id, p_title, p_starts, p_starts + interval '2 hours', p_movie, 10, 30, q, p_status, p_prize, p_max, 'clock', '{}')
  on conflict (id) do update set title = excluded.title, starts_at = excluded.starts_at, movie = excluded.movie, per_round = 10, q = excluded.q,
    status = excluded.status, prize = excluded.prize, max_q = excluded.max_q, mode = 'clock', pushed = '{}';
  select max(close_at) + interval '90 seconds' into ends from _tv_sched(p_id);
  update trivia_events set ends_at = ends where id = p_id;
  return jsonb_build_object('id', p_id, 'starts', p_starts, 'ends', ends, 'questions', jsonb_array_length(q));
end $$;

create or replace function _tv_send(p_code text, p_title text, p_body text, p_url text, p_kind text default 'event', p_to text default null, p_extra jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(url := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/nudge', timeout_milliseconds := 30000, headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('kind', p_kind, 'code', p_code, 'member', '-', 'title', p_title, 'body', p_body, 'url', p_url) || case when p_to is not null then jsonb_build_object('to', p_to) else '{}'::jsonb end || p_extra);
end $$;

-- the minute job: old-style nights as before; clock nights get a start push, opt-in buzzes, and the prize at the end
create or replace function _trivia_tick() returns integer
language plpgsql security definer set search_path = public as $$
declare e record; r record; n int := 0; k text; t text; b text; s record; last_close timestamptz; w record;
begin
  for e in select * from trivia_events where status = 'ready' and mode <> 'clock' and starts_at <= now() and ends_at > now() loop
    k := case when not e.pushed ? 'start' then 'start' when not e.pushed ? 'half' and now() >= e.starts_at + make_interval(mins => e.gap_min * 2) then 'half' end;
    continue when k is null;
    update trivia_events set pushed = pushed || jsonb_build_object(k, now()) where id = e.id;
    t := case k when 'start' then 'Trivia night is on' else 'Trivia night: halfway' end;
    b := case k when 'start' then 'Round 1 is open. Press play on ' || coalesce(e.movie->>'title', 'the movie') || ', grab your other half, and tap in when you’re both ready.' else 'Round 3 just opened. Earlier rounds are still there if you’re catching up.' end;
    for r in select c.code from couples c where exists (select 1 from members m where m.couple_id = c.id) loop
      perform _tv_send(r.code, t, b, './?trivia=' || e.id, 'extra'); n := n + 1;
    end loop;
  end loop;

  for e in select * from trivia_events where status in ('ready', 'test') and mode = 'clock' and starts_at <= now() + interval '2 minutes' and ends_at + interval '30 minutes' > now() loop
    -- start: one push to every couple (test nights: only the host and test couples)
    if not e.pushed ? 'start' and now() >= e.starts_at - interval '1 minute' and now() < e.starts_at + interval '5 minutes' then
      update trivia_events set pushed = pushed || jsonb_build_object('start', now()) where id = e.id;
      for r in select c.code, (select count(*) from members m where m.couple_id = c.id) k from couples c
               where exists (select 1 from members m where m.couple_id = c.id) and (e.status = 'ready' or c.code = 'G9BKZF5C' or _is_test(c.id)) loop
        perform _tv_send(r.code, e.title || ' is starting', 'Question 1 in 3 minutes, on every phone at once. ' || case when r.k < 2 then 'Play along solo.' else 'Sit together: you answer as a team.' end, './?trivia=' || e.id);
        n := n + 1;
      end loop;
    end if;
    -- opt-in buzz about a minute before each question
    for s in select * from _tv_sched(e.id) x where x.show_at > now() + interval '15 seconds' and x.show_at <= now() + interval '75 seconds' and not e.pushed ? ('b' || x.n) loop
      update trivia_events set pushed = pushed || jsonb_build_object('b' || s.n, now()) where id = e.id;
      for w in select bz.*, c.code from trivia_buzz bz join couples c on c.id = bz.couple_id where bz.event_id = e.id loop
        -- three questions in a row with no answer: stop buzzing them
        if (select count(*) from _tv_sched(e.id) z where z.close_at < now() and z.close_at > w.on_at) >= 3
           and not exists (select 1 from trivia_answers ta, (select qid from _tv_sched(e.id) z where z.close_at < now() order by z.n desc limit 3) l
                           where ta.event_id = e.id and ta.couple_id = w.couple_id and ta.member = w.member and ta.qid = l.qid) then
          delete from trivia_buzz where event_id = e.id and couple_id = w.couple_id and member = w.member; continue;
        end if;
        perform _tv_send(w.code, 'Question ' || s.n || ' in about a minute', e.title || ' · Round ' || s.rnd || '. Grab your partner.', './?trivia=' || e.id, '', w.member,
          jsonb_build_object('noinbox', true, 'tag', 'tv-' || e.id, 'ttl', 90));
        n := n + 1;
      end loop;
    end loop;
    -- the end: prize to the top couple that can win it, one "final scores" note to every team that played
    select max(close_at) into last_close from _tv_sched(e.id);
    if not e.pushed ? 'final' and now() > last_close + interval '5 seconds' then
      update trivia_events set pushed = pushed || jsonb_build_object('final', now()) where id = e.id;
      if e.prize and e.status = 'ready' then
        perform _trivia_prize_award(e.id, (select cp.id from couples cp
          cross join lateral (select coalesce(sum(x.pts), 0) pts, count(*) filter (where x.sync) sy, avg(x.ms) ms from _tv_score(e.id, cp.id) x) sc
          where exists (select 1 from trivia_answers ta where ta.event_id = e.id and ta.couple_id = cp.id) and not _is_test(cp.id)
            and coalesce((cp.settings->>'trivia_host')::boolean, false) = false and (select count(*) from members m where m.couple_id = cp.id) >= 2 and sc.pts > 0
          order by sc.pts desc, sc.sy desc, coalesce(sc.ms, 1e9) limit 1));
      end if;
      for r in select c.code from couples c where exists (select 1 from trivia_answers ta where ta.event_id = e.id and ta.couple_id = c.id) loop
        perform _tv_send(r.code, 'Final scores are in', 'See where you two finished in ' || e.title || '.', './?trivia=' || e.id, '', null, jsonb_build_object('noinbox', true, 'tag', 'tv-' || e.id));
        n := n + 1;
      end loop;
    end if;
  end loop;
  return n;
end $$;

-- The result (Mon 24 Nov 11:30am for the week's vote; Fri 27 Nov 11:30am for the Friday try).
-- 3+ couples: the full clock night with the prize. Short on the week's vote: no warm-up, the night moves to a Friday try announced Wednesday.
-- Short on Friday too: a 10-question warm-up Friday night.
create or replace function _trivia_finalize(p_poll text default 'trivia-1') returns jsonb
language plpgsql security definer set search_path = public as $$
declare p polls; day jsonb; tm text; mv jsonb; yes int; no int; st timestamptz; c cards; teams int; r record; full_night boolean; fri boolean := p_poll like 'trivia-fri-%'; fri_d date; built jsonb; dl text;
begin
  select * into p from polls where id = p_poll; if p.id is null then return null; end if;
  select count(*) filter (where choice <> 'no'), count(*) filter (where choice = 'no') into yes, no from poll_votes where not _is_test(couple_id) and poll_id = p_poll;
  teams := _trivia_teams(p_poll); full_night := teams >= 3;
  select o->>'k' into tm from polls x, jsonb_array_elements(x.options) with ordinality t(o, i) where x.id = 'trivia-1-time'
    order by (select count(*) from poll_votes where not _is_test(couple_id) and poll_id = x.id and choice = o->>'k') desc, (o->>'k' = '20:00') desc, i limit 1;
  select o into mv from polls x, jsonb_array_elements(x.options) with ordinality t(o, i) where x.id = 'trivia-1-movie'
    order by (select count(*) from poll_votes where not _is_test(couple_id) and poll_id = x.id and choice = o->>'k') desc, i limit 1;
  dl := to_char(('2000-01-01 ' || coalesce(tm, '20:00'))::timestamp, 'FMHH12:MI') || case when coalesce(tm, '20:00') >= '12:00' then 'pm' else 'am' end;

  if not fri and not full_night then
    -- move to Friday: no warm-up on the voted night
    fri_d := (select d from generate_series(current_date + 1, current_date + 7, interval '1 day') d where extract(isodow from d) = 5 limit 1);
    insert into polls (id, title, body, options, opens_at, closes_at, pushed)
    values ('trivia-fri-1', 'Friday trivia night?', 'Every couple a team, 30 questions in an hour. We need 3 couples for the $25 Amazon gift card. Are you two in?',
      jsonb_build_array(jsonb_build_object('k', 'in', 't', 'We’re in, ' || to_char(fri_d, 'FMDay, Mon FMDD') || ' at ' || dl, 'd', fri_d::text), jsonb_build_object('k', 'no', 't', 'Can’t make it')),
      ((fri_d - 2)::text || ' 19:25')::timestamp at time zone 'America/New_York', (fri_d::text || ' 11:30')::timestamp at time zone 'America/New_York', '{}')
    on conflict (id) do nothing;
    for r in select cp.code, (select count(*) from members m where m.couple_id = cp.id) k from couples cp
             where exists (select 1 from poll_votes v where v.poll_id = p_poll and v.couple_id = cp.id and v.choice <> 'no') loop
      perform _tv_send(r.code, 'Trivia moves to Friday',
        'We had ' || teams || ' of the 3 couples we need, so the night you voted for is off. Wednesday we’ll ask about Friday. Invite a couple before then.',
        case when r.k < 2 then './?invite=1' else './?tell=1' end);
    end loop;
    perform cron.schedule('welike-trivia-fri-ask', '30 0 ' || extract(day from fri_d - 1)::int || ' ' || extract(month from fri_d - 1)::int || ' *', 'select public._trivia_fri_ask(''trivia-fri-1'')');
    perform cron.schedule('welike-trivia-fri-final', '30 16 ' || extract(day from fri_d)::int || ' ' || extract(month from fri_d)::int || ' *', 'select public._trivia_finalize(''trivia-fri-1''); select cron.unschedule(''welike-trivia-fri-final'');');
    perform _tv_send('G9BKZF5C', 'Trivia moves to Friday', teams || ' couple(s) signed up, not counting you two or solo players. Wednesday 7:30pm asks everyone about ' || to_char(fri_d, 'FMDay, Mon FMDD') || '.', './', '', 'Davy');
    return jsonb_build_object('created', false, 'moved', fri_d, 'teams', teams);
  end if;

  if fri then day := (select o from jsonb_array_elements(p.options) o where o->>'k' = 'in');
  else
    select o into day from jsonb_array_elements(p.options) with ordinality t(o, i) where o->>'k' <> 'no'
      order by (select count(*) from poll_votes where not _is_test(couple_id) and poll_id = p_poll and choice = o->>'k') desc, i limit 1;
  end if;
  st := ((day->>'d') || ' ' || coalesce(tm, '20:00'))::timestamp at time zone 'America/New_York';
  select * into c from cards where id = (mv->>'k')::uuid;
  built := _tv_build('trivia-1-night', case when full_night then 'Trivia night' else 'Trivia warm-up' end, st, full_night, case when full_night then null else 10 end, 'ready',
    case when mv is not null then jsonb_build_object('id', mv->>'k', 'title', mv->>'t', 'sub', mv->>'s', 'image', c.image) end);
  for r in select cp.code, (select count(*) from members m where m.couple_id = cp.id) k from couples cp where exists (select 1 from members m where m.couple_id = cp.id) loop
    perform _tv_send(r.code,
      case when full_night then 'Trivia night is set' else 'Trivia: a warm-up first' end,
      to_char(st at time zone 'America/New_York', 'FMDay') || ' at ' || dl || ': ' ||
      case when full_night then '30 questions in an hour, every couple a team. Top couple wins the $25 Amazon gift card.' || case when r.k < 2 then ' Solo players can play, but the prize is for couples.' else '' end
           else 'we had ' || teams || ' of 3 couples, so it’s a 10-question warm-up. Invite a couple and the prize night is next.' end,
      './?trivia=trivia-1-night');
  end loop;
  perform _tv_send('G9BKZF5C', case when full_night then 'Trivia night is set' else 'Trivia: warm-up only' end,
    teams || ' couple(s) signed up, not counting you two or solo players. ' || to_char(st at time zone 'America/New_York', 'FMDay, Mon FMDD') || ' at ' || dl || '.', './?trivia=trivia-1-night', '', 'Davy');
  return jsonb_build_object('created', true, 'full', full_night, 'teams', teams, 'starts', st, 'movie', mv->>'t', 'yes', yes, 'no', no) || built;
end $$;

-- Wednesday 7:30pm: ask everyone about Friday; the live "we made it" watch switches to the Friday sign-up
create or replace function _trivia_fri_ask(p_poll text default 'trivia-fri-1') returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; p polls; teams int;
begin
  perform cron.unschedule('welike-trivia-fri-ask');
  select * into p from polls where id = p_poll; if p.id is null then return 0; end if;
  teams := _trivia_teams(p_poll);
  for r in select cp.code, (select count(*) from members m where m.couple_id = cp.id) k from couples cp where exists (select 1 from members m where m.couple_id = cp.id) loop
    perform _tv_send(r.code, 'Friday trivia night?',
      case when r.k < 2 then 'Couples play for a $25 Amazon gift card. You can play solo, but get your partner in to play for it.'
           else 'We need 3 couples for the $25 Amazon gift card night' || case when teams > 0 then ' and have ' || teams else '' end || '. Tap if you two are in.' end,
      case when r.k < 2 then './?invite=1' else './?poll=' || p_poll end);
    n := n + 1;
  end loop;
  perform cron.schedule('welike-trivia-watch', '*/10 * * * *', 'select public._trivia_watch(''' || p_poll || ''')');
  return n;
end $$;

-- the watch now stops when its poll closes (was a fixed date)
create or replace function _trivia_watch(p_poll text default 'trivia-1') returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; p polls;
begin
  select * into p from polls where id = p_poll;
  if p.id is null or now() > p.closes_at then perform cron.unschedule('welike-trivia-watch'); return 0; end if;
  if p.pushed ? 'made_it' then return 0; end if;
  if _trivia_teams(p_poll) < 3 then return 0; end if;
  update polls set pushed = coalesce(pushed, '{}'::jsonb) || jsonb_build_object('made_it', now()) where id = p_poll;
  for r in select cp.code, (select count(*) from members m where m.couple_id = cp.id) k from couples cp where exists (select 1 from members m where m.couple_id = cp.id) loop
    perform _tv_send(r.code, 'Trivia night is on!',
      case when r.k < 2 then '3 couples are in for the $25 Amazon gift card night. Get your partner in and you two can play for it too.'
           else '3 couples are in, so the $25 Amazon gift card is up for grabs. ' || case when p_poll like 'trivia-fri-%' then 'Tap if you’re in for Friday.' else 'Vote on the night if you haven’t yet.' end end,
      case when r.k < 2 then './?invite=1' else './?poll=' || p_poll end);
    n := n + 1;
  end loop;
  return n;
end $$;

-- schedule fix: voting closes Sunday 22 Nov 11:59pm ET, so last call is Sunday 7:30pm and the result Monday 23 Nov 11:30am ET
select cron.schedule('welike-trivia-lastcall', '30 0 23 11 *', 'select public._trivia_last_call(''trivia-1'')');
select cron.schedule('welike-trivia-finalize', '30 16 23 11 *', 'select public._trivia_finalize(''trivia-1''); select cron.unschedule(''welike-trivia-finalize'');');

-- Applied after (migrations trivia_clock_practice, trivia_board_first_names):
--  * _trivia_tick: a test night's start push goes to Davy only.
--  * practice-clock: a 10-question test night for Davy and Kelsey, Thu 19 Nov 9pm ET, from bank questions the real night doesn't use.
--  * _tv_board: a couple with no team name shows as their first names ("Maya & Jordan").
