# SearchPerfTest - context / plan (resume point)

## Goal
Build a performance-testing toolkit for the Atlas Search endpoint of the
`listing` collection, to measure query latency/throughput against the ~16
million document Atlas cluster, with adjustable parallelism (e.g. run
100,000 queries linearly with `-P 1`, or with 10 concurrent via `-P 10`).

## Target endpoint (confirmed from ListingController.java)
- `POST /api/listings/search`
- Request body (raw JSON string, no auth/headers besides
  `Content-Type: application/json`):
  ```json
  {
    "search": { ... any valid $search operator body (text/compound/range/equals) ... },
    "projection": { "field": 1, ... },
    "skip": 0,
    "limit": 1000
  }
  ```
- Field paths inside `search` must match actual stored MongoDB field names
  exactly (no renaming). Confirmed via fresh DataGen run that
  `city`/`state`/`zipcode`/`streetAddress` exist BOTH top-level and nested
  under `address.*` with identical values - but the rest of the app
  (`queryableFields.json`/`gridFields.json`) uses the nested `address.*`
  paths exclusively, so generated queries must use `address.city`,
  `address.state`, `address.zipcode`, `address.streetAddress` (not the
  top-level duplicates) to match the corrected Atlas Search index
  (`ListingPreflightConfig.java`, fixed in commit 786f91f).

## Current Atlas Search index fields (ListingPreflightConfig.java, as of
commit 786f91f) - use these exact paths when generating query bodies:
- `address.city` (string), `address.state` (string), `address.zipcode` (number),
  `address.streetAddress` (string)
- `county` (string), `abbreviatedAddress` (string)
- `price`, `zestimate`, `rentZestimate`, `lastSoldPrice` (number)
- `bedrooms`, `bathrooms`, `livingArea`, `lotSize`, `yearBuilt` (number)
- `homeType`, `propertyTypeDimension`, `homeStatus`, `listingTypeDimension`, `tag` (string)
- `daysOnZillow` (number), `dateSold` (date)
- `hoa_details` (document, dynamic:true -> `hoa_details.hoa_fee_value` (number),
  `hoa_details.hoa_fee_period` (string), `hoa_details.has_hoa` (boolean, unreliable to filter))
- `description` (string, full-text)
- `zpid` (number)
- Index name: `"default"`, `dynamic: false` overall.

## Chosen approach: curl + xargs (not ab/hey/wrk/vegeta)
- `ab`/`hey` can't vary the POST body per request (fixed single body only).
- `curl` supports per-request body via `--data @file` and built-in timing via
  `-w "%{time_total}"` - no external timing code needed.
- `xargs -P N` gives trivial parallelism control (`-P 1` = linear, `-P 10` =
  10 concurrent), works with macOS's built-in BSD xargs.

## Planned files under SearchPerfTest/ (not yet created)
- `generate_queries.py` - generates a pool of N distinct realistic query
  JSON files (full request envelope) into `queries/`, sampling field values
  from actual DataGen CSVs (`DataGen/Zillow/*.csv.gz`) for realistic
  distributions (state/homeType/homeStatus/tag/county frequencies), numeric
  ranges informed by sampling `DataGen/listings.json`, and free-text
  keywords for `description` full-text queries. Mix of query shapes: pure
  full-text, compound (text + range/equality filters), filter-only
  (no text), varying skip/limit for pagination realism. Projection mirrors
  `configapi/gridFields.json` storage paths + `score: {"$meta":"searchScore"}`.
- `run_queries.sh` - replays queries from the pool at a specified total
  request count and parallelism (cycles through pool if total > pool size),
  via `xargs -P <parallelism>` + `curl -w "%{time_total},%{http_code}"`,
  appending to a results CSV (`query_file,time_total_seconds,http_status`).
  Wraps invocation in `time` for wall-clock elapsed (used for throughput).
- `summarize.py` - reads results CSV, prints count, error count, mean, min,
  max, p50/p90/p95/p99 latency, and throughput (req/s) given elapsed time.
- `README.md` - documents end-to-end workflow.

## Open decisions (were asked, not yet answered/confirmed by user before
this note was written - re-confirm before implementing):
- Default query pool size (proposed default: 2000 distinct queries, cycled
  to reach larger totals like 100k requests).
- Default target endpoint for scripts (proposed default:
  `http://localhost:8080/api/listings/search`, overridable via CLI arg).
