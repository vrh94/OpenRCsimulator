#!/usr/bin/env python3
"""TG-02: bake the Triglav (Planica/Tamar) height grids from the TG-01 sources.

- core: 8 x 8 km, 4000 x 4000 nodes at 2 m. Node (i, j) sits at D96/TM E = CORE_E0 + 2 i + 0.5,
  N = CORE_N0 + 2 j + 0.5 (row j = 0 is the south edge). Each node is the mean of the ground points of the GURS CLSS
  2023-25 survey (GKOT class 2, rasterised by raster_gkot.py) in its 2 x 2 m cell. Cells without ground points
  (dense canopy) take the ARSO DMR1 2014-15 value (mean of 2 x 2 1 m samples) plus a smooth GKOT - ARSO offset field,
  so no step appears. Where neither survey has data (Italy), SRTM fills, shifted by the mean LiDAR - SRTM offset
  along the hole's edge. Without the GKOT cache the core is ARSO + SRTM alone.
- ring: 24 x 24 km around the core centre, 1500 x 1500 nodes at 16 m, from SRTM (bilinear, projected to D96/TM)
  outside the core and from the core inside it. Visual only.

Heights are stored as unsigned 16-bit steps of 1/32 m above BASE_M, little-endian, gzip (mtime 0, so the bytes are
reproducible), with a JSON header file per grid. `--check` rebakes in memory and compares the bytes.

    python3 research/triglav/TG-02/bake_terrain.py [--check]

Needs numpy and the TG-01 cache (python3 research/triglav/TG-01/fetch_dem.py).
"""
import argparse
import gzip
import hashlib
import io
import json
import math
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
CACHE = REPO / "tmp/triglav"
GKOT_RASTER = CACHE / "gkot_raster"
SOURCES = REPO / "research/triglav/sources.json"
OUT = REPO / "app/landscapes/triglav_tamar/terrain"

CORE_E0, CORE_N0 = 399000, 144000  # D96/TM metres, the core's south-west corner
CORE_KM = 8
CORE_STEP = 2.0
RING_STEP = 16.0
RING_SIZE_M = 24000.0
BASE_M = 600.0          # lowest storable height; the region's valleys are above 800 m
STEP_M = 1.0 / 32.0     # 3.1 cm; 65535 steps reach 2648 m: Jalovec is 2645 m, so the ring clamps nothing in the core
FORMAT = "openrc-heightfield v1"

# GRS80 transverse Mercator for D96/TM (EPSG:3794).
A = 6378137.0
F = 1.0 / 298.257222101
E2 = F * (2.0 - F)
EP2 = E2 / (1.0 - E2)
K0 = 0.9999
LON0 = math.radians(15.0)
FE, FN = 500000.0, -5000000.0


def d96_to_wgs84(east: np.ndarray, north: np.ndarray):
    """Inverse transverse Mercator (Snyder 1987, eqs. 8-12 to 8-25), arrays in metres to degrees."""
    x = (east - FE) / K0
    m = (north - FN) / K0
    mu = m / (A * (1 - E2 / 4 - 3 * E2 ** 2 / 64 - 5 * E2 ** 3 / 256))
    e1 = (1 - math.sqrt(1 - E2)) / (1 + math.sqrt(1 - E2))
    phi1 = (mu + (3 * e1 / 2 - 27 * e1 ** 3 / 32) * np.sin(2 * mu) + (21 * e1 ** 2 / 16 - 55 * e1 ** 4 / 32) * np.sin(4 * mu)
            + (151 * e1 ** 3 / 96) * np.sin(6 * mu) + (1097 * e1 ** 4 / 512) * np.sin(8 * mu))
    c1 = EP2 * np.cos(phi1) ** 2
    t1 = np.tan(phi1) ** 2
    n1 = A / np.sqrt(1 - E2 * np.sin(phi1) ** 2)
    r1 = A * (1 - E2) / (1 - E2 * np.sin(phi1) ** 2) ** 1.5
    d = x / n1
    lat = phi1 - (n1 * np.tan(phi1) / r1) * (d ** 2 / 2 - (5 + 3 * t1 + 10 * c1 - 4 * c1 ** 2 - 9 * EP2) * d ** 4 / 24
                                              + (61 + 90 * t1 + 298 * c1 + 45 * t1 ** 2 - 252 * EP2 - 3 * c1 ** 2) * d ** 6 / 720)
    lon = LON0 + (d - (1 + 2 * t1 + c1) * d ** 3 / 6 + (5 - 2 * c1 + 28 * t1 - 3 * c1 ** 2 + 8 * EP2 + 24 * t1 ** 2) * d ** 5 / 120) / np.cos(phi1)
    return np.degrees(lat), np.degrees(lon)


def load_srtm():
    raw = gzip.decompress((CACHE / "srtm/N46E013.hgt.gz").read_bytes())
    size = int(round(math.sqrt(len(raw) / 2)))
    grid = np.frombuffer(raw, dtype=">i2").reshape(size, size).astype(np.float64)  # rows north (47 N) to south
    grid[grid < -1000] = np.nan
    return grid, size


