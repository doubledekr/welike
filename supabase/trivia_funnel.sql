-- Trivia sign-up funnel (Dave's go, 19 Nov 2026): a couple counts only when BOTH partners say they're in.
create table if not exists trivia_rsvp (poll_id text not null, couple_id uuid not null, member text not null, at timestamptz not null default now(), primary key (poll_id, couple_id, member));
create table if not exists trivia_nudged (poll_id text not null, couple_id uuid not null, member text not null, kind text not null, at timestamptz not null default now(), primary key (poll_id, couple_id, member, kind));
alter table trivia_rsvp enable row level security;
alter table trivia_nudged enable row level security;

-- the person who votes for a night is in; "Not this time" clears the couple
create or replace function _trivia_vote_rsvp() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.poll_id !~ '^trivia-(1|fri-1)$' then return new; end if;
  if new.choice = 'no' then delete from trivia_rsvp where poll_id = new.poll_id and couple_id = new.couple_id;
  else insert into trivia_rsvp (poll_id, couple_id, member) values (new.poll_id, new.couple_id, new.by_member) on conflict do nothing; end if;
  return new;
end $$;
drop trigger if exists trivia_vote_rsvp on poll_votes;
create trigger trivia_vote_rsvp after insert or update on poll_votes for each row execute function _trivia_vote_rsvp();
insert into trivia_rsvp (poll_id, couple_id, member) select poll_id, couple_id, by_member from poll_votes where poll_id in ('trivia-1', 'trivia-fri-1') and choice <> 'no' and by_member is not null on conflict do nothing;

-- a couple counts when both partners are in (host and test couples never count)
create or replace function _trivia_teams(p_poll text) returns integer language sql stable security definer set search_path = public as $$
  select count(*)::int from couples cp
  where exists (select 1 from poll_votes v where v.poll_id = p_poll and v.couple_id = cp.id and v.choice <> 'no')
    and not _is_test(cp.id) and coalesce((cp.settings->>'trivia_host')::boolean, false) = false
    and (select count(*) from members m where m.couple_id = cp.id) >= 2
    and (select count(*) from members m where m.couple_id = cp.id and exists (select 1 from trivia_rsvp r where r.poll_id = p_poll and r.couple_id = cp.id and r.member = m.name)) >= 2 $$;

-- the trivia poll that matters right now: Friday's once it exists, else the week's
create or replace function _trivia_poll_now() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select id from polls where id = 'trivia-fri-1'), (select id from polls where id = 'trivia-1')) $$;

