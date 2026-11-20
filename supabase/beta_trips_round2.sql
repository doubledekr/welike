-- Applied to the live project 20 Nov as migrations beta_trips_round2, viator_item_product, start_trips_skip_eat.
-- start_trip_eat(p_code, p_member, p_city): an Eat pile for a trip city (local food and drink cards not yet swiped).
-- fr_day(p_id, p_card, p_day, p_vote add|up|down|off): stops on a group trip day; host adds straight in, others suggest,
--   a suggestion goes on the day once half the group is in. Stored in fr_plans.data.days. Nothing is pushed.
-- _viator_apply now keeps the product code on each booked item, so a missing start time can be picked from the tour's times.
-- start_trips skips Eat sessions (filters ? 'eat').

-- Round 3 (applied as migration beta_trips_round3, 20 Nov afternoon):
-- start_trip_explore(code, member, city): Explore pile (day trips first, then tours on your dates, then gems/spots).
-- trips_tag_explore(codes, tag) (service only); trips edge function action 'explore' (source supabase/trips_index.ts).
-- trip_points(ids): lat/lng for the trip map.
-- fr_day(p_id, p_card|null, p_day, p_vote add|suggest|up|down|lock|off, p_opt {title,time,url}): majority on, half out drops;
--   planner adds directly or puts to a vote; planner can lock in. fr_day_rand(p_id, p_cards): planner lets chance pick.
-- plan_stop(code, member, city, card|null, day, vote, opt) and plan_stop_rand(...): the same for couple trips
--   (two people: on once the other is in; a card you both liked goes straight on).

-- Festivals and Wikipedia photos (migration wiki_fests_and_photos, 20 Nov afternoon):
-- city_fests (one Claude pass per city, kept 300 days), fests_upsert, edge function fests (source supabase/fests_index.ts),
-- start_trip_explore(code, member, city, from, to) leads with festivals whose usual months overlap the trip.
-- gems.photo_credit + trigger cards_gem_credit; gems edge function v8 uses wikiimg.ts before Google photos.

-- Trip merch (20 Nov evening): edge function merch (source supabase/merch_index.ts) on Fourthwall, fr_merch_add(plan, items).
-- Planner-only; up to 3 blanks per go, 6 per trip; hidden products, $5 margin; fr_plans.data.merch holds {id, kind, price, img, url}.

-- Round 4 (20 Nov, evening): trip merch group order. Migration fr_merch_group_order on production:
--   _fr_money: cost mode 'each' counts one share per person (plus-ones don't change a merch share)
--   fr_merch_patch (service role only), fr_merch_act(p_id, p_kind mode|color|size|ordered, p_data)
--   'ordered' turns each "Everyone gets one" item into a fr_costs row: price x people, mode 'each', claims = who has a size.
-- merch function: opts {plan,item} reads colours/sizes/variant ids; checkout {plan} builds
--   https://<shop>/cart/checkout?products=variantId:qty,... (ships to whoever checks out: the planner).

-- Round 5 (20 Nov, 5:30pm): trip day screen. Migration trip_day_details on production:
--   fr_trip_set(p_id, 'flight'|'stay', value)  (group: data.flights[uid] = {code, day, land, from}; also sets arrive_at/arrive_how)
--   plan_trip_set(code, member, city, 'flight'|'stay', value)  (couple: plan_meta[city].flights_by[member], plan_meta[city].stay)