def sample_srtm(grid, size, east, north):
    lat, lon = d96_to_wgs84(east, north)
    row = (47.0 - lat) * (size - 1)
    col = (lon - 13.0) * (size - 1)
    r0 = np.clip(np.floor(row).astype(int), 0, size - 2)
    c0 = np.clip(np.floor(col).astype(int), 0, size - 2)
    fr = row - r0
    fc = col - c0
    return ((grid[r0, c0] * (1 - fc) + grid[r0, c0 + 1] * fc) * (1 - fr)
            + (grid[r0 + 1, c0] * (1 - fc) + grid[r0 + 1, c0 + 1] * fc) * fr)


def load_core_1m(pins: dict) -> np.ndarray:
    side = CORE_KM * 1000
    core = np.full((side, side), np.nan, dtype=np.float64)  # [north index, east index], south row first
    for item in pins["arso_dmr1"]:
        if "absent" in item:
            continue
        data = np.fromstring((CACHE / "arso_dmr1" / item["name"]).read_text().replace(";", " "), sep=" ")
        data = data.reshape(-1, 3)
        e = np.rint(data[:, 0] - CORE_E0).astype(int)
        n = np.rint(data[:, 1] - CORE_N0).astype(int)
        inside = (e >= 0) & (e < side) & (n >= 0) & (n < side)
        core[n[inside], e[inside]] = data[inside, 2]
    return core


