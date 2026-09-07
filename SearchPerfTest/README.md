# SearchPerfTest

A small, dependency-light toolkit to load-test the Atlas Search endpoint
(`POST /api/listings/search`) of the `listing` collection, with adjustable
total request count and parallelism.

Uses only `curl`, `xargs`, `bash`, and `python3` - no `ab`/`hey`/`wrk`/`vegeta`
install required. See `NOTES.md` for the full rationale/history behind this
toolkit and the fixes made along the way to the search index and DataGen data
that this relies on.

## How does it know which fields to test?

It doesn't hardcode a field list. `generate_queries.py`:

1. **Reads the field list straight from the live Atlas Search index
   definition** - it parses
   `memex/src/main/java/com/johnlpage/memex/Listing/service/ListingPreflightConfig.java`'s
   `getSearchIndexes()` JSON directly out of the Java source. If you change
   the index definition (add/remove/retype a field), just rerun this script
   and the query pool follows automatically - nothing to keep in sync by
   hand. For the one field mapped as a dynamic embedded document
   (`hoa_details`, which has no static per-field type listing in the index
   itself), the actual sub-fields are discovered by looking for DataGen CSV
   columns nested under that path, since the CSVs are the real source of the
   generated document shape.

2. **Samples realistic values straight from `DataGen/Zillow/*.csv.gz`** - the
   exact same probability-weighted generator input files used to produce the
   16M documents loaded into Atlas - including parsing DataGen's macro
   tokens (`@INTEGER(min,max)`, `@DOUBLE(a,b)`, `@DATE(start,end)`,
   `@DATETIME(start,end)`, `@ONEUP`) into proper random samplers instead of
   treating them as literal values.

Run `python3 generate_queries.py --explain` at any time to see exactly which
fields were found and used (or skipped, and why - e.g. boolean fields are
excluded since Atlas Search/the UI can't reliably filter on them) and which
CSV file each field's values came from.

## Workflow

### 1. Generate the query pool (once, or whenever the search index/data changes)

```bash
python3 generate_queries.py                 # writes 10,000 query files to queries/, limit=200 each
python3 generate_queries.py --explain       # just show field discovery, don't generate
python3 generate_queries.py --count 2000    # smaller/larger pool
python3 generate_queries.py --limit 50      # override the per-query "limit" (default 200)
```

Each file in `queries/` is a complete request body for
`POST /api/listings/search`:
```json
{"search": {...}, "projection": {...}, "skip": 0, "limit": 20}
```
The generator produces a mix of query shapes: pure full-text (matching the
UI's free-text search box, no field-specific filters), compound (2-3 field
filters + full-text), and filter-only (2-3 field filters, dropdown-style, no
keyword) - every query combines at least 2 field-specific filters unless
it's a global full-text search. Each field filter uses a realistic mix of
`equals`/`range`/`text` operators, matching what the UI's query builder
actually sends (see `main.js`'s `searchQuery` computed property).

### 2. Run a load test

```bash
./run_queries.sh [endpoint] [queries_dir] [total_requests] [parallelism] [results_csv]
```

All arguments are positional and optional (pass `-` to keep a default while
overriding a later argument):

```bash
./run_queries.sh                                                    # smoke test: 100 requests, linear (1 at a time)
./run_queries.sh - - 1000 5                                          # 1000 requests, 5 concurrent
./run_queries.sh http://localhost:8080/api/listings/search - 100000 10   # 100,000 requests, 10 concurrent
./run_queries.sh http://<ec2-ip>:8080/api/listings/search - 100000 20    # against the real EC2/Atlas deployment
```

- `-P 1` (parallelism 1) = strictly linear/sequential requests.
- `-P 10` = 10 requests in flight concurrently.
- If `total_requests` exceeds the pool size, queries are cycled through
  (e.g. 100,000 requests from a 10,000-query pool replays the pool 10 times).
- Results are appended to a CSV (default: `results/run_<timestamp>.csv`) with
  columns `query_file,time_total_seconds,http_status`, and a summary is
  printed automatically at the end of the run.

### 3. Re-summarize a previous run

```bash
python3 summarize.py results/run_20260902_150051.csv --elapsed 7.921
```

Prints request count, success/error breakdown, min/mean/p50/p90/p95/p99/max
latency, and throughput (req/s) if `--elapsed` (the wall-clock time printed
by `run_queries.sh`) is given.

## Why curl + xargs instead of ab/hey/wrk/vegeta

- `ab` (ApacheBench) and `hey` only support **one fixed POST body** for the
  entire run - can't vary the query per request, which we need since every
  request should be a different, realistic search.
- `wrk` can vary bodies, but only via a Lua scripting layer - unnecessary
  complexity for this.
- `curl` supports a per-request body via `--data @<file>` and has built-in
  timing instrumentation via `-w "%{time_total},%{http_code}"` - no external
  timing code needed.
- `xargs -P N` gives exact, trivial control over concurrency and works with
  macOS's stock BSD xargs (no GNU coreutils required).

## Files

- `generate_queries.py` - generates the query pool (see above).
- `run_queries.sh` - replays the pool at a given total/parallelism, measuring
  latency.
- `summarize.py` - latency/throughput report from a results CSV.
- `queries/` - generated query JSON files (gitignored - run
  `generate_queries.py` to (re)create; takes a couple of seconds for 10,000
  files).
- `results/` - run output CSVs (gitignored).
- `NOTES.md` - running log of context/decisions behind this toolkit and the
  related Atlas Search index / DataGen fixes made alongside it.
