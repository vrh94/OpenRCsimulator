#!/usr/bin/env python3
"""KM-01/KM-02: the Kamnik landscape's ring photo, a 48 x 48 km colour image from Sentinel-2 cloudless 2016.

The 8 km core is coloured by the GKOT orthophoto (research/triglav/TG-02/bake_gkot.py); outside it the ring had only
the alpine colouring, which paints the Ljubljana basin's fields and towns as forest. This script gives the ring its
real colour so Kamnik, Domžale, Ljubljana, Rašica, Šmarna gora and the Kamnik Alps read as themselves from the air.

- fetch (default): the EOX WMTS tiles of layer `s2cloudless_3857` (the 2016 mosaic, CC BY 4.0) at zoom 13
  (about 13 m per pixel here) covering the ring plus a margin, into tmp/kamnik/s2cloudless/ (not committed), each
  pinned by size and SHA-256 in research/kamnik/sources.json (`s2cloudless`). Present files are not fetched again;
  changed upstream bytes fail without touching the pins.
- bake: resample the mosaic onto the ring's D96/TM grid (north up, PIXELS square over RING_SIZE_M, bilinear) and write
  app/landscapes/kamnik_duplica/photo/ring.jpg plus ring.json. `--check` rebakes in memory and compares bytes.

    tmp/triglav/venv/bin/python research/kamnik/KM-01/ring_photo.py fetch
    tmp/triglav/venv/bin/python research/kamnik/KM-01/ring_photo.py bake [--check]

Terms: "Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data
2016)", CC BY 4.0. Later EOX mosaics are CC BY-NC-SA and are not used.
"""
import argparse
import concurrent.futures
import hashlib
import io
import json
import math
import sys
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve()
REPO = HERE.parents[3]
sys.path.insert(0, str(REPO / "research/triglav"))
import region as regions  # noqa: E402
from d96 import d96_to_wgs84  # noqa: E402

R = regions.REGIONS["kamnik"]
CACHE = R["cache"] / "s2cloudless"
SOURCES = R["sources"]
OUT = R["landscape"] / "photo"
LAYER = "s2cloudless_3857"
URL = "https://tiles.maps.eox.at/wmts/1.0.0/" + LAYER + "/default/g/{z}/{y}/{x}.jpg"
ZOOM = 13
TILE = 256
PIXELS = 3600            # 13.3 m per pixel over 48 km, the zoom's native size here
JPEG_QUALITY = 88
USER_AGENT = "OpenRCsimulator-terrain/1 (ring photo; https://github.com/vrh94/OpenRCsimulator)"
CREDIT = ("Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel "
          "data 2016), CC BY 4.0")


def ring_bounds():
    centre_e = R["core_e_km"] * 1000 + R["core_km"] * 500.0
    centre_n = R["core_n_km"] * 1000 + R["core_km"] * 500.0
    half = R["ring_size_m"] / 2.0
    return centre_e - half, centre_n - half, R["ring_size_m"]


