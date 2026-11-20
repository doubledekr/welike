-- Trivia night cadence (Dave, 19 Nov 2026): 10 s to read, 4 s to answer, 30 s until the next question.
-- One question every 44 s; 3 min welcome; 3 min board after each round of 10. 30 questions end at about 31 min.

create or replace function public._tv_read_s(t text)
 returns integer language sql immutable
as $$ select 10 $$;

create or replace function public._tv_sched(p_event text)
 returns table(n integer, qid text, rnd integer, show_at timestamptz, open_at timestamptz, close_at timestamptz, mine boolean)
 language sql stable security definer set search_path to 'public'
as $$
  select t.i::int, t.x->>'id', ((t.i - 1) / e.per_round)::int + 1,
    e.starts_at + make_interval(secs => 180 + (t.i - 1) * 44 + ((t.i - 1) / e.per_round) * 180),
    e.starts_at + make_interval(secs => 180 + (t.i - 1) * 44 + ((t.i - 1) / e.per_round) * 180 + _tv_read_s(t.x->>'q')),
    e.starts_at + make_interval(secs => 180 + (t.i - 1) * 44 + ((t.i - 1) / e.per_round) * 180 + _tv_read_s(t.x->>'q') + 4),
    coalesce((t.x->>'mine')::boolean, false)
  from trivia_events e, jsonb_array_elements(e.q) with ordinality t(x, i)
  where e.id = p_event and (e.max_q is null or t.i <= e.max_q)
$$;

-- every clock night not yet started gets its end time from the new schedule
update trivia_events e set ends_at = (select max(close_at) + interval '90 seconds' from _tv_sched(e.id))
where e.mode = 'clock' and e.starts_at > now();
