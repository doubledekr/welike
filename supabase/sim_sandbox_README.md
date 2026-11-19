# Simulation sandbox (LTbeta project)

The copy of the app at /s talks to a separate Supabase project that holds only made-up people.
Its database has the same tables and functions as live, plus the `sim_*` functions and four helpers
(`_now`, `_today`, `_uid`, `_sim_post`) that every app function is rewritten to use there.
After copying new functions from live into LTbeta, run `select _sim_rewrite();` in LTbeta.
The sim key is not kept in this repository.
