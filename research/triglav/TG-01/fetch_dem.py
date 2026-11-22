#!/usr/bin/env python3
"""TG-01: fetch and pin the elevation sources for the Triglav (Planica/Tamar) landscape.

Sources (docs/plans/triglav-planica-tamar.md):
- ARSO LiDAR DMR1, the 1 m bare-earth terrain model, 1 km tiles in D96/TM (EPSG:3794), ASCII rows "E;N;H".
  Credit: Ministry of the Environment and Spatial Planning, Slovenian Environment Agency (ARSO).
- SRTM 1 arc-second via Mapzen Terrain Tiles (skadi), for the far ring and the tiles outside Slovenia.
  Credit: SRTM data courtesy of the U.S. Geological Survey; Mapzen Terrain Tiles.

Raw files go to a cache outside app/ (default tmp/triglav/, ignored by git). research/triglav/sources.json pins each
file's size and SHA-256. A first fetch records them; later fetches refuse changed upstream bytes.

    python3 research/triglav/TG-01/fetch_dem.py            # fetch what is missing, verify everything
    python3 research/triglav/TG-01/fetch_dem.py --check    # verify the cache against the pins, no network
    python3 research/triglav/TG-01/fetch_dem.py --record   # (re)record pins for files fetched for the first time

Python standard library only.
"""
import argparse
import concurrent.futures
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import region as regions  # noqa: E402

R = regions.select()
SOURCES = R["sources"]
DEFAULT_CACHE = R["cache"]

# The playable core (region.py): 8 x 8 km of D96/TM kilometre tiles.
CORE_E = range(R["core_e_km"], R["core_e_km"] + R["core_km"])
CORE_N = range(R["core_n_km"], R["core_n_km"] + R["core_km"])
# ARSO serves the tiles in survey blocks (region.py lists the ones found by probing).
ARSO_URL = "https://gis.arso.gov.si/lidar/dmr1/b_{block}/D96TM/TM1_{e}_{n}.asc"
ARSO_BLOCKS = R["arso_blocks"]
SRTM_TILES = R["srtm_tiles"]
USER_AGENT = "OpenRCsimulator-TG01/1 (terrain fetch; https://github.com/vrh94/OpenRCsimulator)"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def get(url: str, method: str = "GET", timeout: float = 120.0):
    request = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(request, timeout=timeout)


def arso_entries(pins: dict) -> list:
    """Every core tile: its pinned block if known, otherwise discovered by HEAD requests. Tiles outside Slovenia
    (no block serves them) are recorded as absent."""
    entries = []
    known = {item["name"]: item for item in pins.get("arso_dmr1", [])}
    for n in CORE_N:
        for e in CORE_E:
            name = f"TM1_{e}_{n}.asc"
            if name in known:
                entries.append(known[name])
                continue
            found = None
            for block in ARSO_BLOCKS:
                url = ARSO_URL.format(block=block, e=e, n=n)
                try:
                    with get(url, "HEAD", 30.0):
                        found = {"name": name, "url": url}
                        break
                except Exception:
                    continue
            entries.append(found or {"name": name, "absent": "no ARSO block serves this tile (outside Slovenia)"})
    return entries


def fetch(entry: dict, cache: Path) -> dict:
    target = cache / entry["name"]
    if not target.exists():
        part = target.with_suffix(target.suffix + ".part")
        with get(entry["url"]) as response, part.open("wb") as handle:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                handle.write(chunk)
        part.rename(target)
    return {**entry, "bytes": target.stat().st_size, "sha256": sha256(target)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--check", action="store_true", help="verify the cache against the pins without network")
    parser.add_argument("--record", action="store_true", help="record pins for files that have none yet")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    pins = json.loads(SOURCES.read_text()) if SOURCES.exists() else {}
    arso_dir = args.cache / "arso_dmr1"
    srtm_dir = args.cache / "srtm"
    if args.check:
        failures = []
        for group, folder in (("arso_dmr1", arso_dir), ("srtm", srtm_dir)):
            for item in pins.get(group, []):
                if "absent" in item:
                    continue
                path = folder / item["name"]
                if not path.exists() or path.stat().st_size != item["bytes"] or sha256(path) != item["sha256"]:
                    failures.append(item["name"])
        print(f"{'FAIL' if failures else 'ok'}: {len(failures)} cached sources differ from the pins {failures[:5]}")
        return 1 if failures else 0
    arso_dir.mkdir(parents=True, exist_ok=True)
    srtm_dir.mkdir(parents=True, exist_ok=True)
    entries = arso_entries(pins)
    wanted = [item for item in entries if "absent" not in item]
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        fetched = {item["name"]: item for item in pool.map(lambda item: fetch(item, arso_dir), wanted)}
    srtm = [fetch({"name": name + ".hgt.gz", "url": url}, srtm_dir) for name, url in SRTM_TILES.items()]
    changed = []
    for group, items in (("arso_dmr1", list(fetched.values())), ("srtm", srtm)):
        old = {item["name"]: item for item in pins.get(group, [])}
        for item in items:
            pin = old.get(item["name"])
            if pin and "sha256" in pin and (pin["sha256"] != item["sha256"] or pin["bytes"] != item["bytes"]):
                changed.append(item["name"])
    if changed:
        print(f"FAIL: upstream bytes changed for {changed}; the pins were not updated", file=sys.stderr)
        return 1
    unpinned = any("sha256" not in item for item in pins.get("arso_dmr1", [])) or not pins
    if args.record or unpinned:
        record = {
            "format": "openrc-terrain-sources v1",
            "region": R["name"],
            "crs": "ARSO tiles: D96/TM (EPSG:3794), heights in metres; SRTM: WGS84 geographic, 1 arc-second",
            "core_d96tm_km": {"east": [CORE_E.start, CORE_E.stop - 1], "north": [CORE_N.start, CORE_N.stop - 1]},
            "attribution": [
                "Digital terrain model DMR1 (LiDAR, 1 m): Ministry of the Environment and Spatial Planning, "
                "Slovenian Environment Agency (ARSO)",
                "SRTM data courtesy of the U.S. Geological Survey; Mapzen Terrain Tiles",
            ],
            "licence_note": "ARSO: free to use, modify and reuse with the credit above (ARSO statement recorded by "
                            "opendem.info); confirm with ARSO before a public release. SRTM: public domain.",
            "arso_dmr1": [fetched.get(item["name"], item) for item in entries],
            "srtm": srtm,
        }
        SOURCES.parent.mkdir(parents=True, exist_ok=True)
        SOURCES.write_text(json.dumps(record, indent=1) + "\n")
        print(f"recorded {len(fetched)} ARSO tiles ({sum(1 for i in entries if 'absent' in i)} absent) and "
              f"{len(srtm)} SRTM tile(s) in {SOURCES.relative_to(REPO)}")
    else:
        print(f"ok: {len(fetched)} ARSO tiles and {len(srtm)} SRTM tile(s) match the pins")
    return 0


if __name__ == "__main__":
    sys.exit(main())
