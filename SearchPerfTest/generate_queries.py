#!/usr/bin/env python3
"""
Generate a pool of Atlas Search query JSON files for the `listing` collection's
/api/listings/search endpoint.

IMPORTANT - field discovery is NOT hardcoded here:

1. The set of fields to query is read directly out of
   memex/.../Listing/service/ListingPreflightConfig.java's getSearchIndexes()
   definition (the actual live Atlas Search index config) by parsing the Java
   source's embedded JSON. If that file's field list changes (fields added,
   removed, retyped), just rerun this script - it follows automatically. For
   the one field mapped as a dynamic embedded document ("hoa_details", which
   has no static per-field type listing in the index itself), the actual
   sub-fields are discovered by looking for DataGen CSV columns nested under
   that path, since the CSVs are the real source of the generated document
   shape.

2. Realistic values for each field are sampled directly from the DataGen
   generator's own input files (DataGen/Zillow/*.csv.gz) - the exact same
   probability-weighted CSVs used to generate the 16M documents loaded into
   Atlas - rather than any hand-typed/guessed value list. This includes
   parsing DataGen's special macro tokens (@INTEGER(min,max), @DOUBLE(a,b),
   @DATE(start,end), @DATETIME(start,end), @ONEUP) into the correct kind of
   random sampler instead of treating them as literal string values.

Run with --explain to see exactly which fields were found/used, which were
skipped and why, and where each field's values came from - this is the
running documentation of "how does it know which fields to test".
"""
import argparse
import csv
import gzip
import json
import random
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
JAVA_INDEX_FILE = (
    REPO_ROOT
    / "memex/src/main/java/com/johnlpage/memex/Listing/service/ListingPreflightConfig.java"
)
ZILLOW_DIR = REPO_ROOT / "DataGen/Zillow"
GRID_FIELDS_FILE = REPO_ROOT / "memex/src/main/resources/public/configapi/gridFields.json"

# Words too common/short to make interesting free-text search terms.
STOPWORDS = {
    "this", "that", "with", "from", "have", "will", "your", "their", "there",
    "been", "were", "than", "then", "into", "such", "these", "those", "also",
    "very", "some", "more", "most", "each", "both", "over", "only", "which",
    "when", "what", "where", "while", "about", "after", "before", "being",
    "home", "home.",
}


# ---------------------------------------------------------------------------
# Step 1: parse the actual live Atlas Search index definition straight out of
# the Java source - this is the single source of truth for which fields are
# indexed, not a list maintained separately here.
# ---------------------------------------------------------------------------
def load_search_index_mappings():
    if not JAVA_INDEX_FILE.exists():
        sys.exit(f"Cannot find {JAVA_INDEX_FILE}")
    src = JAVA_INDEX_FILE.read_text()
    m = re.search(r'SEARCH_INDEXES\s*=\s*"""(.*?)"""\s*;', src, re.S)
    if not m:
        sys.exit(f"Could not find the SEARCH_INDEXES text block inside {JAVA_INDEX_FILE}")
    envelope = json.loads(m.group(1))
    return envelope["searchIndexes"][0]["definition"]["mappings"]


def flatten_index_fields(mappings, csv_index, prefix="", explain=None):
    """
    Walk the Atlas Search "mappings.fields" tree from ListingPreflightConfig.java
    and return {field_path: declared_type}. declared_type is "string"/"number"/
    "date" for explicitly typed leaf fields, or "auto" for fields discovered
    under a {"type":"document","dynamic":true} sub-object (no static type
    given in the index itself - inferred later from the actual CSV values).
    """
    fields = {}
    for name, spec in mappings.get("fields", {}).items():
        path = f"{prefix}{name}"
        if isinstance(spec, list):
            # Multi-type field, e.g. [{"type":"string"},{"type":"autocomplete"}] -
            # not used by the current index, but handled generically: prefer the
            # first concrete, non-autocomplete type.
            spec = next((s for s in spec if s.get("type") not in (None, "autocomplete")), spec[0])
        spec_type = spec.get("type")
        if spec_type == "document":
            if "fields" in spec:
                fields.update(
                    flatten_index_fields(spec, csv_index, prefix=f"{path}.", explain=explain)
                )
            elif spec.get("dynamic"):
                sub_prefix = f"{path}."
                discovered = sorted(p for p in csv_index if p.startswith(sub_prefix))
                if explain is not None:
                    explain.append(
                        f"  '{path}' is a dynamic embedded document in the index "
                        f"(no static field list) -> discovered sub-fields from "
                        f"DataGen CSVs: {discovered or '(none found)'}"
                    )
                for sub_path in discovered:
                    fields[sub_path] = "auto"
        else:
            fields[path] = spec_type
    return fields


