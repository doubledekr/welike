# seasonal (edge function, deployed 21 Nov 2026 via MCP)
Finds what is on only this season near an area (holiday pop-up bars, light displays, igloos, rinks, markets that run for weeks),
confirms each venue on Google Places, and with `save: true` calls `_season_apply`. Source lives in the Supabase project
(function `seasonal`, files `index.ts` and `ai_log.ts`). Database side: table `place_seasons`, `_season_of`, `_season_apply`,
`_season_tick` (cron `welike-seasonal`, Wednesdays 10am ET). `hungry_spots` and `local_browse` read `_season_of`.
