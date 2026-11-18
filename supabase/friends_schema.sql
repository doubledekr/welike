-- Friends, private groups and group plans. People are accounts (auth.uid()), separate from couples.
-- Every table is closed (RLS on, no policies); all access goes through the fr_* functions, signed-in people only.
create table if not exists fr_people (id uuid primary key, name text not null, code text unique not null, created_at timestamptz not null default now());
create table if not exists fr_friends (a uuid not null references fr_people(id) on delete cascade, b uuid not null references fr_people(id) on delete cascade, created_at timestamptz not null default now(), primary key (a, b));
create table if not exists fr_groups (id uuid primary key default gen_random_uuid(), owner uuid not null references fr_people(id) on delete cascade, name text not null, members uuid[] not null default '{}', created_at timestamptz not null default now());
create index if not exists fr_groups_owner on fr_groups(owner);
create table if not exists fr_plans (id uuid primary key default gen_random_uuid(), owner uuid not null references fr_people(id) on delete cascade, kind text not null, flow text not null, title text not null,
  city text, day_from date, at_time text, parent uuid references fr_plans(id) on delete cascade, surprise_for uuid, deck uuid[] not null default '{}', data jsonb not null default '{}', created_at timestamptz not null default now());
create index if not exists fr_plans_parent on fr_plans(parent);
create table if not exists fr_plan_members (plan uuid not null references fr_plans(id) on delete cascade, person uuid not null references fr_people(id) on delete cascade, role text, status text not null default 'invited',
  via uuid, arrive_at timestamptz, arrive_how text, booked boolean not null default false, created_at timestamptz not null default now(), primary key (plan, person));
create index if not exists fr_pm_person on fr_plan_members(person);
create table if not exists fr_polls (id uuid primary key default gen_random_uuid(), plan uuid not null references fr_plans(id) on delete cascade, kind text not null, options jsonb not null default '[]', state text not null default 'open',
  round int not null default 1, runoff jsonb, result text, tally jsonb, created_at timestamptz not null default now());
create index if not exists fr_polls_plan on fr_polls(plan);
create table if not exists fr_votes (poll uuid not null references fr_polls(id) on delete cascade, person uuid not null references fr_people(id) on delete cascade, round int not null default 1, v jsonb not null, created_at timestamptz not null default now(), primary key (poll, person, round));
create table if not exists fr_ideas (id uuid primary key default gen_random_uuid(), plan uuid not null references fr_plans(id) on delete cascade, title text not null, by uuid not null, created_at timestamptz not null default now());
create index if not exists fr_ideas_plan on fr_ideas(plan);
create table if not exists fr_swipes (plan uuid not null references fr_plans(id) on delete cascade, card uuid not null, person uuid not null references fr_people(id) on delete cascade, yes boolean not null, created_at timestamptz not null default now(), primary key (plan, card, person));
alter table fr_people enable row level security; alter table fr_friends enable row level security; alter table fr_groups enable row level security; alter table fr_plans enable row level security;
alter table fr_plan_members enable row level security; alter table fr_polls enable row level security; alter table fr_votes enable row level security; alter table fr_ideas enable row level security; alter table fr_swipes enable row level security;
