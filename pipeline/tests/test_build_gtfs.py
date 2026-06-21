"""
Pipeline unit tests.

All tests are network-free: fixture zips are built in memory and requests.get
is patched where download_provider is exercised.
"""

import hashlib
import io
import json
import sqlite3
import sys
import zipfile
import zlib
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from build_gtfs import (
    Provider,
    build_sqlite,
    compress_sqlite,
    download_provider,
    ingest_provider,
    iter_gtfs_rows,
    sha256_file,
    write_manifest,
)

# ---------------------------------------------------------------------------
# Fixture zip helpers
# ---------------------------------------------------------------------------

def make_zip(files: dict[str, str]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, content in files.items():
            zf.writestr(name, content)
    return buf.getvalue()


STOPS_CSV = (
    "stop_id,stop_name,stop_lat,stop_lon\n"
    "S1,Limassol Central,34.6786,33.0412\n"
    "S2,Zero Island,0.0,0.0\n"           # (0,0) should be dropped
    "S3,Off Earth,200.0,400.0\n"          # out of range — dropped
)

ROUTES_CSV = (
    "route_id,route_short_name,route_color,route_text_color\n"
    "R1,30,FF0000,FFFFFF\n"
)

TRIPS_CSV = (
    "trip_id,route_id,service_id,trip_headsign,shape_id\n"
    "T1,R1,SVC1,Downtown,SH1\n"
)

CALENDAR_CSV = (
    "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,"
    "start_date,end_date\n"
    "SVC1,1,1,1,1,1,0,0,20260101,20261231\n"
)

CALENDAR_DATES_CSV = (
    "service_id,date,exception_type\n"
    "SVC1,20260101,2\n"
)

STOP_TIMES_CSV = (
    "trip_id,stop_id,arrival_time,departure_time,stop_sequence\n"
    "T1,S1,08:00:00,08:00:00,1\n"
)

SHAPES_CSV = (
    "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\n"
    "SH1,34.6786,33.0412,1\n"
    "SH1,34.6800,33.0430,2\n"
)

MINIMAL_ZIP = make_zip(
    {
        "stops.txt": STOPS_CSV,
        "routes.txt": ROUTES_CSV,
        "trips.txt": TRIPS_CSV,
        "calendar.txt": CALENDAR_CSV,
        "calendar_dates.txt": CALENDAR_DATES_CSV,
        "stop_times.txt": STOP_TIMES_CSV,
        "shapes.txt": SHAPES_CSV,
    }
)

# ---------------------------------------------------------------------------
# download_provider
# ---------------------------------------------------------------------------

def _mock_response(data: bytes, status: int = 200) -> MagicMock:
    resp = MagicMock()
    resp.raise_for_status = MagicMock()
    resp.iter_content = MagicMock(return_value=[data])
    if status != 200:
        resp.raise_for_status.side_effect = Exception(f"HTTP {status}")
    return resp


class TestDownloadProvider:
    def test_rejects_html_response(self):
        """Magic-byte check must reject an HTML error page returned as 200."""
        html = b"<html><body>Error</body></html>"
        with patch("build_gtfs.requests.get", return_value=_mock_response(html)):
            with pytest.raises(ValueError, match="not a zip archive"):
                download_provider(Provider("Test", 1))

    def test_rejects_oversized_payload(self):
        """Size guard must fire before magic-byte check for very large payloads."""
        # Stream chunks totalling > 50 MB
        chunk = b"X" * (1024 * 1024)  # 1 MB
        resp = MagicMock()
        resp.raise_for_status = MagicMock()
        resp.iter_content = MagicMock(return_value=[chunk] * 51)
        with patch("build_gtfs.requests.get", return_value=resp):
            with pytest.raises(ValueError, match="zip bomb guard"):
                download_provider(Provider("Test", 1))

    def test_accepts_valid_zip(self):
        """Valid zip must be returned as bytes without error."""
        with patch("build_gtfs.requests.get", return_value=_mock_response(MINIMAL_ZIP)):
            data = download_provider(Provider("Test", 1))
        assert data[:4] == b"PK\x03\x04"

    def test_provider_url_contains_rel_param(self):
        """The &rel=True param is required; the server returns HTML without it."""
        p = Provider("EMEL", 6)
        assert "&rel=True" in p.url

# ---------------------------------------------------------------------------
# iter_gtfs_rows
# ---------------------------------------------------------------------------

class TestIterGtfsRows:
    def test_zip_slip_rejected(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr("../evil.txt", "bad")
        with pytest.raises(ValueError, match="Zip-slip"):
            list(iter_gtfs_rows(buf.getvalue(), "../evil.txt"))

    def test_absolute_path_rejected(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr("/etc/passwd", "bad")
        with pytest.raises(ValueError, match="Zip-slip"):
            list(iter_gtfs_rows(buf.getvalue(), "/etc/passwd"))

    def test_missing_file_yields_nothing(self):
        rows = list(iter_gtfs_rows(MINIMAL_ZIP, "nonexistent.txt"))
        assert rows == []

    def test_yields_dicts_with_stripped_keys(self):
        rows = list(iter_gtfs_rows(MINIMAL_ZIP, "stops.txt"))
        assert any(r["stop_id"] == "S1" for r in rows)

# ---------------------------------------------------------------------------
# ingest_provider + build_sqlite
# ---------------------------------------------------------------------------

class TestIngestProvider:
    def _open_memory_db(self):
        from build_gtfs import SCHEMA
        con = sqlite3.connect(":memory:")
        con.executescript(SCHEMA)
        return con

    def test_valid_stop_ingested(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), MINIMAL_ZIP)
        con.commit()
        row = con.execute("SELECT * FROM stops WHERE stop_id = 'EMEL:S1'").fetchone()
        assert row is not None
        assert row[1] == "Limassol Central"

    def test_zero_zero_coordinate_dropped(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), MINIMAL_ZIP)
        con.commit()
        row = con.execute("SELECT * FROM stops WHERE stop_id = 'EMEL:S2'").fetchone()
        assert row is None

    def test_out_of_range_coordinate_dropped(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), MINIMAL_ZIP)
        con.commit()
        row = con.execute("SELECT * FROM stops WHERE stop_id = 'EMEL:S3'").fetchone()
        assert row is None

    def test_ids_namespaced_with_provider_prefix(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("NPT", 9), MINIMAL_ZIP)
        con.commit()
        # All IDs should be prefixed with "NPT:"
        stops = con.execute("SELECT stop_id FROM stops").fetchall()
        assert all(sid[0].startswith("NPT:") for sid in stops)
        trips = con.execute("SELECT trip_id FROM trips").fetchall()
        assert all(tid[0].startswith("NPT:") for tid in trips)

    def test_route_ingested(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), MINIMAL_ZIP)
        con.commit()
        row = con.execute("SELECT route_short_name FROM routes WHERE route_id = 'EMEL:R1'").fetchone()
        assert row is not None
        assert row[0] == "30"

    def test_trip_links_to_route(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), MINIMAL_ZIP)
        con.commit()
        row = con.execute("SELECT route_id FROM trips WHERE trip_id = 'EMEL:T1'").fetchone()
        assert row is not None
        assert row[0] == "EMEL:R1"

    def test_calendar_ingested(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), MINIMAL_ZIP)
        con.commit()
        row = con.execute("SELECT monday FROM calendar WHERE service_id = 'EMEL:SVC1'").fetchone()
        assert row is not None
        assert row[0] == 1

    def test_calendar_dates_ingested(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), MINIMAL_ZIP)
        con.commit()
        row = con.execute(
            "SELECT exception_type FROM calendar_dates WHERE service_id = 'EMEL:SVC1'"
        ).fetchone()
        assert row is not None
        assert row[0] == 2

    def test_stop_times_ingested(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), MINIMAL_ZIP)
        con.commit()
        row = con.execute(
            "SELECT stop_id FROM stop_times WHERE trip_id = 'EMEL:T1'"
        ).fetchone()
        assert row is not None
        assert row[0] == "EMEL:S1"

    def test_shapes_ingested(self):
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), MINIMAL_ZIP)
        con.commit()
        count = con.execute(
            "SELECT COUNT(*) FROM shapes WHERE shape_id = 'EMEL:SH1'"
        ).fetchone()[0]
        assert count == 2

    def test_optional_file_absent_does_not_crash(self):
        """A zip without shapes.txt (optional) must still ingest successfully."""
        zip_without_shapes = make_zip(
            {
                "stops.txt": STOPS_CSV,
                "routes.txt": ROUTES_CSV,
                "trips.txt": TRIPS_CSV,
                "calendar.txt": CALENDAR_CSV,
                "stop_times.txt": STOP_TIMES_CSV,
            }
        )
        con = self._open_memory_db()
        ingest_provider(con.cursor(), Provider("EMEL", 6), zip_without_shapes)
        con.commit()
        count = con.execute("SELECT COUNT(*) FROM stops").fetchone()[0]
        assert count >= 1


