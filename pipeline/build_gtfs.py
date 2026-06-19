#!/usr/bin/env python3
"""
Cybus static GTFS pipeline.

Downloads the 7 Cyprus provider GTFS zips, validates each, merges them into
one compact SQLite containing only the columns the app needs, computes a
SHA-256 hash, and writes a manifest.json. The GitHub Action then publishes
the SQLite + manifest to the static host.

Usage:
    python build_gtfs.py --out-dir dist/

Environment variables (optional — for upload step):
    STATIC_HOST_TOKEN   secret token for the static hosting upload API
"""

import argparse
import hashlib
import io
import json
import logging
import os
import sqlite3
import struct
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import requests

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Provider definitions
# ---------------------------------------------------------------------------

@dataclass
class Provider:
    name: str
    file_num: int

    @property
    def url(self) -> str:
        encoded = f"GTFS%5C{self.file_num}_google_transit.zip"
        return f"https://motionbuscard.org.cy/opendata/downloadfile?file={encoded}&rel=True"


PROVIDERS = [
    Provider("EMEL",       6),
    Provider("OSYPA",      2),
    Provider("OSEA",       4),
    Provider("Intercity",  5),
    Provider("NPT",        9),
    Provider("LPT",       10),
    Provider("PameExpress",11),
]

# ---------------------------------------------------------------------------
# SQLite schema
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS stops (
    stop_id   TEXT PRIMARY KEY,
    stop_name TEXT NOT NULL,
    stop_lat  REAL NOT NULL,
    stop_lon  REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS routes (
    route_id         TEXT PRIMARY KEY,
    route_short_name TEXT NOT NULL,
    route_color      TEXT,
    route_text_color TEXT
);

CREATE TABLE IF NOT EXISTS trips (
    trip_id       TEXT PRIMARY KEY,
    route_id      TEXT NOT NULL,
    service_id    TEXT,
    trip_headsign TEXT,
    shape_id      TEXT
);

CREATE TABLE IF NOT EXISTS calendar (
    service_id TEXT PRIMARY KEY,
    monday     INTEGER NOT NULL,
    tuesday    INTEGER NOT NULL,
    wednesday  INTEGER NOT NULL,
    thursday   INTEGER NOT NULL,
    friday     INTEGER NOT NULL,
    saturday   INTEGER NOT NULL,
    sunday     INTEGER NOT NULL,
    start_date TEXT NOT NULL,
    end_date   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS calendar_dates (
    service_id     TEXT    NOT NULL,
    date           TEXT    NOT NULL,
    exception_type INTEGER NOT NULL,
    PRIMARY KEY (service_id, date)
);

CREATE TABLE IF NOT EXISTS stop_times (
    trip_id       TEXT    NOT NULL,
    stop_id       TEXT    NOT NULL,
    arrival_time  TEXT,
    departure_time TEXT,
    stop_sequence INTEGER NOT NULL,
    PRIMARY KEY (trip_id, stop_sequence)
);

CREATE TABLE IF NOT EXISTS shapes (
    shape_id          TEXT    NOT NULL,
    shape_pt_lat      REAL    NOT NULL,
    shape_pt_lon      REAL    NOT NULL,
    shape_pt_sequence INTEGER NOT NULL,
    PRIMARY KEY (shape_id, shape_pt_sequence)
);

CREATE INDEX IF NOT EXISTS idx_stop_times_stop ON stop_times(stop_id);
CREATE INDEX IF NOT EXISTS idx_trips_route     ON trips(route_id);
CREATE INDEX IF NOT EXISTS idx_shapes_id       ON shapes(shape_id);
CREATE INDEX IF NOT EXISTS idx_stops_latlon    ON stops(stop_lat, stop_lon);
"""

# ---------------------------------------------------------------------------
# Download + validate
# ---------------------------------------------------------------------------

MAX_ZIP_BYTES = 50 * 1024 * 1024   # 50 MB bomb guard
TIMEOUT_S = 60

def download_provider(provider: Provider) -> bytes:
    """Download a provider zip, enforcing magic-byte and size checks."""
    log.info(f"Downloading {provider.name} from {provider.url}")
    resp = requests.get(provider.url, timeout=TIMEOUT_S, stream=True)
    resp.raise_for_status()

    chunks = []
    total = 0
    for chunk in resp.iter_content(chunk_size=65536):
        total += len(chunk)
        if total > MAX_ZIP_BYTES:
            raise ValueError(f"{provider.name}: zip exceeds {MAX_ZIP_BYTES} bytes (zip bomb guard)")
        chunks.append(chunk)
    data = b"".join(chunks)

    # Magic-byte check — "PK\x03\x04"
    if not data[:4] == b"PK\x03\x04":
        raise ValueError(
            f"{provider.name}: response is not a zip archive "
            f"(got {data[:4]!r}). The server may have returned an HTML error page."
        )

    log.info(f"  {provider.name}: {len(data):,} bytes, valid zip")
    return data


def iter_gtfs_rows(zip_bytes: bytes, filename: str) -> Iterator[dict]:
    """Yield dicts for each row in a GTFS text file inside the zip."""
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        # Zip-slip guard: reject any entry with path traversal
        for name in zf.namelist():
            if ".." in name or name.startswith("/"):
                raise ValueError(f"Zip-slip detected: {name!r}")

        if filename not in zf.namelist():
            return  # optional file absent — yield nothing

        with zf.open(filename) as f:
            import csv
            reader = csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))
            for row in reader:
                yield {k.strip(): v.strip() for k, v in row.items()}

# ---------------------------------------------------------------------------
# Merge into SQLite
# ---------------------------------------------------------------------------

def ingest_provider(cur: sqlite3.Cursor, provider: Provider, zip_bytes: bytes) -> None:
    prefix = provider.name + ":"     # namespace all IDs to avoid collisions between providers

    def pid(val: str) -> str:
        return prefix + val if val else val

    log.info(f"  Ingesting stops…")
    for r in iter_gtfs_rows(zip_bytes, "stops.txt"):
        try:
            lat, lon = float(r["stop_lat"]), float(r["stop_lon"])
        except (ValueError, KeyError):
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180 and not (lat == 0 and lon == 0)):
            continue
        cur.execute(
            "INSERT OR IGNORE INTO stops VALUES (?,?,?,?)",
            (pid(r["stop_id"]), r.get("stop_name",""), lat, lon)
        )

    log.info(f"  Ingesting routes…")
    for r in iter_gtfs_rows(zip_bytes, "routes.txt"):
        cur.execute(
            "INSERT OR IGNORE INTO routes VALUES (?,?,?,?)",
            (pid(r["route_id"]),
             r.get("route_short_name") or r.get("route_id",""),
             r.get("route_color") or None,
             r.get("route_text_color") or None)
        )

    log.info(f"  Ingesting trips…")
    for r in iter_gtfs_rows(zip_bytes, "trips.txt"):
        cur.execute(
            "INSERT OR IGNORE INTO trips VALUES (?,?,?,?,?)",
            (pid(r["trip_id"]),
             pid(r["route_id"]),
             pid(r["service_id"]) if r.get("service_id") else None,
             r.get("trip_headsign") or None,
             pid(r["shape_id"]) if r.get("shape_id") else None)
        )

    log.info(f"  Ingesting calendar…")
    for r in iter_gtfs_rows(zip_bytes, "calendar.txt"):
        try:
            days = tuple(int(r[d]) for d in
                         ("monday", "tuesday", "wednesday", "thursday",
                          "friday", "saturday", "sunday"))
        except (ValueError, KeyError):
            continue
        cur.execute(
            "INSERT OR IGNORE INTO calendar VALUES (?,?,?,?,?,?,?,?,?,?)",
            (pid(r["service_id"]), *days,
             r.get("start_date", ""), r.get("end_date", ""))
        )

    log.info(f"  Ingesting calendar_dates…")
    for r in iter_gtfs_rows(zip_bytes, "calendar_dates.txt"):
        try:
            exception_type = int(r["exception_type"])
        except (ValueError, KeyError):
            continue
        if not r.get("date"):
            continue
        cur.execute(
            "INSERT OR IGNORE INTO calendar_dates VALUES (?,?,?)",
            (pid(r["service_id"]), r["date"], exception_type)
        )

    log.info(f"  Ingesting stop_times…")
    rows = []
    for r in iter_gtfs_rows(zip_bytes, "stop_times.txt"):
        try:
            seq = int(r["stop_sequence"])
        except (ValueError, KeyError):
            continue
        rows.append((
            pid(r["trip_id"]),
            pid(r["stop_id"]),
            r.get("arrival_time") or None,
            r.get("departure_time") or None,
            seq,
        ))
        if len(rows) >= 10_000:
            cur.executemany("INSERT OR IGNORE INTO stop_times VALUES (?,?,?,?,?)", rows)
            rows = []
    if rows:
        cur.executemany("INSERT OR IGNORE INTO stop_times VALUES (?,?,?,?,?)", rows)

    log.info(f"  Ingesting shapes…")
    rows = []
    for r in iter_gtfs_rows(zip_bytes, "shapes.txt"):
        try:
            lat = float(r["shape_pt_lat"])
            lon = float(r["shape_pt_lon"])
            seq = int(r["shape_pt_sequence"])
        except (ValueError, KeyError):
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            continue
        rows.append((pid(r["shape_id"]), lat, lon, seq))
        if len(rows) >= 10_000:
            cur.executemany("INSERT OR IGNORE INTO shapes VALUES (?,?,?,?)", rows)
            rows = []
    if rows:
        cur.executemany("INSERT OR IGNORE INTO shapes VALUES (?,?,?,?)", rows)


def build_sqlite(provider_zips: dict[str, bytes], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()

    con = sqlite3.connect(out_path)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.executescript(SCHEMA)

    for provider in PROVIDERS:
        if provider.name not in provider_zips:
            log.warning(f"Skipping {provider.name} — download failed")
            continue
        log.info(f"Ingesting {provider.name}…")
        cur = con.cursor()
        ingest_provider(cur, provider, provider_zips[provider.name])
        con.commit()

    log.info("Running VACUUM…")
    con.execute("VACUUM")
    con.close()

    size_mb = out_path.stat().st_size / 1024 / 1024
    log.info(f"SQLite written: {out_path} ({size_mb:.1f} MB)")


# ---------------------------------------------------------------------------
# SHA-256 + manifest
# ---------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def write_manifest(sqlite_path: Path, manifest_path: Path, version: str, public_url: str) -> None:
    digest = sha256_file(sqlite_path)
    manifest = {
        "version": version,
        "sha256": digest,
        "url": public_url,
        "size_bytes": sqlite_path.stat().st_size,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2))
    log.info(f"Manifest written: {manifest_path}")
    log.info(f"  version={version}  sha256={digest[:16]}…")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="Cybus GTFS pipeline")
    ap.add_argument("--out-dir", default="dist", help="Output directory")
    ap.add_argument("--version", default=None, help="Version string (default: today's date)")
    ap.add_argument(
        "--public-url",
        default="https://YOUR_STATIC_HOST/cybus/gtfs.sqlite",
        help="Public URL the app will download the SQLite from"
    )
    ap.add_argument(
        "--fail-fast", action="store_true",
        help="Abort on the first provider download failure instead of continuing"
    )
    args = ap.parse_args()

    import datetime
    version = args.version or datetime.date.today().strftime("%Y%m%d")
    out_dir = Path(args.out_dir)

    # Download all providers (continue on error unless --fail-fast)
    provider_zips: dict[str, bytes] = {}
    failed: list[str] = []
    for provider in PROVIDERS:
        try:
            provider_zips[provider.name] = download_provider(provider)
        except Exception as exc:
            log.error(f"{provider.name} download failed: {exc}")
            failed.append(provider.name)
            if args.fail_fast:
                raise

    if not provider_zips:
        raise RuntimeError("All provider downloads failed — aborting")

    if failed:
        log.warning(f"Proceeding without: {', '.join(failed)}")

    sqlite_path = out_dir / "gtfs.sqlite"
    manifest_path = out_dir / "manifest.json"

    build_sqlite(provider_zips, sqlite_path)
    write_manifest(sqlite_path, manifest_path, version, args.public_url)

    log.info("Done.")


if __name__ == "__main__":
    main()
