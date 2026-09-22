#!/usr/bin/env python3

import csv
import io
import json
import os
import re
import sys
import unicodedata
import zipfile


STOP_WORDS = {
    "im",
    "in",
    "der",
    "die",
    "das",
    "den",
    "des",
    "dem",
    "ein",
    "eine",
    "einer",
    "eines",
    "und",
    "von",
    "vom",
    "am",
    "an",
    "auf",
    "bei",
    "zu",
    "zum",
    "zur",
}

RAIL_WORDS = {
    "bahnhof",
    "hbf",
    "bf",
    "bhf",
    "hauptbahnhof",
    "station",
    "ob",
    "oberer",
    "unterer",
    "ub",
}

IRRELEVANT_WORDS = {
    "autobahn",
    "rastplatz",
    "raststaette",
    "raststätte",
    "parkplatz",
    "tankstelle",
}


def normalize(text):
    if not text:
        return ""

    text = text.strip().lower()

    replacements = {
        "ä": "ae",
        "ö": "oe",
        "ü": "ue",
        "ß": "ss",
    }

    for old, new in replacements.items():
        text = text.replace(old, new)

    text = unicodedata.normalize("NFKD", text)

    text = "".join(
        char
        for char in text
        if not unicodedata.combining(char)
    )

    text = re.sub(r"[\(\)\[\]\{\},.;:/_\\\-]+", " ", text)

    text = re.sub(r"\s+", " ", text).strip()

    return text


def normalized_tokens(text):
    value = normalize(text)

    if not value:
        return []

    tokens = value.split()

    result = []

    for token in tokens:
        if token in STOP_WORDS:
            continue

        if token == "vogtl":
            token = "vogtland"

        if token == "vogt":
            token = "vogtland"

        if token == "bhf":
            token = "bahnhof"

        if token == "hbf":
            token = "bahnhof"

        if token == "bf":
            token = "bahnhof"

        if token == "oberer":
            token = "ob"

        if token == "unterer":
            token = "ub"

        result.append(token)

    return result


def make_search_text(name, location=""):
    base = normalize(name)
    location = normalize(location)
    if location:
        base = f"{base} {location}"

    variants = {base}

    if "vogtl" in base:
        variants.add(base.replace("vogtl", "vogtland"))

    if "vogt " in base:
        variants.add(base.replace("vogt ", "vogtland "))

    if "bahnhof" in base:
        variants.add(base.replace("bahnhof", "bf"))

    if re.search(r"\bbf\b", base):
        variants.add(re.sub(r"\bbf\b", "bahnhof", base))

    if re.search(r"\bhbf\b", base):
        variants.add(re.sub(r"\bhbf\b", "bahnhof", base))

    if re.search(r"\bbhf\b", base):
        variants.add(re.sub(r"\bbhf\b", "bahnhof", base))

    return " | ".join(sorted(variants))


def calculate_priority(name, location_type):
    normalized = normalize(name)
    tokens = set(normalized.split())

    priority = 0

    # GTFS location_type 1 = Station.
    if location_type == 1:
        priority += 1000

    # Railway-related names should appear before ordinary stops.
    if tokens.intersection(RAIL_WORDS):
        priority += 500

    if "hauptbahnhof" in tokens:
        priority += 150

    if "bahnhof" in tokens:
        priority += 150

    if "hbf" in tokens:
        priority += 150

    if "bf" in tokens:
        priority += 100

    if "station" in tokens:
        priority += 100

    # Clearly non-station places should be lower in the results.
    if tokens.intersection(IRRELEVANT_WORDS):
        priority -= 250

    return priority


def bucket_keys(name, location=""):
    tokens = normalized_tokens(name) + normalized_tokens(location)

    keys = set()

    for token in tokens:
        if not token:
            continue

        first = token[0]

        if "a" <= first <= "z":
            keys.add(first)

    if not keys:
        keys.add("_")

    return keys


def parse_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def main():
    if len(sys.argv) != 3:
        print(
            "Usage: build_stops_index.py <gtfs.zip> <output-directory>",
            file=sys.stderr,
        )
        sys.exit(1)

    zip_path = sys.argv[1]
    output_dir = sys.argv[2]

    os.makedirs(output_dir, exist_ok=True)

    buckets = {
        chr(ord("a") + i): {}
        for i in range(26)
    }

    buckets["_"] = {}

    total_rows = 0
    accepted_rows = 0

    print("Opening GTFS ZIP...")

    with zipfile.ZipFile(zip_path, "r") as archive:
        names = archive.namelist()

        stop_file = None

        for name in names:
            if name.lower().endswith("stops.txt"):
                stop_file = name
                break

        if stop_file is None:
            raise RuntimeError("stops.txt was not found in GTFS ZIP")

        print(f"Reading: {stop_file}")

        with archive.open(stop_file, "r") as raw_file:
            text_file = io.TextIOWrapper(
                raw_file,
                encoding="utf-8-sig",
                newline="",
            )

            reader = csv.DictReader(text_file)

            for row in reader:
                total_rows += 1

                stop_id = (row.get("stop_id") or "").strip()
                stop_name = (row.get("stop_name") or "").strip()

                if not stop_id or not stop_name:
                    continue

                location_type = parse_int(
                    row.get("location_type") or "0"
                )

                # We currently need stations and normal stops.
                if location_type not in (0, 1):
                    continue

                lat = parse_float(row.get("stop_lat"))
                lon = parse_float(row.get("stop_lon"))

                if lat is None or lon is None:
                    continue

                parent_station = (
                    row.get("parent_station") or ""
                ).strip()

                location = (
                    row.get("stop_desc") or ""
                ).strip()

                if location == stop_name:
                    location = ""

                search_text = make_search_text(
                    stop_name,
                    location,
                )

                priority = calculate_priority(
                    stop_name,
                    location_type,
                )

                record = {
                    "id": stop_id,
                    "name": stop_name,
                    "location": location,
                    "lat": lat,
                    "lon": lon,
                    "parent": parent_station,
                    "type": location_type,
                    "priority": priority,
                    "search": search_text,
                }

                keys = bucket_keys(
                    stop_name,
                    location,
                )

                for key in keys:
                    existing = buckets[key].get(stop_id)

                    if (
                        existing is None
                        or record["priority"] > existing["priority"]
                    ):
                        buckets[key][stop_id] = record

                accepted_rows += 1

    print(f"Total GTFS stop rows: {total_rows}")
    print(f"Accepted station/stop rows: {accepted_rows}")

    total_records = 0

    for key, records in buckets.items():
        values = list(records.values())

        values.sort(
            key=lambda item: (
                -item["priority"],
                normalize(item["name"]),
                item["id"],
            )
        )

        output_file = os.path.join(
            output_dir,
            f"{key}.json",
        )

        with open(
            output_file,
            "w",
            encoding="utf-8",
        ) as file:
            json.dump(
                values,
                file,
                ensure_ascii=False,
                separators=(",", ":"),
            )

        total_records += len(values)

        print(
            f"{key}.json: {len(values):,} records"
        )

    print("")
    print(
        f"Total indexed records (including bucket duplicates): "
        f"{total_records:,}"
    )
    print("Station search index successfully created.")


if __name__ == "__main__":
    main()
