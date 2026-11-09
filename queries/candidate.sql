-- Your query goes here. It starts as a copy of the baseline.
-- Keep the columns, ordering and LIMIT. Rewrite the date predicate.
-- query_day is a UTC calendar date. result_limit is 20, or NULL for the full-day check.
select id, route_id, scheduled_departure_utc, status
from lab08.trips
where route_id = :'route_id'
  and status = 'Scheduled'
  and scheduled_departure_utc >= timezone('UTC', :'query_day'::date::timestamp)
  and scheduled_departure_utc <  timezone('UTC', (:'query_day'::date + 1)::timestamp)
order by scheduled_departure_utc, id
limit :result_limit;