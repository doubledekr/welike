-- LIVE COPY, dumped from the live database 19 Nov 2026, 10:35pm ET (pg_get_functiondef). The real definitions of the
-- event card guard, sweep and check queue, which until now existed only in the live database (event_cards_quality.sql
-- holds notes only). Includes the 10:30pm changes (Dave: "do all recommended actions"):
--   * Viator / Ticketmaster cards only need a date to stay on (they carry no start time or venue).
--   * _tv_buzz_gate: the 5-second trivia buzz job exists only from 5 min before a clock night until 30 min after it.
-- Migration: audit_viator_dates_buzz_gate. Trigger and jobs are at the bottom.

CREATE OR REPLACE FUNCTION public._event_card_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare d jsonb := new.data || case when new.data ? 'date' or new.event_date is null then '{}'::jsonb else jsonb_build_object('date', new.event_date::text) end;
begin
  if coalesce((new.data ? 'place'), false) then return new; end if;
  if coalesce(new.created_by, '') in ('viator', 'tmevents', 'ticketmaster') then
    if d->>'date' is null then new.active := false; end if;
  elsif coalesce(new.created_by, '') <> 'wild' and (not _event_card_ok(d) or _event_needs_check(new.created_by, new.data)) then new.active := false; end if;
  if new.data->>'image_src' = 'site' and coalesce(new.data->>'url', '') ~ '^https?://[^/]+/?$' and not _event_site_is_venue(new.data) then
    new.image := null; new.data := new.data - 'image_src';
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public._event_card_ok(d jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ select (d->>'date') is not null
   and coalesce(d->>'time', '') ~* '\d{1,2}(:\d{2})?\s*(am|pm)'
   and length(trim(coalesce(nullif(d->>'venue', ''), d->>'address', ''))) > 2 $function$
;

CREATE OR REPLACE FUNCTION public._event_needs_check(p_by text, d jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ select not coalesce(d ? 'place', false)
         and coalesce(p_by, '') not in ('viator', 'tmevents', 'ticketmaster')
         and coalesce(d->'verify'->>'state', '') not in ('ok', 'fixed') $function$
;

CREATE OR REPLACE FUNCTION public._event_over(p_date date, p_time text, p_now timestamp without time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare m text[]; st int; fin int;
begin
  if p_date is null then return false; end if;
  if p_date < p_now::date then return true; end if;
  if p_date > p_now::date then return false; end if;
  m := regexp_match(lower(coalesce(p_time, '')), '(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*(?:-|to)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm))?');
  if m is null then return false; end if;
  st := ((m[1]::int % 12) + case when m[3] = 'pm' then 12 else 0 end) * 60 + coalesce(m[2]::int, 0);
  if m[4] is not null then
    fin := ((m[4]::int % 12) + case when m[6] = 'pm' then 12 else 0 end) * 60 + coalesce(m[5]::int, 0);
    if fin <= st then fin := 24 * 60; end if;
  else fin := st + 30; end if;
  return extract(hour from p_now)::int * 60 + extract(minute from p_now)::int > fin;
end $function$
;

CREATE OR REPLACE FUNCTION public._event_site_is_venue(d jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ select exists (
  select 1 from regexp_split_to_table(lower(coalesce(nullif(d->>'venue', ''), d->>'title', '')), '[^a-z0-9]+') w
  where length(w) >= 4 and w not in ('theater', 'theatre', 'cafe', 'club', 'park', 'hall', 'center', 'centre', 'house', 'room', 'detroit', 'music', 'live', 'downtown', 'lounge')
    and position(w in lower(regexp_replace(coalesce(d->>'url', ''), '^https?://(www\.)?([^/]+).*$', '\2'))) > 0) $function$
;

CREATE OR REPLACE FUNCTION public._eventcheck_apply(p_id uuid, p_res jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public._eventcheck_queue(p_n integer DEFAULT 6)
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare today date := (now() at time zone 'America/Detroit')::date;
begin
  return query
  with q as (
    select c.id from cards c
    where c.deck = 'event' and _event_needs_check(c.created_by, c.data)
      and _event_card_ok(c.data || jsonb_build_object('date', coalesce(c.data->>'date', c.event_date::text)))
      and coalesce(c.data->'verify'->>'state', '') <> 'unconfirmed'
      and coalesce((c.data->'verify'->>'tries')::int, 0) < 3
      and c.event_date between today and today + 14
      and not _event_over(c.event_date, c.data->>'time', (now() at time zone 'America/Detroit')::timestamp)
    order by c.event_date, c.created_at limit greatest(1, least(p_n, 12)))
  update cards c set data = jsonb_set(c.data, '{verify}', coalesce(c.data->'verify', '{}'::jsonb)
           || jsonb_build_object('tries', coalesce((c.data->'verify'->>'tries')::int, 0) + 1, 'asked', now()))
  from q where c.id = q.id returning c.id;
end $function$
;

CREATE OR REPLACE FUNCTION public._events_sweep()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int;
begin
  update cards c set active = false from couples k
  where k.id = c.couple_id and c.deck = 'event' and c.active and not (c.data ? 'place')
    and _event_over(c.event_date, c.data->>'time', (now() at time zone _zip_tz(k.settings->>'zip'))::timestamp);
  get diagnostics n = row_count;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public._tv_buzz_gate()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare live boolean; has boolean;
begin
  select exists (select 1 from trivia_events where status in ('ready', 'test') and mode = 'clock'
                 and starts_at <= now() + interval '5 minutes' and ends_at + interval '30 minutes' > now()) into live;
  select exists (select 1 from cron.job where jobname = 'welike-trivia-buzz') into has;
  if live and not has then perform cron.schedule('welike-trivia-buzz', '5 seconds', 'select public._tv_buzz_tick()'); return 'on'; end if;
  if not live and has then perform cron.unschedule('welike-trivia-buzz'); return 'off'; end if;
  return case when live then 'on' else 'off' end;
end $function$
;

-- Trigger (live): CREATE TRIGGER event_card_guard BEFORE INSERT OR UPDATE OF data, image, active ON public.cards
--   FOR EACH ROW WHEN ((new.deck = 'event'::text)) EXECUTE FUNCTION _event_card_guard();
-- Jobs (live): welike-events-sweep */10 * * * * select public._events_sweep();
--   welike-eventcheck 3-59/10 * * * * (net.http_post to the eventcheck edge function);
--   welike-trivia-buzz-gate * * * * * select public._tv_buzz_gate();  (adds/removes welike-trivia-buzz, '5 seconds')
