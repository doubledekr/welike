-- Friends, next pass (Dave, 19 Nov 2026; beta and sim):
--   * Friend requests: entering someone's code sends a request they accept or decline. An invite link they sent you
--     still makes you friends at once (they asked you). If they already asked you, your request makes you friends.
--   * Things you like with friends: for friends who turned on "Match with friends" (and only if you did too), the
--     things you both said yes to, with who. Nothing one person liked alone is ever returned.
create table if not exists fr_requests (a uuid not null references fr_people(id) on delete cascade, b uuid not null references fr_people(id) on delete cascade,
  created_at timestamptz not null default now(), primary key (a, b));
alter table fr_requests enable row level security;

create or replace function fr_request(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._uid(); f fr_people;
begin
  if uid is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  if not exists (select 1 from fr_people where id = uid) then return jsonb_build_object('ok', false, 'why', 'name'); end if;
  select * into f from fr_people where code = upper(trim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('ok', false, 'why', 'nocode'); end if;
  if f.id = uid then return jsonb_build_object('ok', false, 'why', 'self'); end if;
  if exists (select 1 from fr_friends where a = uid and b = f.id) then return jsonb_build_object('ok', true, 'friends', true, 'name', f.name); end if;
  if exists (select 1 from fr_requests where a = f.id and b = uid) then
    insert into fr_friends(a, b) values (uid, f.id), (f.id, uid) on conflict do nothing;
    delete from fr_requests where (a = f.id and b = uid) or (a = uid and b = f.id);
    return jsonb_build_object('ok', true, 'friends', true, 'name', f.name, 'id', f.id);
  end if;
  insert into fr_requests(a, b) values (uid, f.id) on conflict do nothing;
  return jsonb_build_object('ok', true, 'sent', true, 'name', f.name);
end $$;

create or replace function fr_requests_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('in', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by r.created_at) from fr_requests r join fr_people p on p.id = r.a where r.b = public._uid()), '[]'),
    'out', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by r.created_at) from fr_requests r join fr_people p on p.id = r.b where r.a = public._uid()), '[]'));
$$;

create or replace function fr_request_answer(p_from uuid, p_yes boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._uid();
begin
  if uid is null then return jsonb_build_object('ok', false, 'why', 'signin'); end if;
  if not exists (select 1 from fr_requests where a = p_from and b = uid) then return jsonb_build_object('ok', false, 'why', 'gone'); end if;
  delete from fr_requests where a = p_from and b = uid;
  if p_yes then insert into fr_friends(a, b) values (uid, p_from), (p_from, uid) on conflict do nothing; end if;
  return jsonb_build_object('ok', true, 'friends', p_yes);
end $$;

-- things you like with friends: only shared yeses, only between people who both turned matching on
create or replace function fr_lib_matches() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := public._uid(); me record; f record; pr record; acc jsonb := '{}'; k text;
begin
  if uid is null or not coalesce((select share from fr_people where id = uid), false) then return jsonb_build_object('ok', false, 'why', 'share'); end if;
  select * into me from _fr_partner(uid); if me.cid is null then return jsonb_build_object('ok', true, 'cards', '[]'::jsonb); end if;
  for f in select p.id, p.name from fr_friends x join fr_people p on p.id = x.b where x.a = uid and p.share loop
    select * into pr from _fr_partner(f.id); if pr.cid is null or pr.cid = me.cid then continue; end if;
    for k in select a.k from (select m.k from _fr_likes(me.cid, me.myname, 'movie') m union all select m.k from _fr_likes(me.cid, me.myname, 'dinner') m union all select m.k from _fr_likes(me.cid, me.myname, 'out') m) a
             intersect select b.k from (select t.k from _fr_likes(pr.cid, pr.myname, 'movie') t union all select t.k from _fr_likes(pr.cid, pr.myname, 'dinner') t union all select t.k from _fr_likes(pr.cid, pr.myname, 'out') t) b loop
      acc := jsonb_set(acc, array[k], coalesce(acc->k, '[]'::jsonb) || to_jsonb(f.name));
    end loop;
  end loop;
  return jsonb_build_object('ok', true, 'cards', coalesce((select jsonb_agg(_spin_card(z.card) || jsonb_build_object('with', acc->z.k)) from (
    select distinct on (m.k) m.k, m.card from (select * from _fr_likes(me.cid, me.myname, 'movie') union all select * from _fr_likes(me.cid, me.myname, 'dinner') union all select * from _fr_likes(me.cid, me.myname, 'out')) m
    where acc ? m.k order by m.k, m.card limit 80) z), '[]'::jsonb));
end $$;

grant execute on function fr_request(text), fr_requests_list(), fr_request_answer(uuid, boolean), fr_lib_matches() to authenticated;

-- LTbeta (sim) only: the sim's signed-in check is public._uid(). On the live project the file is applied with auth.uid()
-- in its place and without this block.
do $$ declare d text; f text; begin
  foreach f in array array['public.fr_someday(uuid[])', 'public.fr_spin(uuid[],text)'] loop
    d := pg_get_functiondef(f::regprocedure); if position('auth.uid()' in d) = 0 then raise exception 'anchor % ', f; end if;
    execute replace(d, 'auth.uid()', 'public._uid()');
  end loop; end $$;
