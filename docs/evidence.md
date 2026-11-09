# Query optimization notes

Use the `Execution Time` from each of the five measured plans. Sort the five values to find the median. Record the smallest and largest as the range.

The plans behind every row are saved next to this file: `baseline-r7.txt`, `baseline-r0.txt`, `rewrite-r7.txt`, `rewrite-r0.txt`, `index-route-r7.txt`, `index-route-r0.txt`, `index-chosen-r7.txt`, `index-chosen-r0.txt` and `partition-plans.txt`.

| Route | Query / active index | Median ms | Range ms | Scan / filter / sort observation | Top-node shared hit / read buffers | Check passes? |
| --- | --- | ---: | --- | --- | --- | --- |
| R-7 | Baseline / primary key only | 8.666 | 7.088–10.592 | Seq Scan over the whole table, 119,970 rows removed by filter, quicksort of the surviving 38. The estimate is 15 against 38 actual, because the planner has no statistics for the expression `(scheduled_departure_utc at time zone 'UTC')::date`. | 1007 / 0 | yes, with the candidate still a copy of the baseline |
| R-7 | Rewrite / primary key only | 7.406 | 6.211–7.969 | The same Seq Scan and the same 119,970 rows removed. The date test is now two timestamp comparisons, and the planner moved it to the front of the filter. The estimate improves to 31 against 38. | 1007 / 0 | yes |
| R-7 | Rewrite / route-only index | 2.181 | 1.939–2.981 | Bitmap Index Scan over 3,337 entries in 4 buffers, then Bitmap Heap Scan with `Heap Blocks: exact=1001` and 3,299 rows removed by filter. The sort stays, so all 38 departures must be found before the first can be returned. | 1011 / 0 | yes |
| R-7 | Rewrite / chosen index | 0.208 | 0.163–0.411 | Index Scan alone. No Sort and no Filter: three conditions became `Index Cond`, and `status` is covered by the index predicate. The scan stops after 20 rows. | 23 / 0 | yes |
| R-0 | Baseline / primary key only | 15.852 | 13.648–19.372 | Seq Scan, 119,017 rows removed, top-N heapsort of the surviving 991. Slower than R-7 because `route_id = 'R-0'` passes about three quarters of the rows, so the expensive date expression ran for roughly 90,000 of them instead of 3,300. | 1007 / 0 | yes, with the candidate still a copy of the baseline |
| R-0 | Rewrite / primary key only | 6.176 | 6.050–7.864 | The same Seq Scan, but the cheap date test now runs first and rejects about 99 percent of the rows before `route_id` is examined. This is why the rewrite helps R-0 more than twice as much as R-7. The estimate is 851 against 991. | 1007 / 0 | yes |
| R-0 | Rewrite / route-only index | 6.321 | 5.935–8.976 | Seq Scan. The index is not used at all, because it selects about three quarters of the table and reading the table outright is cheaper. | 1007 / 0 | yes |
| R-0 | Rewrite / chosen index | 0.213 | 0.197–0.356 | Index Scan alone, no Sort, stops after 20 rows. The same plan and nearly the same time as R-7, although R-0 has 991 departures that day against R-7's 38. | 24 / 0 | yes |

## Keep or remove?

- Index sizes: route-only **832 kB**; chosen index **4408 kB**. The primary key on `id` is 2640 kB for comparison. The route-only index is the smallest although it covers the most rows, because `route_id` has only ten distinct values and PostgreSQL stores each one once with a list of row pointers beneath it. The chosen index cannot do that, because `id` makes every entry unique.
- Index to keep: `create index trips_route_departure_idx on lab08.trips (route_id, scheduled_departure_utc, id) where status = 'Scheduled';`
- One result that supports the decision: R-0 fell from 6.321 ms to 0.213 ms and from 1007 buffers to 24, where the route-only index had changed nothing at all for that route. The work now follows the 20 rows that are returned rather than the 120,008 rows in the table, which is why both routes cost the same despite one having 26 times more departures that day.
- One alternative rejected, and why: the index on `route_id` alone. It helped only the small route, and PostgreSQL ignored it outright for R-0. For R-7 it left the Sort in place, so the query still had to find all 38 departures before returning the first, and `Heap Blocks: exact=1001` shows it read every page of the table anyway. It made the query faster by examining fewer rows, not by reading fewer pages — so it does not scale with the size of the route or of the table.
- What changes when a scheduled departure is inserted, rescheduled or cancelled? An insert writes one more entry into the chosen index, positioned by `(route_id, scheduled_departure_utc, id)`; a new trip on an existing route lands inside that route's section rather than at the end, so pages can split. A reschedule changes `scheduled_departure_utc`, which is part of the key, so the old entry is removed and a new one written, usually on a different page — and because an indexed column changed, the update cannot be a heap-only update. A cancellation moves `status` from `Scheduled` to `Cancelled`, and the row then leaves the partial index completely, so the entry is deleted rather than updated. All three also write to the write-ahead log for the index as well as for the table, and the 4408 kB competes for cache with everything else.

