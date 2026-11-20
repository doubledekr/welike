-- Opt-in trivia buzz about 10 seconds before each question (Dave, 19 Nov 2026).
-- Its own job every 5 seconds; the minute job (_trivia_tick) no longer buzzes.

create or replace function public._tv_buzz_tick()
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare e record; s record; w record; n int := 0;
begin
  for e in select * from trivia_events where status in ('ready', 'test') and mode = 'clock'
             and starts_at <= now() + interval '4 minutes' and ends_at > now() loop
    for s in select * from _tv_sched(e.id) x where x.show_at > now() + interval '3 seconds' and x.show_at <= now() + interval '13 seconds'
               and not e.pushed ? ('b' || x.n) loop
      update trivia_events set pushed = pushed || jsonb_build_object('b' || s.n, now()) where id = e.id;
      for w in select bz.*, c.code from trivia_buzz bz join couples c on c.id = bz.couple_id where bz.event_id = e.id loop
        -- three questions in a row with no answer: stop buzzing them
        if (select count(*) from _tv_sched(e.id) z where z.close_at < now() and z.close_at > w.on_at) >= 3
           and not exists (select 1 from trivia_answers ta, (select qid from _tv_sched(e.id) z where z.close_at < now() order by z.n desc limit 3) l
                           where ta.event_id = e.id and ta.couple_id = w.couple_id and ta.member = w.member and ta.qid = l.qid) then
          delete from trivia_buzz where event_id = e.id and couple_id = w.couple_id and member = w.member; continue;
        end if;
        perform _tv_send(w.code, 'Question ' || s.n || ' in 10 seconds', e.title || ' · Round ' || s.rnd || '. Grab your partner.', './?trivia=' || e.id, '', w.member,
          jsonb_build_object('noinbox', true, 'tag', 'tv-' || e.id, 'ttl', 20));
        n := n + 1;
      end loop;
    end loop;
  end loop;
  return n;
end $$;

create or replace function public._trivia_tick()
 returns integer language plpgsql security definer set search_path to 'public'
as $function$
declare e record; r record; n int := 0; k text; t text; b text; last_close timestamptz;
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
               where exists (select 1 from members m where m.couple_id = c.id) and e.status = 'ready' loop
        perform _tv_send(r.code, e.title || ' is starting', 'Question 1 in 3 minutes, on every phone at once. ' || case when r.k < 2 then 'Play along solo.' else 'Sit together: you answer as a team.' end, './?trivia=' || e.id);
        n := n + 1;
      end loop;
      if e.status = 'test' then perform _tv_send('G9BKZF5C', e.title || ' is starting', 'Question 1 in 3 minutes. Practice run: only you two see it.', './?trivia=' || e.id, 'community', 'Davy'); end if;
    end if;
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
end $function$;

select cron.schedule('welike-trivia-buzz', '5 seconds', 'select public._tv_buzz_tick()');
