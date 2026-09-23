#!/usr/bin/env python3
"""
build_routing_index.py

Erweitert build_stops_index.py: erzeugt aus einer GTFS-ZIP (rv_free von
gtfs.de) eine kompakte Routing-Datenbasis fuer die App, die NUR
Deutschlandticket-gueltige Verbindungen enthaelt.

Eingabe:  GTFS-ZIP (agency.txt, routes.txt, trips.txt, calendar.txt,
          calendar_dates.txt, stop_times.txt)
Ausgabe:  assets/data/routing/
            routes.json     - gefilterte Routen (id -> short_name, agency)
            patterns.json   - eindeutige (Route, Haltestellenfolge)-Muster
            trips.json      - Einzelfahrten: Muster + Sekunden-Zeiten + Service
            calendar.json   - Servicetage je service_id

Aufruf:
    python3 build_routing_index.py path/zu/rv_free.zip assets/data/routing/

Die Ausschlussliste (agency_exclude.json) liegt neben diesem Skript und
wird bei jedem Lauf geprueft/geladen - so bleibt sie zentral pflegbar
und nachvollziehbar (siehe README-Abschnitt "D-Ticket-Filter").
"""
import csv
import json
import sys
import zipfile
import io
import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
EXCLUDE_FILE = SCRIPT_DIR / "agency_exclude.json"

DAY_ORDER = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

# Sicherheitsnetz zusaetzlich zur Agentur-Sperrliste: Diese Linienpraefixe
# werden verworfen, auch wenn die Agentur nicht auf der Sperrliste steht
# (z.B. bei Datenqualitaetsproblemen, in denen Fernverkehr faelschlich
# unter einer regionalen Agentur auftaucht).
FERNVERKEHR_PATTERNS = ("ICE", "IC ", "IC", "EC", "EN", "NJ", "TGV", "RJ", "RJX")


def load_exclude_agency_ids() -> set[str]:
    with open(EXCLUDE_FILE, encoding="utf-8") as f:
        cls = json.load(f)
    ids: set[str] = set()
    for key in (
        "exclude_fernverkehr",
        "exclude_privat_fern",
        "exclude_fracht",
        "exclude_touristisch_historisch",
        "exclude_review",
    ):
        ids.update(cls.get(key, []))
    return ids


def is_fernverkehr_name(short_name: str) -> bool:
    name = (short_name or "").strip().upper()
    return any(name == p.strip() or name.startswith(p.strip() + " ") for p in FERNVERKEHR_PATTERNS)


def read_csv(zf: zipfile.ZipFile, name: str) -> list[dict]:
    with zf.open(name) as raw:
        text = io.TextIOWrapper(raw, encoding="utf-8-sig")
        return list(csv.DictReader(text))