-- everything the Home banner and the "get ready" checklist need, for one person
create or replace function trivia_funnel(p_code text, p_member text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v uuid := _couple(p_code); p polls; ch text; ev trivia_events; ms text[]; ins text[];
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then return null; end if;
  select * into p from polls where id = _trivia_poll_now();
  if p.id is null then return null; end if;
  select * into ev from trivia_events where id = 'trivia-1-night' and status = 'ready';
  if p.closes_at < now() - interval '1 day' and ev.id is null then return null; end if;
  if ev.id is not null and ev.ends_at < now() then return null; end if;
  select choice into ch from poll_votes where poll_id = p.id and couple_id = v;
  select array_agg(name order by created_at) into ms from members where couple_id = v;
  select array_agg(member) into ins from trivia_rsvp where poll_id = p.id and couple_id = v;
  return jsonb_build_object('poll', p.id, 'title', p.title, 'open', p.opens_at <= now() and p.closes_at > now(), 'opens', p.opens_at, 'closes', p.closes_at,
    'fri', p.id = 'trivia-fri-1', 'teams', _trivia_teams(p.id), 'need', 3,
    'choice', ch, 'night', (select o->>'t' from jsonb_array_elements(p.options) o where o->>'k' = ch),
    'members', to_jsonb(ms), 'in', coalesce(to_jsonb(ins), '[]'::jsonb),
    'installed', (select installed_at is not null from members where couple_id = v and name = p_member),
    'host', coalesce((select (settings->>'trivia_host')::boolean from couples where id = v), false) or _is_test(v),
    'event', case when ev.id is not null then jsonb_build_object('id', ev.id, 'title', ev.title, 'starts', ev.starts_at, 'prize', ev.prize) end);
end $$;

-- "I'm in" / "I'm out" for the partner who didn't vote
create or replace function trivia_rsvp_set(p_code text, p_member text, p_in boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := _couple(p_code); pid text := _trivia_poll_now(); p polls; was int; now_in int;
begin
  if v is null or not exists (select 1 from members where couple_id = v and name = p_member) then raise exception 'bad_code'; end if;
  select * into p from polls where id = pid;
  if p.id is null or p.closes_at <= now() then raise exception 'closed'; end if;
  if not exists (select 1 from poll_votes where poll_id = pid and couple_id = v and choice <> 'no') then raise exception 'no_vote'; end if;
  was := _trivia_teams(pid);
  if p_in then insert into trivia_rsvp (poll_id, couple_id, member) values (pid, v, p_member) on conflict do nothing;
  else delete from trivia_rsvp where poll_id = pid and couple_id = v and member = p_member; end if;
  return trivia_funnel(p_code, p_member);
end $$;
grant execute on function trivia_funnel(text, text), trivia_rsvp_set(text, text, boolean) to anon, authenticated;

-- one gentle nudge per open checklist row, at most two per person all week, never at night
create or replace function _trivia_checklist_nudge() returns integer
language plpgsql security definer set search_path = public as $$
declare pid text := _trivia_poll_now(); p polls; r record; n int := 0; h int := extract(hour from now() at time zone 'America/New_York');
begin
  if h < 11 or h >= 20 then return 0; end if;
  select * into p from polls where id = pid; if p.id is null or p.closes_at <= now() or p.opens_at > now() then return 0; end if;
  for r in
    select cp.id, cp.code, m.name, v.by_member, v.at,
      (select count(*) from members x where x.couple_id = cp.id) k,
      exists (select 1 from trivia_rsvp t where t.poll_id = pid and t.couple_id = cp.id and t.member = m.name) me_in
    from poll_votes v join couples cp on cp.id = v.couple_id join members m on m.couple_id = cp.id
    where v.poll_id = pid and v.choice <> 'no' and v.at < now() - interval '20 hours' and not _is_test(cp.id) and coalesce((cp.settings->>'trivia_host')::boolean, false) = false
  loop
    continue when (select count(*) from trivia_nudged z where z.poll_id = pid and z.couple_id = r.id and z.member = r.name) >= 2;
    if not r.me_in and not exists (select 1 from trivia_nudged z where z.poll_id = pid and z.couple_id = r.id and z.member = r.name and z.kind = 'confirm') then
      insert into trivia_nudged values (pid, r.id, r.name, 'confirm');
      perform _tv_send(r.code, r.by_member || ' signed you two up for trivia', 'You only count as a team once you both say you’re in. Tap to say you’re in.', './?trivia_in=1', 'event', r.name);
      n := n + 1;
    elsif r.k < 2 and r.name = r.by_member and not exists (select 1 from trivia_nudged z where z.poll_id = pid and z.couple_id = r.id and z.member = r.name and z.kind = 'partner') then
      insert into trivia_nudged values (pid, r.id, r.name, 'partner');
      perform _tv_send(r.code, 'Get your partner in for trivia', 'You can play solo, but the $25 Amazon gift card is for couples. Joining takes them a minute.', './?invite=1&t=1', 'event', r.name);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
select cron.schedule('welike-trivia-checklist', '7 * * * *', 'select public._trivia_checklist_nudge()');

-- the week's pushes: a couple that voted but isn't both-in hears that, not "you're in"
do $$ declare d text; f text; b text;
begin
  foreach f in array array['_trivia_need_push', '_trivia_last_call'] loop
    d := pg_get_functiondef(f::regproc);
    b := case f when '_trivia_need_push' then 'when r.voted then ''You’re in.' else 'when r.voted then ''We need ' end;
    if position('and v.choice <> ''no'') voted' in d) = 0 or position(b in d) = 0 or position('when r.voted then ''./?tell=1''' in d) = 0 then raise exception '% anchor', f; end if;
    d := replace(d, 'and v.choice <> ''no'') voted', 'and v.choice <> ''no'') voted, (select count(*) from trivia_rsvp t where t.poll_id = p_poll and t.couple_id = cp.id) >= 2 both_in');
    d := replace(d, b, 'when r.voted and not r.both_in then ''You only count as a team once you both say you’re in. Open the trivia card on Home.'' ' || b);
    d := replace(d, 'when r.voted then ''./?tell=1''', 'when r.voted and not r.both_in then ''./?trivia_in=1'' when r.voted then ''./?tell=1''');
    execute d;
  end loop;
end $$;