# ---------------------------------------------------------------------------
# Step 2: build an index of every column across DataGen/Zillow/*.csv.gz
# (top-level files only - NOT the homeValuation/comps, nearbyHomes,
# nearbyZipcodes subfolders, which define fields local to array-of-object
# sub-schemas rather than root-document fields) mapping the exact dotted
# field path (matching the CSV header, which already uses dotted notation for
# nested fields per DataGen's convention) to its raw (value, probability)
# rows, macro tokens included verbatim for later parsing.
# ---------------------------------------------------------------------------
def build_csv_index():
    index = {}
    for path in sorted(ZILLOW_DIR.glob("*.csv.gz")):
        with gzip.open(path, "rt", newline="") as f:
            reader = csv.DictReader(f)
            fieldnames = reader.fieldnames or []
            cols = [c for c in fieldnames if c and c.lower() != "probability"]
            for row in reader:
                try:
                    weight = float(row.get("probability", "1") or "1")
                except ValueError:
                    weight = 1.0
                for col in cols:
                    raw = (row.get(col) or "").strip()
                    if raw == "":
                        continue
                    index.setdefault(col, []).append((raw, weight, path.name))
    return index


MACRO_RE = re.compile(r"@(INTEGER|DOUBLE|DATE|DATETIME)\(([^,]+),([^)]+)\)")


def parse_cell(raw):
    """Classify one raw CSV cell value into a (kind, ...) tuple."""
    if raw == "@ONEUP":
        return ("oneup",)
    m = MACRO_RE.match(raw)
    if m:
        macro, a, b = m.group(1), m.group(2), m.group(3)
        if macro == "INTEGER":
            return ("int_range", float(a), float(b))
        if macro == "DOUBLE":
            a, b = float(a), float(b)
            return ("double_range", min(a, b), max(a, b))
        if macro == "DATE":
            return ("date_range", a, b)
        if macro == "DATETIME":
            return ("datetime_range", a, b)
    return ("literal", raw)


# ---------------------------------------------------------------------------
# Step 3: a sampler for one field, built from its raw CSV rows.
# ---------------------------------------------------------------------------
class FieldSampler:
    MACRO_KINDS = {"int_range", "double_range", "date_range", "datetime_range", "oneup"}

    def __init__(self, path, rows, total_docs):
        self.path = path
        self.total_docs = total_docs
        self.kind = "empty"
        self.macro = None
        self.values = []  # list of (value, weight)
        self.source_files = sorted({r[2] for r in rows})
        self._build(rows)

    def _build(self, rows):
        parsed_rows = [(parse_cell(raw), weight) for raw, weight, _f in rows]
        macros = [(p, w) for p, w in parsed_rows if p[0] in self.MACRO_KINDS]
        if macros:
            parsed, _ = macros[0]
            self.kind = parsed[0]
            self.macro = parsed[1:]
            return

        literals = [(p[1], w) for p, w in parsed_rows if p[0] == "literal"]
        if not literals:
            return

        vals_lower = {v.lower() for v, _ in literals}
        if vals_lower <= {"true", "false"}:
            self.kind = "bool_list"
            self.values = [(v.lower() == "true", w) for v, w in literals]
            return

        try:
            numeric = [(float(v), w) for v, w in literals]
            all_int = all(float(v).is_integer() for v, _w in literals)
            self.values = [(int(v) if all_int else v, w) for v, w in numeric]
            self.kind = "number_list"
            return
        except ValueError:
            pass

        self.kind = "string_list"
        self.values = literals

    def is_boolean(self):
        return self.kind == "bool_list"

    def is_numeric(self):
        return self.kind in ("int_range", "double_range", "number_list", "oneup")

    def is_dateish(self):
        return self.kind in ("date_range", "datetime_range")

    def is_stringish(self):
        return self.kind == "string_list"

    def sample(self, rng):
        if self.kind == "int_range":
            lo, hi = self.macro
            return rng.randint(int(lo), int(hi))
        if self.kind == "double_range":
            lo, hi = self.macro
            return round(rng.uniform(lo, hi), 2)
        if self.kind in ("date_range", "datetime_range"):
            start, end = self.macro
            return self._random_date_between(start, end, rng, is_datetime=(self.kind == "datetime_range"))
        if self.kind == "oneup":
            # @ONEUP fields are sequential counters at generation time, not a
            # weighted value list - approximate the plausible id space instead.
            # bootstrap.sh runs 2 @ONEUP fields (listingId, zpid) per document,
            # each consuming one counter tick, so the id space is ~2x total docs.
            return rng.randint(1, max(2 * self.total_docs, 2))
        if self.kind in ("number_list", "string_list", "bool_list"):
            vals = [v for v, _w in self.values]
            weights = [w for _v, w in self.values]
            return rng.choices(vals, weights=weights, k=1)[0]
        return None

    def sample_range(self, rng):
        a, b = self.sample(rng), self.sample(rng)
        if a is None or b is None:
            return a, b
        lo, hi = (a, b) if a <= b else (b, a)
        if lo == hi:
            if isinstance(hi, (int, float)):
                hi = hi + 1
        return lo, hi

    @staticmethod
    def _random_date_between(start, end, rng, is_datetime):
        fmt = "%Y-%m-%dT%H:%M:%S" if is_datetime else "%Y-%m-%d"
        s = datetime.strptime(start, fmt)
        e = datetime.strptime(end, fmt)
        delta = (e - s).total_seconds()
        result = s + timedelta(seconds=rng.uniform(0, max(delta, 0)))
        # Full ISO 8601 datetime with milliseconds + 'Z', matching exactly
        # what JS's Date.prototype.toISOString() produces (see main.js's
        # mongoQuery computed property) - this raw string must be wrapped in
        # MongoDB Extended JSON's {"$date": "..."} form wherever it's placed
        # into a query clause (see build_clause below), or the server parses
        # it as a plain BSON string instead of a real date, which causes
        # Atlas Search to reject it with "needs to be indexed as token" (it
        # falls back to token/string-match semantics for a string value
        # against a field that isn't indexed as a token).
        return result.strftime("%Y-%m-%dT%H:%M:%S.000Z")