- Your AI prompt, asked of ChatGPT in a conversation that knew nothing of the work above:

  ```
  I have one PostgreSQL 17 table and one query that runs very often. The query is
  parameterised: the route and the day change between runs, the limit is always 20.
  Below are the table definition, the data distribution, the indexes that exist today,
  the query, and its current plan from explain (analyze, buffers).

  Suggest exactly one index to add. Explain why you put the columns in that order,
  which part of the current plan your index removes, and what it will cost on inserts
  and updates. If you think no index is worth adding, say that instead.
  ```

  The table definition, the row distribution, the single existing index and the baseline plan for R-7 were pasted below the question. The index chosen here was deliberately left out, so the answer could not simply agree with a conclusion it had been handed.
- One AI suggestion accepted, changed or rejected, and the check that decided it: accepted without change. The suggestion was `(route_id, scheduled_departure_utc, id) where status = 'Scheduled'` — the same three columns in the same order with the same partial predicate as the index chosen here, differing only in name. Its reasoning matched column for column, and it predicted the resulting plan correctly: an Index Scan, no sort, and a stop after 20 rows. What decided it was the measurement rather than the agreement: `check` passed all four comparisons with the index in place, and the measured plan was the predicted one at 23 buffers and 0.208 ms for R-7. The measurement did correct one part of the suggestion. It argued the index is particularly useful for a route such as R-7 with only 38 departures that day, but R-0, with 991, gained far more — from 15.852 ms to 0.213 ms — and ends at the same cost as R-7. The index does not help because a route is small; it helps because the work follows the 20 rows returned instead of the number of rows the route holds.

A fourth variant, the same index with `include (status)`, was considered and not measured. It would permit an index-only scan and cut the 23 buffers to roughly 3, but it makes the index larger, and the saving depends on the visibility map being current. On a timetable with continuous inserts, reschedules and cancellations, vacuum does not always keep up, and the benefit disappears whenever it does not.

## Partitioning

| Read | Plain-table plan | Partitions actually accessed | Same result? |
| --- | --- | --- | --- |
| October count | `Index Only Scan` on `validations_plain_pkey` with `Heap Fetches: 0`, 198 buffers, 8.780 ms. The primary key is `(validated_utc, id)`, so one month is a contiguous slice of the index and the table is never read. | `validations_oct` only. September and November were pruned, and with a single child left there is no `Append` node. `Seq Scan`, 261 buffers, 14.129 ms. | Yes, 40,889 in both layouts. |
| Ticket 100 history | `Seq Scan` with `Filter: (ticket_id = 100)`, 119,988 rows removed, then `Sort`. 771 buffers, 7.638 ms. | All three: `validations_sep` 253 buffers, `validations_oct` 261 and `validations_nov` 252, combined by `Append`. 766 buffers in total, 8.543 ms. | Yes, 12 in both, and `different_ticket_history_rows` is 0. |

Pruning did work for the October count, and the plan names only `validations_oct`. It was still the slower of the two, because pruning cut the rows considered from 120,000 to 40,889 while the plain table's index-only scan cut the pages read to 198. Reading 261 pages and evaluating a filter on 40,889 rows costs more than counting 40,889 entries in an index.

The ticket lookup cannot be pruned at all. It never mentions `validated_utc`, which is the column the table is divided by, so no month can be excluded. Three sequential scans replace one and read the same number of pages, with an `Append` added on top.

One caveat on the October figures. `Heap Fetches: 0` is only possible because every page was already marked all-visible. `pg_class` shows `relallvisible` equal to `relpages` for all five physical tables, and `last_autovacuum` at 21:03:25 UTC, seconds after the fixture finished loading. Running `partitions` immediately after `reset` would most likely give the plain table a sequential scan instead, and partitioning would then win this comparison.

### Would you choose monthly partitions for reporting, ticket support, or monthly retention?

**Not for reporting**, at least not against this schema. The plan confirms that pruning works, but the measurement shows it did not pay: 14.129 ms against 8.780 ms. The plain table already answers a question about one month from its primary-key index without touching the table. Were the primary key not led by `validated_utc`, the plain table would have to read all 765 pages, and pruning would win.

**Not for ticket support.** The lookup has no date to prune on, so all three partitions are read and an `Append` is added. It is slightly slower than the single table today, and it gets worse with every month that is added.

**Yes for monthly retention.** Removing September from the partitioned table is `drop table lab08.validations_sep`, a catalogue change that releases 253 pages at once. Removing it from the plain table is a `delete` of 39,570 rows that leaves dead rows behind, writes to the write-ahead log for every one of them, and needs a vacuum afterwards before the space can be reused. That difference grows with the table, and it is the only argument here that does not depend on the shape of the queries.