def time_to_seconds(t: str) -> int:
    h, m, s = t.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def build(gtfs_zip_path: str, out_dir: str) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    exclude_ids = load_exclude_agency_ids()

    with zipfile.ZipFile(gtfs_zip_path) as zf:
        routes_raw = read_csv(zf, "routes.txt")
        trips_raw = read_csv(zf, "trips.txt")
        calendar_raw = read_csv(zf, "calendar.txt")
        calendar_dates_raw = read_csv(zf, "calendar_dates.txt")
        stops_raw = read_csv(zf, "stops.txt")

        # --- Stop-Gruppen: Elternstation -> Liste der Bahnsteig/Kind-IDs.
        # Die Stationssuche (build_stops_index.py) liefert i.d.R. die
        # Eltern-ID (location_type=1). stop_times.txt referenziert aber
        # die Kind-Stops. Ohne diese Zuordnung findet die Routing-Engine
        # bei einer aus der Suche gewaehlten Station keine einzige Fahrt.
        stop_groups: dict[str, list[str]] = {}
        for s in stops_raw:
            parent = s.get("parent_station") or ""
            if parent:
                stop_groups.setdefault(parent, []).append(s["stop_id"])

        # --- Routen filtern (Agentur-Sperrliste + Linienname-Sicherheitsnetz) ---
        valid_routes: dict[str, dict] = {}
        for r in routes_raw:
            if r["agency_id"] in exclude_ids:
                continue
            if is_fernverkehr_name(r.get("route_short_name", "")):
                continue
            valid_routes[r["route_id"]] = r
        print(f"Routen: {len(routes_raw)} gesamt -> {len(valid_routes)} D-Ticket-gueltig")

        # --- Trips filtern ---
        valid_trips: dict[str, dict] = {
            t["trip_id"]: t for t in trips_raw if t["route_id"] in valid_routes
        }
        print(f"Trips: {len(trips_raw)} gesamt -> {len(valid_trips)} gueltig")

        # --- stop_times streamend einlesen (Datei ist gross, ~75 MB) ---
        trip_stops: dict[str, list[tuple[int, str, str, str]]] = {}
        with zf.open("stop_times.txt") as raw:
            text = io.TextIOWrapper(raw, encoding="utf-8-sig")
            for row in csv.DictReader(text):
                tid = row["trip_id"]
                if tid not in valid_trips:
                    continue
                trip_stops.setdefault(tid, []).append(
                    (int(row["stop_sequence"]), row["stop_id"], row["arrival_time"], row["departure_time"])
                )
        for tid in trip_stops:
            trip_stops[tid].sort(key=lambda x: x[0])
        print(f"stop_times: {len(trip_stops)} Trips mit Haltestellenfolge")

        # --- Patterns bilden (Route + Haltestellenfolge) ---
        pattern_index: dict[tuple, int] = {}
        pattern_list: list[dict] = []
        trip_to_pattern: dict[str, int] = {}
        for tid, stops in trip_stops.items():
            route_id = valid_trips[tid]["route_id"]
            stop_seq = tuple(s[1] for s in stops)
            key = (route_id, stop_seq)
            if key not in pattern_index:
                pattern_index[key] = len(pattern_list)
                pattern_list.append({"route_id": route_id, "stops": list(stop_seq)})
            trip_to_pattern[tid] = pattern_index[key]
        print(f"Patterns: {len(trip_stops)} Trips -> {len(pattern_list)} eindeutige Haltestellenfolgen")

        # --- Trips-Ausgabe: Sekunden-Zeiten + Kalender-Referenz ---
        trips_out: dict[str, dict] = {}
        for tid, stops in trip_stops.items():
            dep_secs, arr_diffs = [], []
            for _, _sid, arr, dep in stops:
                d = time_to_seconds(dep)
                a = time_to_seconds(arr)
                dep_secs.append(d)
                arr_diffs.append(a - d)
            trips_out[tid] = {
                "p": trip_to_pattern[tid],
                "s": valid_trips[tid]["service_id"],
                "d": dep_secs,
                "a": arr_diffs,
            }

        # --- Kalender ---
        calendar: dict[str, dict] = {}
        for row in calendar_raw:
            mask = 0
            for i, day in enumerate(DAY_ORDER):
                if row[day] == "1":
                    mask |= 1 << i
            calendar[row["service_id"]] = {
                "mask": mask,
                "start": row["start_date"],
                "end": row["end_date"],
                "added": [],
                "removed": [],
            }
        for row in calendar_dates_raw:
            sid = row["service_id"]
            if sid not in calendar:
                calendar[sid] = {"mask": 0, "start": "99999999", "end": "00000000", "added": [], "removed": []}
            (calendar[sid]["added"] if row["exception_type"] == "1" else calendar[sid]["removed"]).append(
                row["date"]
            )

        # --- Routen-Metadaten (fuer Anzeige: Linienname etc.) ---
        routes_out = {
            rid: {"name": r.get("route_short_name") or r.get("route_long_name", ""), "agency": r["agency_id"]}
            for rid, r in valid_routes.items()
        }

    (out / "routes.json").write_text(json.dumps(routes_out, separators=(",", ":")), encoding="utf-8")
    (out / "patterns.json").write_text(json.dumps(pattern_list, separators=(",", ":")), encoding="utf-8")
    (out / "trips.json").write_text(json.dumps(trips_out, separators=(",", ":")), encoding="utf-8")
    (out / "calendar.json").write_text(json.dumps(calendar, separators=(",", ":")), encoding="utf-8")
    (out / "stop_groups.json").write_text(json.dumps(stop_groups, separators=(",", ":")), encoding="utf-8")
    print(f"Stop-Gruppen: {len(stop_groups)} Elternstationen mit Kind-Haltestellen")
    print(f"Fertig. Ausgabe in {out}/")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Aufruf: python3 build_routing_index.py <gtfs.zip> <out_dir>")
        sys.exit(1)
    build(sys.argv[1], sys.argv[2])
