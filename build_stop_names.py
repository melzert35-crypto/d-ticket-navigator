#!/usr/bin/env python3
"""Erzeugt stop_names.json (Haltestellen-ID -> Anzeigename).

Nimmt nur Haltestellen, die in patterns.json vorkommen (klein, ~8000 Eintraege).
Bei Bahnsteig/Kind-Haltestellen wird der Name der Elternstation verwendet.

Aufruf: build_stop_names.py <gtfs.zip> <patterns.json> <ausgabe.json>
"""

import csv
import io
import json
import sys
import zipfile


def main():
    if len(sys.argv) != 4:
        print("Usage: build_stop_names.py <gtfs.zip> <patterns.json> <output.json>", file=sys.stderr)
        sys.exit(2)

    gtfs_zip, patterns_path, out_path = sys.argv[1:4]

    with open(patterns_path, encoding="utf-8") as f:
        patterns = json.load(f)
    used = set()
    for pattern in patterns:
        used.update(pattern["stops"])

    with zipfile.ZipFile(gtfs_zip) as zf:
        with zf.open("stops.txt") as raw:
            rows = list(csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8-sig")))
    by_id = {r["stop_id"]: r for r in rows}

    names = {}
    for stop_id in used:
        row = by_id.get(stop_id)
        if not row:
            continue
        name = (row.get("stop_name") or "").strip()
        parent = by_id.get(row.get("parent_station") or "")
        if parent and (parent.get("stop_name") or "").strip():
            name = parent["stop_name"].strip()
        if name:
            names[stop_id] = name

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(names, f, ensure_ascii=False, separators=(",", ":"))

    print(f"Haltestellennamen: {len(names)} von {len(used)} Haltestellen aufgeloest")


if __name__ == "__main__":
    main()
