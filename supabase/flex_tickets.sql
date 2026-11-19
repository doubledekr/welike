-- Open-date Viator tickets (data.flex = true) (Dave, 19 Nov: "I don't want duplicate things or wrong days").
-- A flex ticket can be used any day; the date on the card is only when it was listed. So:
--   * no duplicates: if the couple already has the place itself as a card ("Museum of Illusions Detroit"), the ticket
--     ("Museum of Illusions Detroit Admission Ticket") stays out of their piles and their automatic plans
--   * automatic plans never use the ticket when the couple has the place card (the place card carries hours, the ticket does not)
-- The app already shows a flex ticket as "This week", and the "Tomorrow" reminder skips it (_plan_tick, 19 Nov).
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public._pick(uuid,uuid,text,jsonb,integer,text,boolean)'::regprocedure);
  d2 := replace(d, $a$      and not exists (select 1 from session_cards sc where sc.session_id = p_session and sc.card_id = c.id)$a$,
                   $a$      and not exists (select 1 from session_cards sc where sc.session_id = p_session and sc.card_id = c.id)
      and not (p_deck = 'event' and coalesce((c.data->>'flex')::boolean, false) and exists (select 1 from cards pc where pc.couple_id = p_couple and pc.deck = 'event'
               and pc.active and pc.data ? 'place' and length(pc.title) >= 6 and lower(c.title) like lower(pc.title) || '%'))$a$);
  if d2 = d then raise exception '_pick flex anchor'; end if;
  execute d2;

  d := pg_get_functiondef('public._ap_pick'::regproc);
  d2 := replace(d, $a$when 'day' then c.couple_id = p_couple and c.deck = 'event' and c.kind <> 'Bar' and ((c.data ? 'place') or c.event_date = p_day)$a$,
                   $a$when 'day' then c.couple_id = p_couple and c.deck = 'event' and c.kind <> 'Bar' and ((c.data ? 'place') or c.event_date = p_day)
          and not (coalesce((c.data->>'flex')::boolean, false) and exists (select 1 from cards pc where pc.couple_id = p_couple and pc.deck = 'event'
                   and pc.data ? 'place' and length(pc.title) >= 6 and lower(c.title) like lower(pc.title) || '%'))$a$);
  if d2 = d then raise exception '_ap_pick flex anchor'; end if;
  execute d2;
end $$;
