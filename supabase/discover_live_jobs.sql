-- Discover package, live only (the sim calls _disc_tick from sim_advance instead). Apply after discover.sql.
-- Look for and deal unique spots four times a day, a few minutes after the hidden-gem look runs; check booked trips hourly.
select cron.schedule('welike-disc-look', '35 3,12,17,22 * * *', $$select public._disc_tick('look')$$);
select cron.schedule('welike-disc-trips', '45 * * * *', $$select public._disc_tick('trips')$$);
