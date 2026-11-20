-- Viator bookings back into plans (beta, Dave 20 Nov). Tables viator_tags, viator_bookings, viator_sync and viator_tag(),
-- viator_time() are in migration viator_bookings. This file holds the current _viator_apply.
create or replace function _viator_apply(e jsonb) returns text language plpgsql security definer set search_path to 'public' as $$
declare tg viator_tags; v_ref text := coalesce(e->>'transactionRef', e->>'bookingRef'); ev text := upper(coalesce(e->>'eventType', '')); d date := nullif(e->>'travelDate', '')::date;
  c record; v_city text; uid uuid; fp fr_plans; cancel boolean; old viator_bookings; tm text := nullif(e->>'travelTime', ''); item jsonb; m jsonb; k text; cents int; cl uuid[]; costid uuid;
begin
  if v_ref is null then return 'noref'; end if;
  select * into tg from viator_tags where tag = e->>'campaignValue'; if not found then return 'not_ours'; end if;
  cancel := ev in ('CANCELLATION', 'CUSTOMER_CANCELLATION', 'REJECTION');
  select * into old from viator_bookings b where b.ref = v_ref;
  select id, title, kind, data into c from cards where ext_id = e->>'productCode' and deck = 'trip' order by couple_id nulls first limit 1;
  if c.id is null then select id, title, kind, data into c from cards where ext_id = e->>'productCode' and couple_id = tg.couple_id limit 1; end if;
  v_city := coalesce(c.kind, c.data->>'city');
  tm := coalesce(tm, old.travel_time);
  -- take it out of wherever it was, then put it back (handles date changes and cancellations)
  if old.ref is not null then
    if old.fr_plan is not null then
      update fr_plans set data = jsonb_set(data, '{booked}', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(data->'booked', '[]')) x where x->>'ref' <> v_ref), '[]')) where id = old.fr_plan;
      if old.cost_id is not null then delete from fr_costs where id = old.cost_id; end if;
    end if;
    if old.city is not null then
      update couples set settings = jsonb_set(settings, array['plan_meta', old.city, 'booked'], coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(settings->'plan_meta'->old.city->'booked', '[]')) x where x->>'ref' <> v_ref), '[]'))
      where id = old.couple_id and settings->'plan_meta' ? old.city;
    end if;
  end if;
  insert into viator_bookings as b (ref, tag, couple_id, member, product, card, travel_date, travel_time, status, price, currency, raw, updated_at)
  values (v_ref, tg.tag, tg.couple_id, tg.member, e->>'productCode', c.id, d, tm, ev, nullif(e->>'totalPrice', '')::numeric, e->>'currency', e, now())
  on conflict on constraint viator_bookings_pkey do update set travel_date = excluded.travel_date, travel_time = excluded.travel_time, status = excluded.status, price = coalesce(excluded.price, b.price),
    card = coalesce(excluded.card, b.card), raw = excluded.raw, updated_at = now(), fr_plan = null, city = null, cost_id = null;
  if cancel or d is null then return 'removed'; end if;
  item := jsonb_build_object('ref', v_ref, 'product', e->>'productCode', 'title', coalesce(c.title, 'Booked on Viator'), 'card', c.id, 'day', d, 'time', tm, 'minutes', nullif(c.data->>'minutes', '')::int, 'where', v_city, 'by', tg.member);
  -- a group trip this person is in, covering that day: the booking goes into its itinerary and its bill split
  select m2.user_id into uid from members m2 where m2.couple_id = tg.couple_id and m2.name = tg.member;
  if uid is not null then
    select p.* into fp from fr_plans p join fr_plan_members pm on pm.plan = p.id and pm.person = uid and pm.status = 'in'
      where p.day_from is not null and d between p.day_from - 1 and p.day_from + case when p.kind = 'trip' then 4 else 0 end and (v_city is null or p.city is null or lower(p.city) = lower(v_city))
      order by abs(d - p.day_from) limit 1;
    if fp.id is not null then
      update fr_plans set data = jsonb_set(data, '{booked}', coalesce(data->'booked', '[]') || item) where id = fp.id;
      cents := round(coalesce(nullif(e->>'totalPrice', '')::numeric, 0) * 100);
      if cents > 0 then
        select array_agg(person) into cl from fr_plan_members where plan = fp.id and status = 'in';
        insert into fr_costs (plan, label, cents, payer, mode, claims) values (fp.id, left(coalesce(c.title, 'Viator booking'), 60), cents, uid, 'claim', cl) returning id into costid;
      end if;
      update viator_bookings b set fr_plan = fp.id, cost_id = costid where b.ref = v_ref;
      return 'group';
    end if;
  end if;
  -- the couple's own trip to that city, covering that day
  select settings->'plan_meta' into m from couples where id = tg.couple_id;
  for k in select key from jsonb_each(coalesce(m, '{}')) loop
    if (v_city is null or lower(k) = lower(v_city)) and (m->k->>'from') is not null and d between (m->k->>'from')::date and coalesce((m->k->>'to')::date, (m->k->>'from')::date + 7) then
      update couples set settings = jsonb_set(settings, array['plan_meta', k, 'booked'], coalesce(settings->'plan_meta'->k->'booked', '[]') || item) where id = tg.couple_id;
      update viator_bookings b set city = k where b.ref = v_ref;
      return 'trip';
    end if;
  end loop;
  return 'kept';
end $$;
revoke all on function _viator_apply(jsonb) from public, anon, authenticated;
