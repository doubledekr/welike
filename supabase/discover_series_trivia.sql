-- Discover package, part 2: apply AFTER the Sun 23 Nov trivia night (live trivia is frozen until then).
-- Shows arrive in Watch from the Monday 3:10am ET list run; trivia's "your movies" question must stay movies only.
do $$ declare d text; d2 text; begin
  d := pg_get_functiondef('public._tv_mine'::regproc);
  d2 := replace(d, $a$and c.deck = 'movie' and c.data->>'year' ~ '^\d{4}$'$a$, $a$and c.deck = 'movie' and c.data->>'type' is distinct from 'series' and c.data->>'year' ~ '^\d{4}$'$a$);
  if d2 = d then raise exception '_tv_mine anchor'; end if;
  execute d2;
end $$;
