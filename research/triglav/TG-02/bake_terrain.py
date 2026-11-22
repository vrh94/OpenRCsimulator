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
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import region as regions  # noqa: E402

R = regions.select()
CACHE = R["cache"]
GKOT_RASTER = CACHE / "gkot_raster"
SOURCES = R["sources"]
OUT = R["landscape"] / "terrain"

CORE_E0, CORE_N0 = R["core_e_km"] * 1000, R["core_n_km"] * 1000  # D96/TM metres, the core's south-west corner
CORE_KM = R["core_km"]
CORE_STEP = 2.0
RING_STEP = R["ring_step_m"]
RING_SIZE_M = R["ring_size_m"]
# Storage: uint16 steps above a base (region.py): Triglav 1/32 m above 600 m for both grids.
BASE_M, STEP_M = R["core_base_m"], R["core_step_m"]
RING_BASE_M, RING_STEP_M = R["ring_base_m"], R["ring_step_m_height"]
FORMAT = "openrc-heightfield v1"

from d96 import d96_to_wgs84  # noqa: E402


def load_srtm():
    """The region's skadi tiles as one grid, rows north to south from srtm_north_deg, one column of tiles
    (tiles that share a longitude, stacked by latitude; their shared edge row is kept once). `size` is the samples per
    degree plus one, as for a single tile."""
    tiles = []
    for name in R["srtm_tiles"]:
        raw = gzip.decompress((CACHE / f"srtm/{name}.hgt.gz").read_bytes())
        size = int(round(math.sqrt(len(raw) / 2)))
        grid = np.frombuffer(raw, dtype=">i2").reshape(size, size).astype(np.float64)  # rows north to south
        tiles.append((int(name[1:3]) * (1 if name[0] == "N" else -1), grid))
    tiles.sort(key=lambda item: -item[0])
    grid = tiles[0][1]
    for _, below in tiles[1:]:
        grid = np.vstack([grid[:-1], below])
    grid[grid < -1000] = np.nan
    return grid, size


def sample_srtm(grid, size, east, north):
    lat, lon = d96_to_wgs84(east, north)
    row = (R["srtm_north_deg"] - lat) * (size - 1)
    col = (lon - R["srtm_west_deg"]) * (size - 1)
    r0 = np.clip(np.floor(row).astype(int), 0, grid.shape[0] - 2)
    c0 = np.clip(np.floor(col).astype(int), 0, grid.shape[1] - 2)
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


def apply_ring_lidar(ring, ring_origin):
    """Replace the ring's SRTM under each `ring_lidar` region (region.py) by that region's GKOT ground averaged over
    each ring cell; the LiDAR - SRTM difference fades out over FADE_M around it, so no step appears."""
    fade_m = 1000.0
    info = {}
    for name in R.get("ring_lidar", []):
        area = regions.REGIONS[name]
        raster = area["cache"] / "gkot_raster"
        k, e_km, n_km = area["core_km"], area["core_e_km"], area["core_n_km"]
        side = k * 1000
        ground = np.full((side, side), np.nan, np.float32)   # 1 m, rows south to north
        sheets = 0
        for n in range(n_km, n_km + k):
            for e in range(e_km, e_km + k):
                path = raster / f"{e}_{n}.npz"
                if path.exists():
                    r0, c0 = (n - n_km) * 1000, (e - e_km) * 1000
                    ground[r0:r0 + 1000, c0:c0 + 1000] = np.load(path)["ground"][::-1]
                    sheets += 1
        if not sheets:
            continue
        cell = int(RING_STEP)
        blocks = ground.reshape(side // cell, cell, side // cell, cell)
        count = np.isfinite(blocks).sum(axis=(1, 3))
        with np.errstate(invalid="ignore", divide="ignore"):
            lidar = np.where(count > 0, np.nansum(blocks, axis=(1, 3)) / count, np.nan)
        first_e = int(round((e_km * 1000 - (ring_origin[0] - RING_STEP / 2)) / RING_STEP))
        first_n = int(round((n_km * 1000 - (ring_origin[1] - RING_STEP / 2)) / RING_STEP))
        rows, cols = lidar.shape
        patch_srtm = ring[first_n:first_n + rows, first_e:first_e + cols].copy()
        valid = np.isfinite(lidar) & (count >= cell * cell // 4)
        offset = np.zeros_like(ring)
        known = np.zeros(ring.shape, bool)
        offset[first_n:first_n + rows, first_e:first_e + cols] = np.where(valid, lidar - patch_srtm, 0.0)
        known[first_n:first_n + rows, first_e:first_e + cols] = valid
        offset = push_pull(offset, known)
        ii, jj = np.meshgrid(np.arange(ring.shape[0]), np.arange(ring.shape[1]), indexing="ij")
        dn = np.maximum(np.maximum(first_n - ii, ii - (first_n + rows - 1)), 0) * RING_STEP
        de = np.maximum(np.maximum(first_e - jj, jj - (first_e + cols - 1)), 0) * RING_STEP
        weight = np.clip(1.0 - np.hypot(dn, de) / fade_m, 0.0, 1.0)
        ring += offset * weight
        diff = (lidar - patch_srtm)[valid]
        info[name] = {"sheets": sheets, "cells": int(valid.sum()),
                      "lidar_minus_srtm_median_m": round(float(np.median(diff)), 3)}
    return info


def encode(grid: np.ndarray, base_m: float, step_m: float):
    q = np.clip(np.rint((grid - base_m) / step_m), 0, 65535).astype("<u2")
    clamped = int(np.count_nonzero((grid - base_m) / step_m > 65535.5) + np.count_nonzero(grid < base_m))
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", compresslevel=9, mtime=0) as handle:
        handle.write(q.tobytes())
    return buffer.getvalue(), q, clamped


def bake():
    pins = json.loads(SOURCES.read_text())
    srtm, srtm_size = load_srtm()
    core2, fill = bake_core(pins, srtm, srtm_size)
    ring, ring_origin, ring_core = bake_ring(core2, srtm, srtm_size)
    ring_lidar = apply_ring_lidar(ring, ring_origin)
    outputs = {}
    attribution = pins["attribution"]
    for name, grid, origin, step, extra, base_m, step_m in (
        ("core", core2, None, CORE_STEP, fill, BASE_M, STEP_M),
        ("ring", ring, ring_origin, RING_STEP, {"core_cells": dict(zip(["east_first", "north_first", "east_count", "north_count"], ring_core)),
                                                 **({"ring_lidar": ring_lidar} if ring_lidar else {})},
         RING_BASE_M, RING_STEP_M),
    ):
        if name == "core":
            origin = (CORE_E0 + CORE_STEP / 2, CORE_N0 + CORE_STEP / 2)
        payload, q, clamped = encode(grid, base_m, step_m)
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
            "base_m": base_m,
            "step_m": step_m,
            "min_m": round(float(base_m + q.min() * step_m), 3),
            "max_m": round(float(base_m + q.max() * step_m), 3),
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