def push_pull(values: np.ndarray, valid: np.ndarray) -> np.ndarray:
    """Smoothly fill a 2D field where `valid` is False from the valid values (push-pull pyramid)."""
    levels = [(np.where(valid, values, 0.0), valid.astype(np.float64))]
    while min(levels[-1][1].shape) > 1:
        v, w = levels[-1]
        h, wd = (w.shape[0] // 2) * 2, (w.shape[1] // 2) * 2
        levels.append((v[:h, :wd].reshape(h // 2, 2, wd // 2, 2).sum(axis=(1, 3)),
                       w[:h, :wd].reshape(h // 2, 2, wd // 2, 2).sum(axis=(1, 3))))
    field = levels[-1][0] / np.maximum(levels[-1][1], 1e-9)
    for v, w in reversed(levels[:-1]):
        up = np.repeat(np.repeat(field, 2, axis=0), 2, axis=1)
        full = np.pad(up, ((0, v.shape[0] - up.shape[0]), (0, v.shape[1] - up.shape[1])), mode="edge")
        field = np.where(w > 0, v / np.maximum(w, 1e-9), full)
    return field


def load_gkot_ground_2m():
    """GKOT ground at 2 m (rows south to north), NaN where a 2 x 2 m cell has no ground point; None without the cache."""
    side = CORE_KM * 500
    names = [f"{e}_{n}" for n in range(CORE_N0 // 1000, CORE_N0 // 1000 + CORE_KM)
             for e in range(CORE_E0 // 1000, CORE_E0 // 1000 + CORE_KM)]
    present = [name for name in names if (GKOT_RASTER / f"{name}.npz").exists()]
    if not present:
        return None, []
    total = np.zeros((side, side))
    count = np.zeros((side, side))
    for name in present:
        e, n = (int(v) for v in name.split("_"))
        g = np.load(GKOT_RASTER / f"{name}.npz")["ground"][::-1].astype(np.float64)   # south to north
        valid = np.isfinite(g)
        r0 = (n - CORE_N0 // 1000) * 500
        c0 = (e - CORE_E0 // 1000) * 500
        total[r0:r0 + 500, c0:c0 + 500] = np.where(valid, g, 0.0).reshape(500, 2, 500, 2).sum(axis=(1, 3))
        count[r0:r0 + 500, c0:c0 + 500] = valid.reshape(500, 2, 500, 2).sum(axis=(1, 3))
    with np.errstate(invalid="ignore", divide="ignore"):
        return np.where(count > 0, total / count, np.nan), present


def bake_core(pins: dict, srtm, srtm_size):
    core1 = load_core_1m(pins)
    side = CORE_KM * 1000
    holes = np.isnan(core1)
    filled = int(holes.sum())
    if filled:
        north, east = np.nonzero(holes)
        fill = sample_srtm(srtm, srtm_size, east + CORE_E0 + 0.0, north + CORE_N0 + 0.0)
        # Edge offset: LiDAR minus SRTM over LiDAR samples next to a hole.
        edge = np.zeros_like(holes)
        edge[1:, :] |= holes[:-1, :]
        edge[:-1, :] |= holes[1:, :]
        edge[:, 1:] |= holes[:, :-1]
        edge[:, :-1] |= holes[:, 1:]
        edge &= ~holes
        en, ee = np.nonzero(edge)
        offset = float(np.nanmean(core1[en, ee] - sample_srtm(srtm, srtm_size, ee + CORE_E0 + 0.0, en + CORE_N0 + 0.0)))
        core1[north, east] = fill + offset
    else:
        offset = 0.0
    arso2 = core1.reshape(side // 2, 2, side // 2, 2).mean(axis=(1, 3))
    info = {"filled_1m_samples": filled, "fill_offset_m": round(offset, 3)}
    gkot2, sheets = load_gkot_ground_2m()
    if gkot2 is None:
        return arso2, info
    # ARSO only where ARSO itself is LiDAR (not its SRTM fill) counts for the offset field.
    arso_lidar = ~holes.reshape(side // 2, 2, side // 2, 2).any(axis=(1, 3))
    have = np.isfinite(gkot2)
    both = have & arso_lidar
    offset_field = push_pull(gkot2 - arso2, both)
    core2 = np.where(have, gkot2, arso2 + offset_field)
    diff = (gkot2 - arso2)[both]
    info.update({"gkot_sheets": len(sheets), "gkot_ground_nodes": round(float(have.mean()), 4),
                 "gkot_minus_arso_median_m": round(float(np.median(diff)), 3),
                 "gkot_minus_arso_p05_p95_m": [round(float(v), 3) for v in np.percentile(diff, [5, 95])]})
    return core2, info


def bake_ring(core2, srtm, srtm_size):
    n = int(RING_SIZE_M / RING_STEP)
    centre_e = CORE_E0 + CORE_KM * 500.0
    centre_n = CORE_N0 + CORE_KM * 500.0
    e0 = centre_e - RING_SIZE_M / 2 + RING_STEP / 2
    n0 = centre_n - RING_SIZE_M / 2 + RING_STEP / 2
    ee, nn = np.meshgrid(e0 + RING_STEP * np.arange(n), n0 + RING_STEP * np.arange(n))
    ring = sample_srtm(srtm, srtm_size, ee, nn)
    # Inside the core: the 2 m core averaged over each 16 m cell.
    k = int(RING_STEP / CORE_STEP)
    block = core2.reshape(core2.shape[0] // k, k, core2.shape[1] // k, k).mean(axis=(1, 3))
    first_e = int(round((CORE_E0 - (e0 - RING_STEP / 2)) / RING_STEP))
    first_n = int(round((CORE_N0 - (n0 - RING_STEP / 2)) / RING_STEP))
    ring[first_n:first_n + block.shape[0], first_e:first_e + block.shape[1]] = block
    return ring, (e0, n0), (first_e, first_n, block.shape[1], block.shape[0])


def encode(grid: np.ndarray):
    q = np.clip(np.rint((grid - BASE_M) / STEP_M), 0, 65535).astype("<u2")
    clamped = int(np.count_nonzero((grid - BASE_M) / STEP_M > 65535.5) + np.count_nonzero(grid < BASE_M))
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", compresslevel=9, mtime=0) as handle:
        handle.write(q.tobytes())
    return buffer.getvalue(), q, clamped


def bake():
    pins = json.loads(SOURCES.read_text())
    srtm, srtm_size = load_srtm()
    core2, fill = bake_core(pins, srtm, srtm_size)
    ring, ring_origin, ring_core = bake_ring(core2, srtm, srtm_size)
    outputs = {}
    attribution = pins["attribution"]
    for name, grid, origin, step, extra in (
        ("core", core2, None, CORE_STEP, fill),
        ("ring", ring, ring_origin, RING_STEP, {"core_cells": dict(zip(["east_first", "north_first", "east_count", "north_count"], ring_core))}),
    ):
        if name == "core":
            origin = (CORE_E0 + CORE_STEP / 2, CORE_N0 + CORE_STEP / 2)
        payload, q, clamped = encode(grid)
        header = {
            "format": FORMAT,
            "name": name,
            "crs": "D96/TM (EPSG:3794); grid north; heights in metres above the Slovenian height datum (GKOT ground, ARSO DMR1 fill)",
            "columns": int(grid.shape[1]),
            "rows": int(grid.shape[0]),
            "origin_east_m": float(origin[0]),
            "origin_north_m": float(origin[1]),
            "spacing_m": step,
            "row_order": "south to north; column order west to east; node (0, 0) at the origin",
            "encoding": "gzip of little-endian uint16; height_m = base_m + value * step_m",
            "base_m": BASE_M,
            "step_m": STEP_M,
            "min_m": round(float(BASE_M + q.min() * STEP_M), 3),
            "max_m": round(float(BASE_M + q.max() * STEP_M), 3),
            "clamped_nodes": clamped,
            "data": f"{name}.u16.gz",
            "data_sha256": hashlib.sha256(payload).hexdigest(),
            "sources": attribution,
            "generator": "research/triglav/TG-02/bake_terrain.py",
            **extra,
        }
        outputs[f"{name}.json"] = (json.dumps(header, indent=1) + "\n").encode()
        outputs[f"{name}.u16.gz"] = payload
    return outputs, core2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs, core2 = bake()
    if args.check:
        stale = [name for name, data in outputs.items() if not (OUT / name).exists() or (OUT / name).read_bytes() != data]
        print(f"{'FAIL' if stale else 'ok'}: {len(outputs) - len(stale)}/{len(outputs)} terrain files current {stale}")
        return 1 if stale else 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in outputs.items():
        (OUT / name).write_bytes(data)
        print(f"wrote {OUT.relative_to(REPO) / name} ({len(data) / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