class TestBuildSqlite:
    def test_schema_tables_exist(self, tmp_path):
        out = tmp_path / "gtfs.sqlite"
        build_sqlite({"EMEL": MINIMAL_ZIP}, out)
        con = sqlite3.connect(out)
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert {"stops", "routes", "trips", "calendar", "stop_times", "shapes"} <= tables

    def test_two_providers_have_separate_namespaces(self, tmp_path):
        out = tmp_path / "gtfs.sqlite"
        build_sqlite({"EMEL": MINIMAL_ZIP, "NPT": MINIMAL_ZIP}, out)
        con = sqlite3.connect(out)
        stop_ids = {r[0] for r in con.execute("SELECT stop_id FROM stops")}
        assert any(s.startswith("EMEL:") for s in stop_ids)
        assert any(s.startswith("NPT:") for s in stop_ids)

    def test_missing_provider_skipped_gracefully(self, tmp_path):
        """build_sqlite must succeed when only a subset of providers have data."""
        out = tmp_path / "gtfs.sqlite"
        build_sqlite({"EMEL": MINIMAL_ZIP}, out)  # only EMEL
        con = sqlite3.connect(out)
        count = con.execute("SELECT COUNT(*) FROM stops").fetchone()[0]
        assert count >= 1


# ---------------------------------------------------------------------------
# sha256_file + write_manifest
# ---------------------------------------------------------------------------

