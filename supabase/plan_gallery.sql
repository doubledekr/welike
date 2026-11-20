-- Swap gallery (19 Nov 2026): plan_options no longer offers hidden gems or unique spots that are still held back
-- (not released yet) unless one of you has already seen them. Same anchor-checked patch as the other plan fixes.
do $$ declare d text; n text; begin
select pg_get_functiondef('public.plan_options(text,text,date,text,text,text,double precision,double precision,uuid[])'::regprocedure) into d;
n := replace(d, 'and not _never(v.id, c.id)
      and (case k.kind', 'and not _never(v.id, c.id)
      and (not (c.data ? ''gem'' or c.data ? ''unique'') or exists (select 1 from _lv(v.id) w where w.card_id = c.id)
           or (coalesce(c.data->>''hold'', '''') <> ''true'' and coalesce((c.data->>''release'')::date, _today()) <= _today()))
      and (case k.kind');
if n = d then raise exception 'anchor not found'; end if; execute n; end $$;
