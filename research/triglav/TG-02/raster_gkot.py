#!/usr/bin/env python3
"""TG-02b, stage 1: rasterise the GURS CLSS GKOT point clouds of the Triglav core, one 1 km sheet at a time.

GKOT is the classified LiDAR point cloud of the 2023-25 cyclic laser scan (LAS 1.4, point format 8: colour and
near-infrared per point, ASPRS classes). For each sheet `tmp/triglav/gkot/GKOT_<E>_<N>.laz` this writes
`tmp/triglav/gkot_raster/<E>_<N>.npz` (a cache, not committed) with:

- `rgb`      2000 x 2000 x 3 uint8, 0.5 m: the colour of the highest point in each cell, which is a true orthophoto
             (tree crowns and roofs where they are, no lean). Black where no coloured point fell (outside Slovenia,
             where the points carry pure white or black).
- `ground`   1000 x 1000 float32, 1 m: mean height of class 2 (ground) points; NaN where none.
- `veg_top`  1000 x 1000 float32, 1 m: highest class 3-5 (vegetation) point; NaN where none.
- `bld_top`  1000 x 1000 float32, 1 m: highest class 6 (building) point; NaN where none.

Rows run north to south (image order), columns west to east; cell (r, c) covers
E = E km * 1000 + c * res .. + res, N = (N km + 1) * 1000 - r * res .. - res. Noise (classes 7 and 18) and withheld
points are ignored.

    tmp/triglav/venv/bin/python research/triglav/TG-02/raster_gkot.py [sheet ...]   # default: every sheet present

Needs laspy with the lazrs backend, numpy (python3 -m venv tmp/triglav/venv; pip install "laspy[lazrs]" numpy).
"""
import sys
import time
from pathlib import Path

import laspy
import numpy as np

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / "tmp/triglav/gkot"
OUT = REPO / "tmp/triglav/gkot_raster"
NOISE = (7, 18)
VEGETATION = (3, 4, 5)
BUILDING = (6,)
GROUND = (2,)


def top_per_cell(cells: np.ndarray, z: np.ndarray, size: int) -> np.ndarray:
    """Index of the highest point in each cell (-1 where empty)."""
    order = np.lexsort((z, cells))            # by cell, then by height
    last = np.r_[cells[order][1:] != cells[order][:-1], True]
    top = np.full(size, -1, np.int64)
    top[cells[order][last]] = order[last]
    return top


def max_per_cell(cells, z, size):
    out = np.full(size, np.nan, np.float32)
    if len(z):
        top = top_per_cell(cells, z, size)
        hit = top >= 0
        out[hit] = z[top[hit]]
    return out


def rasterise(path: Path, e_km: int, n_km: int) -> dict:
    las = laspy.read(path)
    cls = np.asarray(las.classification)
    keep = ~np.isin(cls, NOISE) & ~np.asarray(las.withheld, bool)
    x = np.asarray(las.x)[keep] - e_km * 1000.0
    y = (n_km + 1) * 1000.0 - np.asarray(las.y)[keep]   # metres south of the sheet's north edge
    z = np.asarray(las.z, dtype=np.float64)[keep]
    cls = cls[keep]
    inside = (x >= 0) & (x < 1000) & (y >= 0) & (y < 1000)
    x, y, z, cls = x[inside], y[inside], z[inside], cls[inside]
    rgb_src = np.stack([np.asarray(c)[keep][inside] for c in (las.red, las.green, las.blue)], 1)
    rgb_src = (rgb_src >> 8).astype(np.uint8)           # 16-bit colour, the low byte is zero
    # Points outside the orthophoto's coverage (Italy) carry pure white or black; treat both as "no colour". A
    # saturated real pixel becomes a hole too, and the assembly fills holes from the neighbours.
    coloured = rgb_src.any(axis=1) & ~(rgb_src == 255).all(axis=1)

    out = {}
    n = 2000
    cells = (y[coloured] * 2).astype(np.int64) * n + (x[coloured] * 2).astype(np.int64)
    top = top_per_cell(cells, z[coloured], n * n)
    rgb = np.zeros((n * n, 3), np.uint8)
    hit = top >= 0
    rgb[hit] = rgb_src[coloured][top[hit]]
    out["rgb"] = rgb.reshape(n, n, 3)

    n = 1000
    cells = y.astype(np.int64) * n + x.astype(np.int64)
    g = np.isin(cls, GROUND)
    total = np.bincount(cells[g], weights=z[g], minlength=n * n)
    count = np.bincount(cells[g], minlength=n * n)
    with np.errstate(invalid="ignore", divide="ignore"):
        out["ground"] = np.where(count > 0, total / count, np.nan).astype(np.float32).reshape(n, n)
    v = np.isin(cls, VEGETATION)
    out["veg_top"] = max_per_cell(cells[v], z[v], n * n).reshape(n, n)
    b = np.isin(cls, BUILDING)
    out["bld_top"] = max_per_cell(cells[b], z[b], n * n).reshape(n, n)
    out["points"] = np.int64(len(z))
    return out


def main(argv) -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    names = argv or sorted(p.stem.removeprefix("GKOT_") for p in SRC.glob("GKOT_*.laz"))
    for key in names:
        e_km, n_km = (int(v) for v in key.split("_"))
        target = OUT / f"{key}.npz"
        if target.exists():
            continue
        t0 = time.time()
        data = rasterise(SRC / f"GKOT_{key}.laz", e_km, n_km)
        part = target.with_suffix(".tmp.npz")
        np.savez_compressed(part, **data)
        part.rename(target)
        cover = float((data["rgb"].any(axis=2)).mean())
        print(f"{key}: {int(data['points'])} points, colour cover {cover:.1%}, "
              f"ground cover {float(np.isfinite(data['ground']).mean()):.1%}, {time.time() - t0:.0f} s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
