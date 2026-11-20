-- Event check (Dave, 19 Nov): events from listing sites and web finds are confirmed on the web before they are dealt.
-- Ticketing feeds (Viator, Ticketmaster) are trusted as they are. Places (data.place) are not events and are never held.
-- data.verify = { state: ok | fixed | unconfirmed, at, tries, note, sources, searches }

create or replace function public._event_needs_check(p_by text, d jsonb) returns boolean language sql immutable
as $$ select not coalesce(d ? 'place', false)
         and coalesce(p_by, '') not in ('viator', 'tmevents', 'ticketmaster')
         and coalesce(d->'verify'->>'state', '') not in ('ok', 'fixed') $$;

-- the guard: details to show up (date, time, where), a clean picture, and confirmed on the web
create or replace function public._event_card_guard() returns trigger language plpgsql
as $$
begin
  if coalesce((new.data ? 'place'), false) then return new; end if;
  if not _event_card_ok(new.data) or _event_needs_check(new.created_by, new.data) then new.active := false; end if;
  if new.data->>'image_src' = 'site' and coalesce(new.data->>'url', '') ~ '^https?://[^/]+/?$' and not _event_site_is_venue(new.data) then
    new.image := null; new.data := new.data - 'image_src';
  end if;
  return new;
end $$;

-- the next events to check: soonest first, within two weeks, at most 3 tries each
create or replace function public._eventcheck_queue(p_n int default 6) returns table(id uuid) language plpgsql security definer set search_path to 'public'
as $$
declare today date := (now() at time zone 'America/Detroit')::date;
begin
  return query
  with q as (
    select c.id from cards c
    where c.deck = 'event' and _event_needs_check(c.created_by, c.data) and _event_card_ok(c.data)
      and coalesce(c.data->'verify'->>'state', '') <> 'unconfirmed'
      and coalesce((c.data->'verify'->>'tries')::int, 0) < 3
      and c.event_date between today and today + 14
      and not _event_over(c.event_date, c.data->>'time', (now() at time zone 'America/Detroit')::timestamp)
    order by c.event_date, c.created_at limit greatest(1, least(p_n, 12)))
  update cards c set data = jsonb_set(c.data, '{verify}', coalesce(c.data->'verify', '{}'::jsonb)
           || jsonb_build_object('tries', coalesce((c.data->'verify'->>'tries')::int, 0) + 1, 'asked', now()))
  from q where c.id = q.id returning c.id;
end $$;

-- what the web search found: show it with corrected details, or keep it off
create or replace function public._eventcheck_apply(p_id uuid, p_res jsonb) returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare c cards; d jsonb; st text; nd date; today date := (now() at time zone 'America/Detroit')::date; v jsonb;
  ok_time boolean := coalesce(p_res->>'time', '') ~* '^\s*\d{1,2}(:\d{2})?\s*(am|pm)';
begin
  select * into c from cards where id = p_id; if c.id is null then return null; end if;
  d := c.data;
  begin nd := (p_res->>'date')::date; exception when others then nd := null; end;
  st := case when coalesce((p_res->>'found')::boolean, false) and coalesce((p_res->>'same_date')::boolean, false) then 'ok'
             when coalesce((p_res->>'found')::boolean, false) and nd is not null and nd >= today and nd <= today + 60 then 'fixed'
             else 'unconfirmed' end;
  if st in ('ok', 'fixed') then
    if st = 'fixed' then d := d || jsonb_build_object('date', nd::text); end if;
    if ok_time then d := d || jsonb_build_object('time', trim(p_res->>'time')); end if;
    if nullif(trim(p_res->>'venue'), '') is not null and coalesce(d->>'venue', '') = '' then d := d || jsonb_build_object('venue', trim(p_res->>'venue')); end if;
    if nullif(trim(p_res->>'address'), '') is not null then d := d || jsonb_build_object('address', trim(p_res->>'address')); end if;
    if nullif(trim(p_res->>'about'), '') is not null and coalesce(d->>'notes', '') = '' then d := d || jsonb_build_object('notes', left(trim(p_res->>'about'), 240)); end if;
    if nullif(trim(p_res->>'price'), '') is not null and coalesce(d->>'price', '') = '' then d := d || jsonb_build_object('price', left(trim(p_res->>'price'), 40)); end if;
    if coalesce(p_res->>'link', '') ~ '^https?://[^/]+/.+' and coalesce(d->>'url', '') !~ '^https?://[^/]+/.+' then d := d || jsonb_build_object('url', p_res->>'link'); end if;
  end if;
  v := coalesce(d->'verify', '{}'::jsonb) || jsonb_build_object('state', st, 'at', now(), 'note', left(coalesce(p_res->>'note', ''), 200),
         'sources', coalesce((select jsonb_agg(s) from (select s from jsonb_array_elements_text(coalesce(p_res->'sources', '[]'::jsonb)) s limit 4) x), '[]'::jsonb),
         'searches', coalesce((p_res->>'searches')::int, 0));
  d := jsonb_set(d, '{verify}', v);
  update cards set data = d,
    event_date = case when st = 'fixed' then nd else event_date end,
    subtitle = case when st in ('ok', 'fixed') then nullif(concat_ws(' · ', nullif(d->>'time', ''), nullif(d->>'venue', '')), '') else subtitle end,
    active = st in ('ok', 'fixed') and not _event_over(case when st = 'fixed' then nd else c.event_date end, d->>'time', (now() at time zone 'America/Detroit')::timestamp)
  where id = p_id;
  return jsonb_build_object('state', st, 'date', coalesce(nd::text, c.event_date::text), 'time', d->>'time');
end $$;

-- every 10 minutes, up to 6 events a run
select cron.schedule('welike-eventcheck', '3-59/10 * * * *', $c$select net.http_post(url := 'https://gbzximehndzlsbojoqgj.supabase.co/functions/v1/eventcheck', timeout_milliseconds := 150000, headers := jsonb_build_object('Content-Type','application/json','x-sync-key',(select value from app_secrets where key='sync_key')), body := '{"limit":6}'::jsonb)$c$);

-- Applied live 19 Nov 2026 (migrations eventcheck, eventcheck_wild_not_held, eventcheck_wild_fix). Later changes:
--  * "Found for this week" finds (created_by wild) are checked and corrected but never hidden; their date lives in cards.event_date.
--  * The guard and queue read the date from data.date or cards.event_date.
--  * eventcheck v2: tells the checker today's date; a listing on the venue's own site counts as a source;
--    when sources disagree on the time, the venue's own event page wins, and an unsure time means not confirmed.