# ---------------------------------------------------------------------------
# Step 4: build the pool of samplers for every field the search index
# actually defines, explaining every inclusion/exclusion decision.
# ---------------------------------------------------------------------------
def build_field_samplers(total_docs, explain):
    csv_index = build_csv_index()
    mappings = load_search_index_mappings()
    declared_fields = flatten_index_fields(mappings, csv_index, explain=explain)

    explain.append(
        f"\nSearch index defines {len(declared_fields)} field(s) "
        f"(from {JAVA_INDEX_FILE.relative_to(REPO_ROOT)}):"
    )

    samplers = {}
    for path, declared_type in sorted(declared_fields.items()):
        rows = csv_index.get(path)
        if not rows:
            explain.append(
                f"  SKIP '{path}' (declared type: {declared_type}) - no matching "
                f"column found in any DataGen/Zillow/*.csv.gz file, cannot "
                f"generate realistic values for it"
            )
            continue

        sampler = FieldSampler(path, rows, total_docs)

        if sampler.is_boolean():
            explain.append(
                f"  SKIP '{path}' (declared type: {declared_type}) - boolean "
                f"field; Atlas Search / the UI's query builder can't reliably "
                f"filter on booleans (see SearchPerfTest/NOTES.md), excluded "
                f"from the generated query pool"
            )
            continue

        if sampler.kind == "empty":
            explain.append(f"  SKIP '{path}' - CSV column found but yielded no usable values")
            continue

        samplers[path] = (declared_type, sampler)
        explain.append(
            f"  USE  '{path}' (declared type: {declared_type}, sampled kind: "
            f"{sampler.kind}, source: {', '.join(sampler.source_files)})"
        )

    return samplers


# ---------------------------------------------------------------------------
# Step 5: extract candidate free-text keywords from the description field's
# own generated content (rather than a hand-picked word list).
# ---------------------------------------------------------------------------
def extract_keywords(samplers):
    desc = samplers.get("description")
    words = set()
    if desc:
        _decl, sampler = desc
        for value, _w in sampler.values:
            if not isinstance(value, str):
                continue
            for raw_word in re.split(r"[^A-Za-z]+", value):
                w = raw_word.lower()
                if len(w) >= 5 and w not in STOPWORDS:
                    words.add(w)
    if not words:
        words = {"renovated", "waterfront", "garage", "fireplace", "hardwood"}
    return sorted(words)