- Scope: search endpoint only (`/api/listings/search`), not also the plain
  `/api/listings/query` endpoint, per the original ask - focus purely on
  Atlas Search perf.

## DataGen root-level field duplication fix (commit 7b22001)
`DataGen/Zillow/*.csv.gz` previously generated some fields at BOTH the
document root AND nested inside a grouping object with identical/related
values - fixed by keeping only one canonical copy of each:
- `address.city`/`address.state`/`address.zipcode`/`address.streetAddress`
  now generated ONLY nested under `address` (top-level `city`/`state`/
  `zipcode`/`streetAddress` duplicates removed) - matches the Atlas Search
  index and UI config convention noted above.
- Top-level `bedrooms`/`bathrooms` are now the ONLY copies (the
  `interior.bedrooms_and_bathrooms.bedrooms`/`.bathrooms` duplicate columns
  were removed; `full_bathrooms`/`half_bathroom` remain under
  `interior.bedrooms_and_bathrooms` since those aren't duplicates).
- Files changed: `city_city.csv.gz`->`city.csv.gz`,
  `state_state.csv.gz`->`state.csv.gz`,
  `bedrooms_bedrooms.csv.gz`->`bedrooms.csv.gz`, and
  `streetAddress_2.csv.gz`/`zipcode_2.csv.gz`/`bathrooms_2.csv.gz` deleted
  outright.
- NOT touched: similar-looking per-field files inside `DataGen/Zillow/
  homeValuation/comps/` and `DataGen/Zillow/nearbyHomes/` (e.g.
  `city_zipcode.csv.gz`, `state_mlsName.csv.gz`) - those define fields
  local to array-of-object sub-schemas, not root-document duplicates, so
  out of scope for this fix.
- Verified via a fresh `java -jar DataGen-1.0.jar Zillow ...` run that the
  generated JSON now has no top-level city/state/zipcode/streetAddress and
  retains only top-level bedrooms/bathrooms.
- Any query-generation logic for SearchPerfTest should assume this shape:
  `address.city`, `address.state`, `address.zipcode`,
  `address.streetAddress` for those four fields; plain top-level
  `bedrooms`/`bathrooms` for those two.

## configapi dropdowns repopulated from CSVs (commit bef02f8)
`queryableFields.json` categorical dropdown lists were regenerated
programmatically by reading the actual current `DataGen/Zillow/*.csv.gz`
files (not hand-typed) - full/complete value lists, ordered by real
frequency:
- `State=address.state`: full 48-state list (was a hand-picked top 10).
- `homeType`/`propertyTypeDimension`/`homeStatus`/HOA `hoa_fee_period`:
  same values, corrected ordering to match true frequency.
- Verified every field path in `queryableFields.json`/`gridFields.json`
  actually exists in a fresh 3000-doc DataGen sample (some fields are
  naturally probabilistic/optional, e.g. `tag` ~76%, `lastSoldPrice` ~90% -
  that's expected, not a bug).
- When generating SearchPerfTest query values for these categorical
  fields, prefer reading the CSVs directly (same technique used here)
  rather than hardcoding value lists, for the same accuracy reasons.

## main.js searchQuery >/< fix (commit 81ecae8)
The UI's Atlas Search query builder (`searchQuery` computed property in
`main.js`) previously silently dropped any `>`/`<` (and exact-date) filter
- only `equals` (numbers/dates) and `text` (strings) clauses were emitted.
Fixed to translate `{$gt/$gte/$lt/$lte: v}` into Atlas Search's `range`
operator. Relevant for SearchPerfTest query generation: range-style
compound queries (e.g. `price` between X and Y) are a legitimate, now
actually-working query shape to include in the generated query pool, using
`{"range": {"path": "price", "gte": X, "lte": Y}}` inside a `compound.must`
or `compound.filter` array - matches the real UI-generated shape now.

## Implementation complete (commit pending as of this note)
Built and tested end-to-end:
- `generate_queries.py` - field list parsed directly out of
  `ListingPreflightConfig.java`'s `getSearchIndexes()` (regex + JSON parse of
  the Java text block - NOT hardcoded), dynamic `hoa_details` sub-fields
  discovered via CSV column prefix match (found `has_hoa`, `hoa_fee_currency`,
  `hoa_fee_period`, `hoa_fee_value` - `has_hoa` auto-skipped as boolean).
  Values sampled from `DataGen/Zillow/*.csv.gz`, with a `parse_cell()` macro
  parser handling DataGen's `@INTEGER(min,max)`, `@DOUBLE(a,b)`,
  `@DATE`/`@DATETIME(start,end)`, and `@ONEUP` tokens (confirmed these are
  real - e.g. `price.csv.gz` is `@INTEGER(0,45650400)`, `dateSold.csv.gz` is
  `@DATETIME(...)`, `zpid.csv.gz`/`listingId.csv.gz` are `@ONEUP` - NOT
  discrete weighted lists like most other fields). `--explain` flag prints
  the full field discovery/inclusion/exclusion reasoning - this is the
  running answer to "how does it know which fields to test".
