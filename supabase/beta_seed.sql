-- Beta test world for Dave (20 Nov 2026, Dave: "have my partner and friends already set up so I can try functions").
-- Every couple here is marked settings.test = true (_is_test), so trivia, analytics and pushes treat them as tests.
-- Dave signs in on /t with developer@letstogether.app (forwards to his Gmail) and lands in couple BETADAVE as "Dave".
-- Ava (partner), Maya and Jordan (a couple), Sam (single friend) are mock accounts that nobody signs in to.
-- Re-runnable: it deletes and rebuilds only these couples and these five accounts.
do $$
declare
  u_dave uuid := 'b7a00000-0000-4000-8000-00000000da7e';
  u_ava  uuid := 'b7a00000-0000-4000-8000-0000000000a7';
  u_maya uuid := 'b7a00000-0000-4000-8000-00000000a1a1';
  u_jord uuid := 'b7a00000-0000-4000-8000-00000000a1a2';
  u_sam  uuid := 'b7a00000-0000-4000-8000-00000000a1a3';
  c_us   uuid := 'b7a00000-0000-4000-8000-0000000c0001';
  c_mj   uuid := 'b7a00000-0000-4000-8000-0000000c0002';
  c_sam  uuid := 'b7a00000-0000-4000-8000-0000000c0003';
  src uuid := (select id from couples where code = 'TESTTEST');
  loc jsonb := (select jsonb_strip_nulls(jsonb_build_object('lat', settings->'lat', 'lng', settings->'lng', 'zip', settings->'zip', 'city', settings->'city')) from couples where code = 'TESTTEST');
  s uuid; r record; i int;