# ---------------------------------------------------------------------------
# Step 6: build one query envelope.
# ---------------------------------------------------------------------------
def build_clause(path, declared_type, sampler, rng):
    """Return an Atlas Search operator document for one field, matching the
    same operator choices main.js's query builder actually uses/supports:
    "equals" for number exact matches, "range" for </>/between on numbers and
    dates, "text" for strings. Mirrors mongoQuery's actual set of shapes - a
    plain value (exact match), a "<value" (lt-only), or a ">value" (gt-only)
    - rather than only ever generating symmetric two-sided ranges.

    Dates are ALWAYS expressed via "range" (never "equals") with values
    wrapped in MongoDB Extended JSON's {"$date": "..."} form - this exactly
    mirrors the main.js fix for the same field: a plain ISO string value
    against a "date"-typed indexed field gets parsed server-side as a BSON
    string, not a real date, and Atlas Search then rejects it with "needs to
    be indexed as token" (it falls back to token/string-match semantics for
    a string value against a field that isn't indexed as a token)."""
    is_date = declared_type == "date" or (declared_type == "auto" and sampler.is_dateish())
    is_number = declared_type == "number" or (declared_type == "auto" and sampler.is_numeric())

    def as_date_value(v):
        return {"$date": v} if is_date else v

    if is_date or is_number:
        op = rng.choices(["equals", "gt", "lt", "range"], weights=[30, 20, 20, 30], k=1)[0]

        if op == "equals" and not is_date:
            value = sampler.sample(rng)
            if value is None:
                return None
            return {"equals": {"path": path, "value": value}}

        if op in ("equals", "range"):
            lo, hi = sampler.sample_range(rng)
            if lo is None or hi is None:
                return None
            if op == "equals":
                # No dedicated exact-match operator used for dates (see
                # docstring) - an inclusive gte===lte range is equivalent.
                lo = hi = sampler.sample(rng)
                if lo is None:
                    return None
            return {"range": {"path": path, "gte": as_date_value(lo), "lte": as_date_value(hi)}}

        value = sampler.sample(rng)
        if value is None:
            return None
        bound = "gt" if op == "gt" else "lt"
        return {"range": {"path": path, bound: as_date_value(value)}}

    value = sampler.sample(rng)
    if value is None:
        return None
    return {"text": {"path": path, "query": str(value)}}


def build_query(samplers, keywords, grid_projection, rng, limit):
    field_paths = list(samplers.keys())
    # "fulltext_only" (a global free-text search, no field-specific filters)
    # is the only style allowed to combine fewer than 2 fields. Every other
    # style combines at least 2 distinct field-specific filter clauses -
    # "scoped_text" (a single scoped field, no filters) was removed since a
    # plain global fulltext query already covers the "0 filter fields" case.
    style = rng.choices(
        ["fulltext_only", "compound_with_text", "filters_only"],
        weights=[25, 40, 35],
        k=1,
    )[0]

    search = {"index": "default"}
    must = []

    if style == "fulltext_only":
        search["text"] = {"query": rng.choice(keywords), "path": {"wildcard": "*"}}

    else:
        n_filters = rng.randint(2, 3)
        chosen = rng.sample(field_paths, k=min(n_filters, len(field_paths)))
        for path in chosen:
            decl, sampler = samplers[path]
            clause = build_clause(path, decl, sampler, rng)
            if clause:
                must.append(clause)

        if style == "compound_with_text":
            must.append({"text": {"query": rng.choice(keywords), "path": {"wildcard": "*"}}})

        if not must:
            search["text"] = {"query": rng.choice(keywords), "path": {"wildcard": "*"}}
        else:
            search["compound"] = {"must": must}

    skip = rng.choice([0, 0, 0, 20, 40])

    return {
        "search": search,
        "projection": grid_projection,
        "skip": skip,
        "limit": limit,
    }


def load_grid_projection():
    projection = {}
    if GRID_FIELDS_FILE.exists():
        grid_fields = json.loads(GRID_FIELDS_FILE.read_text())
        for storage_path in grid_fields.values():
            # No support for a.$.b in projections (matches main.js's own
            # handling in runGridQuery) - not expected for Listing fields.
            projection[re.sub(r"\$.*", "$", storage_path)] = True
    projection["score"] = {"$meta": "searchScore"}
    return projection


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=10000, help="Number of distinct query files to generate")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "queries",
                         help="Output directory for generated query JSON files")
    parser.add_argument("--total-docs", type=int, default=16_000_000,
                         help="Approximate total documents in the collection (used to size the @ONEUP id sampling range for zpid)")
    parser.add_argument("--seed", type=int, default=42, help="Random seed for reproducible query pools")
    parser.add_argument("--limit", type=int, default=200,
                         help="Value used for the 'limit' field in every generated query envelope")
    parser.add_argument("--explain", action="store_true",
                         help="Print field discovery/sampling decisions and exit without generating files")
    args = parser.parse_args()

    explain = []
    samplers = build_field_samplers(args.total_docs, explain)

    print("\n".join(explain))
    print(f"\n{len(samplers)} field(s) will be used to generate queries: {', '.join(sorted(samplers))}\n")

    if args.explain:
        return

    if not samplers:
        sys.exit("No usable fields found - cannot generate queries.")

    keywords = extract_keywords(samplers)
    grid_projection = load_grid_projection()
    rng = random.Random(args.seed)

    args.out.mkdir(parents=True, exist_ok=True)
    width = max(5, len(str(args.count)))
    for i in range(1, args.count + 1):
        query = build_query(samplers, keywords, grid_projection, rng, args.limit)
        out_path = args.out / f"query_{i:0{width}d}.json"
        out_path.write_text(json.dumps(query))

    print(f"Wrote {args.count} query files to {args.out}")


if __name__ == "__main__":
    main()