def tile_xy(lat, lon):
    n = 2 ** ZOOM
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - np.arcsinh(np.tan(np.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def tiles():
    e0, n0, size = ring_bounds()
    margin = 1500.0
    e = np.linspace(e0 - margin, e0 + size + margin, 40)
    n = np.linspace(n0 - margin, n0 + size + margin, 40)
    ee, nn = np.meshgrid(e, n)
    lat, lon = d96_to_wgs84(ee, nn)
    x, y = tile_xy(lat, lon)
    return [(int(tx), int(ty)) for ty in range(int(y.min()), int(y.max()) + 1)
            for tx in range(int(x.min()), int(x.max()) + 1)]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch_one(xy):
    x, y = xy
    path = CACHE / f"{ZOOM}_{x}_{y}.jpg"
    if not path.exists():
        request = urllib.request.Request(URL.format(z=ZOOM, x=x, y=y), headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
        part = path.with_suffix(".part")
        part.write_bytes(data)
        part.rename(path)
    data = path.read_bytes()
    return {"name": path.name, "url": URL.format(z=ZOOM, x=x, y=y), "bytes": len(data), "sha256": sha256(data)}


def fetch() -> int:
    CACHE.mkdir(parents=True, exist_ok=True)
    wanted = tiles()
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        got = list(pool.map(fetch_one, wanted))
    pins = json.loads(SOURCES.read_text())
    old = {item["name"]: item for item in pins.get("s2cloudless", [])}
    changed = [item["name"] for item in got if item["name"] in old and old[item["name"]]["sha256"] != item["sha256"]]
    if changed:
        print(f"FAIL: upstream bytes changed for {changed[:5]}; the pins were not updated", file=sys.stderr)
        return 1
    pins["s2cloudless"] = got
    if CREDIT not in pins["attribution"]:
        pins["attribution"].append(CREDIT)
    SOURCES.write_text(json.dumps(pins, indent=1) + "\n")
    print(f"ok: {len(got)} Sentinel-2 cloudless tiles cached and pinned in {SOURCES.relative_to(REPO)}")
    return 0


def mosaic():
    pins = json.loads(SOURCES.read_text())["s2cloudless"]
    xs = sorted({int(item["name"].split("_")[1]) for item in pins})
    ys = sorted({int(item["name"].split("_")[2].split(".")[0]) for item in pins})
    image = np.zeros(((ys[-1] - ys[0] + 1) * TILE, (xs[-1] - xs[0] + 1) * TILE, 3), dtype=np.float64)
    for item in pins:
        data = (CACHE / item["name"]).read_bytes()
        if sha256(data) != item["sha256"]:
            raise SystemExit(f"FAIL: cached {item['name']} differs from its pin")
        x = int(item["name"].split("_")[1]) - xs[0]
        y = int(item["name"].split("_")[2].split(".")[0]) - ys[0]
        image[y * TILE:(y + 1) * TILE, x * TILE:(x + 1) * TILE] = np.asarray(Image.open(io.BytesIO(data)).convert("RGB"))
    return image, xs[0], ys[0]


def bake():
    image, x0, y0 = mosaic()
    e0, n0, size = ring_bounds()
    step = size / PIXELS
    # Pixel (row, column) centre: row 0 is the north edge.
    east = e0 + step * (np.arange(PIXELS) + 0.5)
    north = n0 + size - step * (np.arange(PIXELS) + 0.5)
    out = np.zeros((PIXELS, PIXELS, 3), dtype=np.uint8)
    for r0 in range(0, PIXELS, 400):
        ee, nn = np.meshgrid(east, north[r0:r0 + 400])
        lat, lon = d96_to_wgs84(ee, nn)
        tx, ty = tile_xy(lat, lon)
        px = (tx - x0) * TILE - 0.5
        py = (ty - y0) * TILE - 0.5
        c0 = np.clip(np.floor(px).astype(int), 0, image.shape[1] - 2)
        q0 = np.clip(np.floor(py).astype(int), 0, image.shape[0] - 2)
        fx = np.clip(px - c0, 0, 1)[..., None]
        fy = np.clip(py - q0, 0, 1)[..., None]
        value = ((image[q0, c0] * (1 - fx) + image[q0, c0 + 1] * fx) * (1 - fy)
                 + (image[q0 + 1, c0] * (1 - fx) + image[q0 + 1, c0 + 1] * fx) * fy)
        out[r0:r0 + 400] = np.clip(np.rint(value), 0, 255).astype(np.uint8)
    buffer = io.BytesIO()
    Image.fromarray(out).save(buffer, "JPEG", quality=JPEG_QUALITY, optimize=True)
    payload = buffer.getvalue()
    header = {
        "format": "openrc-ring-photo v1",
        "crs": "D96/TM (EPSG:3794); grid north; row 0 is the north edge",
        "origin_east_m": e0,
        "origin_north_m": n0,
        "size_m": size,
        "pixels": PIXELS,
        "data": "ring.jpg",
        "data_sha256": sha256(payload),
        "source": CREDIT,
        "layer": f"{LAYER} zoom {ZOOM}",
        "generator": "research/kamnik/KM-01/ring_photo.py",
    }
    return {"ring.jpg": payload, "ring.json": (json.dumps(header, indent=1) + "\n").encode()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("action", choices=["fetch", "bake"], nargs="?", default="fetch")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.action == "fetch":
        return fetch()
    outputs = bake()
    if args.check:
        stale = [name for name, data in outputs.items() if not (OUT / name).exists() or (OUT / name).read_bytes() != data]
        print(f"{'FAIL' if stale else 'ok'}: {len(outputs) - len(stale)}/{len(outputs)} ring photo files current {stale}")
        return 1 if stale else 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in outputs.items():
        (OUT / name).write_bytes(data)
        print(f"wrote {(OUT / name).relative_to(REPO)} ({len(data) / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