begin
  -- clean
  delete from swipes where couple_id in (c_us, c_mj, c_sam);
  delete from sessions where couple_id in (c_us, c_mj, c_sam);
  delete from favorites where couple_id in (c_us, c_mj, c_sam);
  delete from someday where couple_id in (c_us, c_mj, c_sam);
  delete from cards where couple_id in (c_us, c_mj, c_sam);
  delete from members where couple_id in (c_us, c_mj, c_sam);
  delete from couples where id in (c_us, c_mj, c_sam);
  delete from fr_groups where owner in (u_dave, u_ava, u_maya, u_jord, u_sam);
  delete from fr_friends where a in (u_dave, u_ava, u_maya, u_jord, u_sam) or b in (u_dave, u_ava, u_maya, u_jord, u_sam);
  delete from fr_people where id in (u_dave, u_ava, u_maya, u_jord, u_sam);
  delete from auth.identities where user_id in (u_dave, u_ava, u_maya, u_jord, u_sam);
  delete from auth.users where id in (u_dave, u_ava, u_maya, u_jord, u_sam);

  -- accounts (no passwords; Dave signs in with an emailed code)
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
  select '00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated', x.email, now(), '{"provider":"email","providers":["email"]}', jsonb_build_object('given_name', x.n), now(), now(), '', '', '', ''
  from (values (u_dave, 'developer@letstogether.app', 'Dave'), (u_ava, 'ava.beta@test.letstogether.app', 'Ava'), (u_maya, 'maya.beta@test.letstogether.app', 'Maya'),
               (u_jord, 'jordan.beta@test.letstogether.app', 'Jordan'), (u_sam, 'sam.beta@test.letstogether.app', 'Sam')) x(id, email, n);
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  select u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), 'email', now(), now(), now() from auth.users u where u.id in (u_dave, u_ava, u_maya, u_jord, u_sam);

  -- couples
  insert into couples (id, code, settings) values
    (c_us,  'BETADAVE', coalesce(loc, '{}') || '{"test":true,"setup":true,"services":["Netflix","Max","Prime Video"]}'),
    (c_mj,  'BETAMAYA', coalesce(loc, '{}') || '{"test":true,"setup":true}'),
    (c_sam, 'BETASAM1', coalesce(loc, '{}') || '{"test":true,"setup":true,"solo":true}');
  insert into members (couple_id, name, user_id, created_at) values
    (c_us, 'Dave', u_dave, now() - interval '30 days'), (c_us, 'Ava', u_ava, now() - interval '29 days'),
    (c_mj, 'Maya', u_maya, now() - interval '20 days'), (c_mj, 'Jordan', u_jord, now() - interval '19 days'),
    (c_sam, 'Sam', u_sam, now() - interval '10 days');

  -- local places: copies of the TESTTEST couple's place cards (public place data)
  insert into cards (couple_id, deck, kind, title, subtitle, image, data, ext_id, event_date, active, created_by)
  select c.id2, x.deck, x.kind, x.title, x.subtitle, x.image, x.data, x.ext_id, x.event_date, true, x.created_by
  from cards x cross join (values (c_us), (c_mj), (c_sam)) c(id2)
  where x.couple_id = src and x.active;

  -- likes: one seed session per couple member
  for r in select * from (values (c_us, 'Dave'), (c_us, 'Ava'), (c_mj, 'Maya'), (c_mj, 'Jordan'), (c_sam, 'Sam')) v(cid, m) loop
    insert into sessions (couple_id, deck, from_member, filters, created_at) values (r.cid, 'all', r.m, '{"seed":true,"solo":true}', now() - interval '7 days') returning id into s;
    -- movies: the first 14 by id both like; each person adds a few of their own
    insert into swipes (session_id, card_id, couple_id, member, verdict, created_at)
    select s, id, r.cid, r.m, 'yes', now() - interval '6 days' from (select id from cards where deck = 'movie' and couple_id is null and active order by id limit 14) q;
    insert into swipes (session_id, card_id, couple_id, member, verdict, created_at)
    select s, id, r.cid, r.m, 'yes', now() - interval '5 days' from (select id from cards where deck = 'movie' and couple_id is null and active order by id offset (14 + 6 * (case r.m when 'Dave' then 0 when 'Ava' then 1 when 'Maya' then 2 when 'Jordan' then 3 else 4 end)) limit 6) q;
    -- places: the first 8 dinner and 8 event cards; Dave and Ava also share a few more
    insert into swipes (session_id, card_id, couple_id, member, verdict, created_at)
    select s, id, r.cid, r.m, 'yes', now() - interval '4 days' from (
      (select id from cards where couple_id = r.cid and deck = 'dinner' and active order by ext_id limit (case when r.cid = c_us then 10 else 6 end))
      union all (select id from cards where couple_id = r.cid and deck = 'event' and active order by ext_id limit (case when r.cid = c_us then 10 else 6 end))) q;
    insert into swipes (session_id, card_id, couple_id, member, verdict, created_at)
    select s, id, r.cid, r.m, 'no', now() - interval '4 days' from (select id from cards where couple_id = r.cid and deck = 'dinner' and active order by ext_id offset 12 limit 4) q;
  end loop;

  -- trips: Dave and Ava both like things in Lisbon; Ava also likes Kyoto
  insert into sessions (couple_id, deck, from_member, filters) values (c_us, 'trip', 'Dave', '{"seed":true,"solo":true}') returning id into s;
  insert into swipes (session_id, card_id, couple_id, member, verdict, created_at)
  select s, q.id, c_us, m, 'yes', now() - interval '3 days' from (select id from cards where deck = 'trip' and kind = 'Lisbon' and active order by id limit 8) q cross join (values ('Dave'), ('Ava')) w(m);
  insert into swipes (session_id, card_id, couple_id, member, verdict, created_at)
  select s, q.id, c_us, 'Ava', 'yes', now() - interval '3 days' from (select id from cards where deck = 'trip' and kind = 'Kyoto' and active order by id limit 5) q;

  insert into someday (couple_id, member, city) values
    (c_us, 'Dave', 'Lisbon'), (c_us, 'Dave', 'Kyoto'), (c_us, 'Dave', 'New Orleans'),
    (c_us, 'Ava', 'Lisbon'), (c_us, 'Ava', 'Kyoto'), (c_us, 'Ava', 'Banff'),
    (c_mj, 'Maya', 'New Orleans'), (c_mj, 'Jordan', 'New Orleans'), (c_mj, 'Maya', 'Lisbon');

  -- a trip that is on: Lisbon, 12 to 18 March, dates agreed
  update couples set settings = settings || jsonb_build_object('plans', jsonb_build_array('Lisbon'),
    'plan_meta', jsonb_build_object('Lisbon', jsonb_build_object('at', now() - interval '2 days', 'by', 'Ava', 'from', '2027-03-12', 'to', '2027-03-18', 'dates_by', 'Ava', 'dates_ok', true)))
  where id = c_us;

  -- favorites: three places both of them loved
  insert into favorites (couple_id, card_id, by_member)
  select c_us, id, 'both' from cards where couple_id = c_us and deck = 'dinner' and active order by ext_id limit 3;

  -- friends: everyone friends with Dave and Ava; Maya and Jordan with each other; all share matches
  insert into fr_people (id, name, code, share) values
    (u_dave, 'Dave', 'BDAVE1', true), (u_ava, 'Ava', 'BAVA01', true), (u_maya, 'Maya', 'BMAYA1', true), (u_jord, 'Jordan', 'BJORD1', true), (u_sam, 'Sam', 'BSAM01', true);
  insert into fr_friends (a, b)
  select a, b from (values (u_dave, u_maya), (u_dave, u_jord), (u_dave, u_sam), (u_ava, u_maya), (u_ava, u_jord), (u_ava, u_sam), (u_maya, u_jord), (u_maya, u_sam)) v(x, y) cross join lateral (values (x, y), (y, x)) z(a, b)
  on conflict do nothing;
  insert into fr_groups (owner, name, members) values (u_dave, 'Detroit crew', array[u_maya, u_jord, u_sam]);
end $$;
