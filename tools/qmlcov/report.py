#!/usr/bin/env python3
"""
Compute QML coverage from a catalog + a hits-marker stream.

Reads the runner's stdout from --runlog, finds every line containing
`__COV_TICK__:<key>` (emitted by the Cov singleton on first-seen-per-engine),
unions the keys, and computes per-file + overall coverage as
`sum(LOC of hit units) / sum(LOC of all units)`.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


_TICK = re.compile(r"__COV_TICK__:([^\s\"]+)")


def extract_hit_keys(runlog_text: str) -> set[str]:
    return set(_TICK.findall(runlog_text))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--runlog", required=True)
    ap.add_argument("--threshold", type=float, default=0.80)
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    catalog = json.loads(Path(args.catalog).read_text(encoding="utf-8"))
    runlog = Path(args.runlog).read_text(encoding="utf-8", errors="replace")
    hit_keys = extract_hit_keys(runlog)

    by_file_total = defaultdict(int)
    by_file_hit = defaultdict(int)
    by_file_total_units = defaultdict(int)
    by_file_hit_units = defaultdict(int)

    for u in catalog["units"]:
        by_file_total[u["file"]] += u["loc"]
        by_file_total_units[u["file"]] += 1
        if u["key"] in hit_keys:
            by_file_hit[u["file"]] += u["loc"]
            by_file_hit_units[u["file"]] += 1

    total_loc = sum(by_file_total.values())
    hit_loc = sum(by_file_hit.values())
    overall = (hit_loc / total_loc) if total_loc else 1.0

    print(f"{'File':<50}{'Units':>10}{'LOC':>10}{'Cov':>8}")
    print("-" * 78)
    files = sorted(by_file_total.keys(), key=lambda f: -by_file_total[f])
    for f in files:
        u_hit = by_file_hit_units[f]
        u_total = by_file_total_units[f]
        l_hit = by_file_hit[f]
        l_total = by_file_total[f]
        pct = (l_hit / l_total) if l_total else 1.0
        print(
            f"{f:<50}{u_hit:>3}/{u_total:<6d}{l_hit:>4}/{l_total:<5d}{pct * 100:>6.1f}%"
        )
    print("-" * 78)
    print(
        f"{'TOTAL':<50}{'':>10}{hit_loc:>4}/{total_loc:<5d}{overall * 100:>6.1f}%"
    )
    print(f"Threshold: {args.threshold * 100:.0f}%")
    print(f"Hits: {len(hit_keys)} unique keys")

    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps(
                {
                    "overall_coverage": overall,
                    "hit_loc": hit_loc,
                    "total_loc": total_loc,
                    "hit_keys": sorted(hit_keys),
                    "threshold": args.threshold,
                    "by_file": {
                        f: {
                            "loc_hit": by_file_hit[f],
                            "loc_total": by_file_total[f],
                            "units_hit": by_file_hit_units[f],
                            "units_total": by_file_total_units[f],
                            "coverage": (by_file_hit[f] / by_file_total[f])
                            if by_file_total[f]
                            else 1.0,
                        }
                        for f in files
                    },
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    if overall < args.threshold:
        print(
            f"FAIL: coverage {overall * 100:.1f}% < threshold "
            f"{args.threshold * 100:.0f}%",
            file=sys.stderr,
        )
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