- `run_queries.sh` - curl+xargs runner, cycles the query pool to reach any
  requested total, positional args with `-` placeholder support. Had to
  rewrite the pool-cycling from bash `mapfile` (not available - macOS ships
  bash 3.2) to a plain `while read` array build, and from a bash `while`
  loop over the cycle indices to an `awk` one-shot (fast enough at 100k+
  requests; a bash loop over that many lines would be the bottleneck).
- `summarize.py` - percentile/throughput report from the results CSV.
- Verified against a local Python mock HTTP server (not real memex/Atlas,
  which weren't available in this environment): confirmed parallelism
  actually changes throughput (P1 ~12 req/s vs P10 ~63 req/s against the
  same artificial per-request delay), and confirmed pool-cycling distributes
  evenly (10 requests over a 3-query pool -> 4/3/3 split).
- Decisions taken from user answers: pool size 10,000, default endpoint
  `http://localhost:8080/api/listings/search`, values sourced from CSVs
  directly (not a fresh DataGen sample run).
- `queries/` and `results/*.csv` are gitignored (39MB/10,000 files,
  regenerates in ~2s - not worth committing).
- NOT yet tested against the real memex app / live Atlas Search index -
  first real test should be a small `--total 20 --parallelism 1` smoke run
  once pulled onto a box with memex actually running, to sanity check the
  generated query shapes are all accepted (200s, not 400s) before scaling up.

## --limit flag added (commit 1684114)
`generate_queries.py --limit N` (default 200) sets a fixed `limit` value for
every generated query, replacing the earlier random choice from
`[10,20,20,20,50]`.

## Atlas Search date handling fix (commit ef6d05e, also ported to
MongoEnterpriseWebServices as 90bbe0b) - user hit
"Path 'dateSold' needs to be indexed as token" in memex logs. Root cause:
`main.js`'s exact-date-match branch unwrapped `{"$date": iso}` down to a
bare ISO string before assigning it to the `$search` range clause's
gte/lte - a bare string against a date-typed indexed path makes Atlas
Search fall back to token/string-match semantics, hence the error (nothing
wrong with dateSold's actual "date" type mapping). Fixed by keeping
gte/lte wrapped as `{"$date": val.$date}`. The `>`/`<` branch was already
correct (val.$gt/$lt already preserve the full `{"$date":...}` object).
Also fixed the equivalent bug in `generate_queries.py` (was emitting plain
"YYYY-MM-DD" strings for `dateSold` clause values) and added `gt`-only/
`lt`-only single-sided range generation for dates (and numbers), mirroring
mongoQuery's real `>`/`<`/exact-match shapes rather than only symmetric
two-sided ranges.

## Query field-combination requirement (this change)
Per explicit request: every generated query must combine at least 2
distinct field-specific filter clauses, UNLESS it's a pure global full-text
query (`fulltext_only`, no field filters at all - covers the "0 filters"
case). Changes in `build_query()`:
- Removed the `scoped_text` style entirely (single-field text search) -
  redundant with `fulltext_only` for testing the "no filters" case.
- `n_filters = rng.randint(2, 3)` (was `randint(1, 3)`) for both remaining
  non-fulltext styles (`filters_only`, `compound_with_text`).
- Style weights adjusted to `fulltext_only`/`compound_with_text`/
  `filters_only` = 25/40/35 (was 25/35/25/15 across 4 styles).
- Verified on a regenerated 10,000-query pool: field-count distribution
  within compound queries is exactly `{2: ~3728, 3: ~3797}` - zero 1-field
  compound queries remain, minimum is 2 as required.
