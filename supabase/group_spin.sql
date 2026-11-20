-- Group spin (Dave, 19 Nov 2026; beta and sim): only what every person in a friend group said yes to and nobody has
-- seen or said never again to. Movies match on the same card; places match on the Google place (each couple has its
-- own copy of a place card). Friends only; returns the shared picks and nothing about who liked what else.
create or replace function _fr_likes(p_cid uuid, p_member text, p_kind text) returns table(k text, card uuid)
language sql stable security definer set search_path = public as $$
  select case when c.deck = 'movie' then c.id::text else coalesce(nullif(c.data->>'place_id', ''), lower(c.title)) end, c.id
  from _lv(p_cid) l join cards c on c.id = l.card_id and c.active
  where l.member = p_member and l.verdict in ('yes', 'love') and not _never(p_cid, c.id)
    and case p_kind when 'movie' then c.deck = 'movie' when 'dinner' then c.deck = 'dinner' and c.kind <> 'cook'
      when 'out' then c.deck = 'event' and (c.data ? 'place' or c.event_date = _today()) else false end;
$$;

create or replace function fr_spin(p_people uuid[], p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); everyone uuid[]; p uuid; pr record; mine_cid uuid; mine_name text; keys text[];
begin
  if me is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  if p_kind not in ('movie', 'dinner', 'out') then return jsonb_build_object('ok', false, 'why', 'kind'); end if;
  if exists (select 1 from unnest(p_people) x where x <> me and not exists (select 1 from fr_friends f where (f.a = me and f.b = x) or (f.b = me and f.a = x))) then
    return jsonb_build_object('ok', false, 'why', 'friends'); end if;
  everyone := array(select distinct x from unnest(p_people || me) x);
  foreach p in array everyone loop
    select * into pr from _fr_partner(p);
    if pr.cid is null then return jsonb_build_object('ok', true, 'cards', '[]'::jsonb, 'n', cardinality(everyone)); end if;
    if p = me then mine_cid := pr.cid; mine_name := pr.myname; end if;
    keys := case when keys is null then array(select k from _fr_likes(pr.cid, pr.myname, p_kind))
                 else array(select unnest(keys) intersect select k from _fr_likes(pr.cid, pr.myname, p_kind)) end;
    -- nobody in the group has marked it seen
    keys := array(select x from unnest(keys) x where not exists (select 1 from _lv(pr.cid) l join cards c on c.id = l.card_id
      where l.member = pr.myname and l.verdict = 'seen' and (case when c.deck = 'movie' then c.id::text else coalesce(nullif(c.data->>'place_id', ''), lower(c.title)) end) = x));
  end loop;
  return jsonb_build_object('ok', true, 'n', cardinality(everyone), 'cards', coalesce((select jsonb_agg(_spin_card(f.card)) from (
    select distinct on (f.k) f.card from _fr_likes(mine_cid, mine_name, p_kind) f where f.k = any(keys) order by f.k, f.card limit 40) f), '[]'::jsonb));
end $$;
grant execute on function fr_spin(uuid[], text) to authenticated;
