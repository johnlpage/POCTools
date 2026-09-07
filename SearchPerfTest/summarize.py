#!/usr/bin/env python3
"""
Summarize a results CSV produced by run_queries.sh
(columns: query_file,time_total_seconds,http_status).

Usage:
    python3 summarize.py results/run_20260902_143000.csv --elapsed 42.317
"""
import argparse
import csv
import sys
from pathlib import Path


def percentile(sorted_values, pct):
    if not sorted_values:
        return float("nan")
    k = (len(sorted_values) - 1) * (pct / 100)
    f = int(k)
    c = min(f + 1, len(sorted_values) - 1)
    if f == c:
        return sorted_values[f]
    return sorted_values[f] + (sorted_values[c] - sorted_values[f]) * (k - f)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results_csv", type=Path)
    parser.add_argument("--elapsed", type=float, default=None,
                         help="Total wall-clock seconds for the run (printed by run_queries.sh); "
                              "used to compute throughput. If omitted, throughput is not shown.")
    args = parser.parse_args()

    if not args.results_csv.exists():
        sys.exit(f"No such file: {args.results_csv}")

    latencies = []
    statuses = {}
    with args.results_csv.open(newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        for row in reader:
            if len(row) < 3:
                continue
            _file, time_total, status = row[0], row[1], row[2]
            try:
                latencies.append(float(time_total))
            except ValueError:
                continue
            statuses[status] = statuses.get(status, 0) + 1

    if not latencies:
        sys.exit("No valid result rows found in CSV.")

    latencies.sort()
    count = len(latencies)
    success = sum(v for k, v in statuses.items() if k.strip() == "200")
    errors = count - success

    print(f"Results file:    {args.results_csv}")
    print(f"Total requests:  {count}")
    print(f"  200 OK:        {success}")
    if errors:
        print(f"  non-200:       {errors}")
        for status, n in sorted(statuses.items()):
            if status.strip() != "200":
                print(f"    {status or '(no response / curl error)'}: {n}")
    print()
    print("Latency (seconds):")
    print(f"  min:   {latencies[0]:.4f}")
    print(f"  mean:  {sum(latencies) / count:.4f}")
    print(f"  p50:   {percentile(latencies, 50):.4f}")
    print(f"  p90:   {percentile(latencies, 90):.4f}")
    print(f"  p95:   {percentile(latencies, 95):.4f}")
    print(f"  p99:   {percentile(latencies, 99):.4f}")
    print(f"  max:   {latencies[-1]:.4f}")

    if args.elapsed:
        print()
        print(f"Wall-clock elapsed: {args.elapsed:.3f}s")
        print(f"Throughput:         {count / args.elapsed:.1f} req/s")


if __name__ == "__main__":
    main()
