#!/usr/bin/env python3
"""Estimate Lockpaw's active installs from getlockpaw.com's appcast requests.

Sparkle fetches https://getlockpaw.com/appcast.xml about once a day from every install
that has automatic update checks on, with the User-Agent "Lockpaw/<version> Sparkle/<x>".
Counting distinct sources per day gives an active-install estimate without any telemetry
in the app — the "no analytics" promise stays word for word.

It is a floor, not a census:
  - installs that declined automatic checks never fetch the appcast unprompted;
  - several Macs behind one NAT/IP count once (raw logs) — the PHP counter hashes the IP
    too, so the same caveat applies;
  - a Mac that's asleep or not running Lockpaw that day doesn't check.

Input: raw web-server access logs (Combined Log Format, plain or .gz) and/or the TSV the
optional PHP counter writes (date<TAB>version<TAB>source-hash). IPs are only hashed in
memory with a per-run random salt and never written anywhere.

Usage:
  scripts/active-users.py access.log access.log.1.gz ...
  scripts/active-users.py --days 28 stats/*.tsv
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import gzip
import hashlib
import os
import re
import sys

COMBINED = re.compile(
    r'^(?P<ip>\S+) \S+ \S+ \[(?P<ts>[^\]]+)\] "(?P<method>[A-Z]+) (?P<path>\S+)[^"]*" '
    r'(?P<status>\d{3}) \S+ "[^"]*" "(?P<ua>[^"]*)"'
)
USER_AGENT = re.compile(r"\bLockpaw/([0-9A-Za-z.?]+) Sparkle/")
SALT = os.urandom(16)


def source(ip: str) -> str:
    return hashlib.sha256(SALT + ip.encode()).hexdigest()[:16]


def open_any(path: str):
    return gzip.open(path, "rt", errors="replace") if path.endswith(".gz") else open(path, errors="replace")


def records(paths: list[str]):
    """Yield (date, version, source) for every Lockpaw appcast fetch."""
    for path in paths:
        with open_any(path) as handle:
            for line in handle:
                if "\t" in line:  # the PHP counter's TSV
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) == 3:
                        try:
                            yield dt.date.fromisoformat(parts[0]), parts[1], parts[2]
                            continue
                        except ValueError:
                            pass
                match = COMBINED.match(line)
                if not match or match["method"] != "GET" or not match["path"].startswith("/appcast.xml"):
                    continue
                if match["status"][0] not in "23":
                    continue
                agent = USER_AGENT.search(match["ua"])
                if not agent:
                    continue
                try:
                    day = dt.datetime.strptime(match["ts"].split()[0], "%d/%b/%Y:%H:%M:%S").date()
                except ValueError:
                    continue
                yield day, agent.group(1), source(match["ip"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("logs", nargs="+", help="access logs (.log/.gz) or counter TSV files")
    parser.add_argument("--days", type=int, default=28, help="window for the distinct-installs total (default 28)")
    args = parser.parse_args()

    by_day: dict[dt.date, set[str]] = collections.defaultdict(set)
    versions: dict[str, str] = {}
    seen_on: dict[str, dt.date] = {}
    for day, version, src in records(args.logs):
        by_day[day].add(src)
        if src not in seen_on or day >= seen_on[src]:
            seen_on[src] = day
            versions[src] = version

    if not by_day:
        print("No Lockpaw appcast requests found.", file=sys.stderr)
        return 1

    last = max(by_day)
    window_start = last - dt.timedelta(days=args.days - 1)
    week_start = last - dt.timedelta(days=6)
    in_window = {s for d, ss in by_day.items() if d >= window_start for s in ss}
    week_days = [len(by_day.get(week_start + dt.timedelta(days=i), ())) for i in range(7)]

    print(f"Lockpaw appcast checks, through {last.isoformat()}")
    print(f"  daily distinct sources, last 7 days: {week_days}  (avg {sum(week_days) / 7:.0f})")
    print(f"  distinct sources, last {args.days} days: {len(in_window)}")
    print("  latest version per source (last {} days):".format(args.days))
    tally = collections.Counter(versions[s] for s in in_window)
    for version, count in sorted(tally.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"    {version:>10}  {count}")
    print("\n  Floor estimate: installs with automatic checks off, or offline, aren't counted;")
    print("  several Macs behind one IP count once.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
