-- Applied live 19 Nov 2026 as migration trivia_sync_hardening (Dave's go).
-- trivia_sync: each phone's clock checks during a night (offset, round trip, why), so drift can be read afterwards.
-- trivia_now(...): returns clock_timestamp(); logs the phone's last measurement when p_event/p_off are given.
-- Grace for answers tapped in time but arriving late: 1.5 s (was 0.6) in trivia_answer;
-- trivia_reveal, _tv_score and _tv_state wait close + 1.6 s (was 0.7) so a late answer is always counted.
-- The function bodies were patched in place with replace() on pg_get_functiondef; see the live database for the full text.

create table if not exists public.trivia_sync (
  id bigint generated always as identity primary key,
  event_id text, couple_id uuid, member text, at timestamptz default now(),
  off_ms int, rtt_ms int, why text, ua text);
alter table public.trivia_sync enable row level security;
create index if not exists trivia_sync_event on public.trivia_sync (event_id, at);

create or replace function public.trivia_now(p_code text default null, p_member text default null, p_event text default null,
  p_off int default null, p_rtt int default null, p_why text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v uuid;
begin
  if p_event is not null and p_off is not null and p_code is not null then
    v := _couple(p_code);
    if v is not null and exists (select 1 from trivia_events where id = p_event and ends_at > now() - interval '10 minutes' and starts_at < now() + interval '20 minutes') then
      insert into trivia_sync (event_id, couple_id, member, off_ms, rtt_ms, why)
      values (p_event, v, left(p_member, 40), p_off, p_rtt, left(p_why, 20));
    end if;
  end if;
  return jsonb_build_object('now', clock_timestamp());
end $$;
grant execute on function public.trivia_now(text, text, text, int, int, text) to anon, authenticated;