class TestManifest:
    def test_sha256_matches_manual_hash(self, tmp_path):
        f = tmp_path / "data.bin"
        f.write_bytes(b"hello world")
        expected = hashlib.sha256(b"hello world").hexdigest()
        assert sha256_file(f) == expected

    def test_manifest_fields(self, tmp_path):
        sqlite_path = tmp_path / "gtfs.sqlite"
        sqlite_path.write_bytes(b"fake sqlite content")
        manifest_path = tmp_path / "manifest.json"
        write_manifest(sqlite_path, manifest_path, "20260621", "https://example.com/gtfs.sqlite.zz")

        manifest = json.loads(manifest_path.read_text())
        assert manifest["version"] == "20260621"
        assert manifest["compression"] == "zlib"
        assert manifest["url"] == "https://example.com/gtfs.sqlite.zz"
        assert manifest["sha256"] == hashlib.sha256(b"fake sqlite content").hexdigest()
        assert manifest["size_bytes"] == len(b"fake sqlite content")

    def test_manifest_sha256_matches_file(self, tmp_path):
        content = b"some gtfs data"
        sqlite_path = tmp_path / "gtfs.sqlite"
        sqlite_path.write_bytes(content)
        manifest_path = tmp_path / "manifest.json"
        write_manifest(sqlite_path, manifest_path, "20260621", "https://x.com/f.zz")

        manifest = json.loads(manifest_path.read_text())
        assert manifest["sha256"] == hashlib.sha256(content).hexdigest()


# ---------------------------------------------------------------------------
# compress_sqlite
# ---------------------------------------------------------------------------

class TestCompressSqlite:
    def test_compressed_output_is_smaller(self, tmp_path):
        # Use repetitive data so compression is effective
        data = b"GTFS data " * 10_000
        src = tmp_path / "gtfs.sqlite"
        dst = tmp_path / "gtfs.sqlite.zz"
        src.write_bytes(data)
        compress_sqlite(src, dst)
        assert dst.stat().st_size < src.stat().st_size

    def test_roundtrip_decompresses_to_original(self, tmp_path):
        data = b"SQLite header\x00" * 500
        src = tmp_path / "gtfs.sqlite"
        dst = tmp_path / "gtfs.sqlite.zz"
        src.write_bytes(data)
        compress_sqlite(src, dst)
        decompressed = zlib.decompress(dst.read_bytes())
        assert decompressed == data
