-- Write your experimental DROP INDEX and CREATE INDEX statements here.
-- Test one candidate at a time. Drop only indexes you created for this experiment.
-- The primary-key index is part of the starting schema and must stay.

drop index if exists lab08.trips_route_id_idx;
drop index if exists lab08.trips_route_departure_idx;

create index trips_route_departure_idx
    on lab08.trips (route_id, scheduled_departure_utc, id)
    where status = 'Scheduled';