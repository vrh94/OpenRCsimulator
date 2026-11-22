#!/usr/bin/env python3
"""TG-02b, stage 2: bake the landscape's photo, trees and buildings from the rasterised GKOT sheets.

Inputs: `tmp/triglav/gkot_raster/<E>_<N>.npz` (stage 1, raster_gkot.py) and the 2 m core height grid
(`app/landscapes/triglav_tamar/terrain/core.*`, TG-02) as the bare-earth reference.

Outputs in `app/landscapes/triglav_tamar/`:
- `photo/ortho.jpg`: 8192 x 8192 true orthophoto of the 8 x 8 km core (0.977 m per pixel), north up in grid north,
  holes (Italy, outside the survey's photo) filled smoothly from the surrounding colour.
- `photo/coverage.png`: 1024 x 1024 8-bit mask, 255 where the photo is real, 0 where it was filled.
- `vegetation/trees.bin.gz` + `trees.json`: one record per detected tree top, 10 bytes little-endian:
  uint16 east and uint16 north in 0.2 m units from the core's south-west corner (8000 m is 40000), uint16 ground
  height under the top (the terrain grid's encoding: 600 m + value / 32), uint8 height in 0.25 m, uint8 crown
  radius in 0.1 m, uint8 kind (0 conifer, 1 broadleaf), uint8 spare 0.
- `buildings/buildings.bin.gz` + `buildings.json`: each connected roof region (GKOT class 6) as a 1 m grid of
  roof heights, so the landscape can rebuild real footprints and roof shapes.

    tmp/triglav/venv/bin/python research/triglav/TG-02/bake_gkot.py [--check]

Needs numpy and Pillow in the same venv as stage 1.
"""
import argparse
import gzip
import hashlib
import io
import json
import sys
from pathlib import Path

import numpy as np
import PIL
from PIL import Image

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import region as regions  # noqa: E402

R = regions.select()
RASTER = R["cache"] / "gkot_raster"
TERRAIN = R["landscape"] / "terrain"
OUT = R["landscape"]
E_KM = range(R["core_e_km"], R["core_e_km"] + R["core_km"])
TREE_GROUND_BASE_M = R["core_base_m"]   # tree ground heights share the core grid's base (Triglav 600 m), in 1/32 m
N_KM = range(R["core_n_km"], R["core_n_km"] + R["core_km"])
PHOTO_PX = 8192
COVERAGE_PX = 1024
JPEG_QUALITY = 85
TREE_MIN_M = 3.0          # canopy heights below this are shrubs, not trees
CONIFER_PEAK_M = 2.0      # a top this far above its crown's 5 x 5 m mean is a spire: a conifer
BUILDING_MIN_M = 2.5      # roofs lower than this over the ground are walls, cars or noise
BUILDING_MIN_CELLS = 12   # 1 m cells; smaller blobs are not buildings
CREDIT = ("Cyclic laser scanning of Slovenia 2023-2025 (CLSS), classified point cloud GKOT: "
          "Surveying and Mapping Authority of the Republic of Slovenia (GURS), CC BY 4.0")


def sheets():
    for n in N_KM:
        for e in E_KM:
            path = RASTER / f"{e}_{n}.npz"
            if path.exists():
                yield e, n, path


def push_pull_fill(image: np.ndarray, valid: np.ndarray) -> np.ndarray:
    """Fill invalid pixels with a smooth blend of the valid ones (push-pull pyramid)."""
    levels = [(image * valid[..., None], valid.astype(np.float64))]
    while min(levels[-1][1].shape) > 1:
        c, w = levels[-1]
        h, wd = (w.shape[0] // 2) * 2, (w.shape[1] // 2) * 2
        c2 = c[:h, :wd].reshape(h // 2, 2, wd // 2, 2, -1).sum(axis=(1, 3))
        w2 = w[:h, :wd].reshape(h // 2, 2, wd // 2, 2).sum(axis=(1, 3))
        levels.append((c2, w2))
    colour = levels[-1][0] / np.maximum(levels[-1][1], 1e-9)[..., None]
    for c, w in reversed(levels[:-1]):
        up = np.repeat(np.repeat(colour, 2, axis=0), 2, axis=1)
        full = np.zeros(c.shape)
        full[:up.shape[0], :up.shape[1]] = up
        if up.shape[0] < c.shape[0]:
            full[up.shape[0]:, :up.shape[1]] = up[-1:]
        if up.shape[1] < c.shape[1]:
            full[:, up.shape[1]:] = full[:, up.shape[1] - 1:up.shape[1]]
        own = c / np.maximum(w, 1e-9)[..., None]
        colour = np.where((w > 0)[..., None], own, full)
    return colour


def load_core():
    header = json.loads((TERRAIN / "core.json").read_text())
    raw = gzip.decompress((TERRAIN / header["data"]).read_bytes())
    q = np.frombuffer(raw, "<u2").reshape(header["rows"], header["columns"])
    return header["base_m"] + q * header["step_m"], header   # rows south to north


def core_height(core2, east, north):
    """Bilinear height of the 2 m core (rows south to north, node (0, 0) at 1 m, 1 m) at core-frame points."""
    x = np.clip((east - 1.0) / 2.0, 0, core2.shape[1] - 1.001)
    y = np.clip((north - 1.0) / 2.0, 0, core2.shape[0] - 1.001)
    c = np.floor(x).astype(int)
    r = np.floor(y).astype(int)
    fx = x - c
    fy = y - r
    return ((core2[r, c] * (1 - fx) + core2[r, c + 1] * fx) * (1 - fy)
            + (core2[r + 1, c] * (1 - fx) + core2[r + 1, c + 1] * fx) * fy)


def ground_1m(core2, e, n):
    """Bare-earth heights for one sheet at 1 m, rows north to south, from the 2 m core (nearest node)."""
    col0 = (e - E_KM.start) * 500
    row0 = (n - N_KM.start) * 500
    block = core2[row0:row0 + 500, col0:col0 + 500][::-1]          # north to south
    return np.repeat(np.repeat(block, 2, axis=0), 2, axis=1)


def local_max(chm: np.ndarray, radius: int) -> np.ndarray:
    padded = np.pad(chm, radius, constant_values=-np.inf)
    window = np.lib.stride_tricks.sliding_window_view(padded, (2 * radius + 1, 2 * radius + 1))
    return chm >= window.max(axis=(2, 3))


def trees_for_sheet(data, ground, e, n):
    veg = data["veg_top"]
    chm = np.where(np.isfinite(veg), veg - ground, 0.0)
    chm = np.clip(chm, 0.0, 60.0)
    tops = local_max(chm, 2) & (chm >= TREE_MIN_M)
    rows, cols = np.nonzero(tops)
    h = chm[rows, cols]
    # Crown shape: spruce and fir tops are spires, so the top stands well above the mean of its 5 x 5 m
    # neighbourhood; beech, maple and most larch crowns are rounded.
    # Only crown cells (at least half the top's height) count, so open ground beside a lone tree does not make it a spire.
    padded = np.pad(chm, 2, mode="edge")
    window = np.lib.stride_tricks.sliding_window_view(padded, (5, 5))[rows, cols]
    crown = window >= 0.5 * h[:, None, None]
    mean_crown = (window * crown).sum(axis=(1, 2)) / np.maximum(crown.sum(axis=(1, 2)), 1)
    conifer = (h - mean_crown) >= CONIFER_PEAK_M
    east = (e - E_KM.start) * 1000.0 + cols + 0.5
    north = (n - N_KM.start) * 1000.0 + 1000.0 - rows - 0.5
    radius = np.where(conifer, 0.8 + 0.12 * h, 1.2 + 0.18 * h)
    return east, north, h, radius, conifer


def building_records(roof: np.ndarray, ground: np.ndarray):
    """Connected roof regions of the 8000 x 8000 1 m roof grid (rows north to south) as compact records."""
    mask = np.isfinite(roof) & ((roof - ground) >= BUILDING_MIN_M)
    seen = np.zeros(mask.shape, bool)
    records = []
    cells_total = 0
    size = mask.shape[0]
    for r0, c0 in zip(*np.nonzero(mask)):
        if seen[r0, c0]:
            continue
        stack = [(int(r0), int(c0))]
        seen[r0, c0] = True
        cells = []
        while stack:
            r, c = stack.pop()
            cells.append((r, c))
            for rr, cc in ((r + 1, c), (r - 1, c), (r, c + 1), (r, c - 1)):
                if 0 <= rr < size and 0 <= cc < size and mask[rr, cc] and not seen[rr, cc]:
                    seen[rr, cc] = True
                    stack.append((rr, cc))
        if len(cells) < BUILDING_MIN_CELLS:
            continue
        rc = np.array(cells)
        # Tiles of at most 255 x 255 m; a larger region (rare) becomes several records whose shared walls hide.
        for tr in range(rc[:, 0].min(), rc[:, 0].max() + 1, 255):
            for tc in range(rc[:, 1].min(), rc[:, 1].max() + 1, 255):
                sel = rc[(rc[:, 0] >= tr) & (rc[:, 0] < tr + 255) & (rc[:, 1] >= tc) & (rc[:, 1] < tc + 255)]
                if len(sel) == 0:
                    continue
                top, bottom = sel[:, 0].min(), sel[:, 0].max()
                left, right = sel[:, 1].min(), sel[:, 1].max()
                w, h = int(right - left + 1), int(bottom - top + 1)
                base = float(np.min(ground[sel[:, 0], sel[:, 1]])) - 0.3
                grid = np.zeros((h, w), np.uint8)
                rel = np.clip(np.rint((roof[sel[:, 0], sel[:, 1]] - base) / 0.2), 1, 255).astype(np.uint8)
                grid[bottom - sel[:, 0], sel[:, 1] - left] = rel        # rows south to north
                head = np.array([left, size - 1 - bottom], "<u2").tobytes() + bytes([w, h]) + \
                    np.array([int(round(base * 10))], "<u2").tobytes()
                records.append(head + grid.tobytes())
                cells_total += len(sel)
    return records, cells_total


def harmonize_sheets(photo: np.ndarray, strip_px: int = 40) -> np.ndarray:
    """Even out the sheet-to-sheet colour of a survey flown over many days (Kamnik). Each 1 km sheet and channel gets
    an affine map, gain g and offset b, solved by least squares so that across every shared sheet edge the strips
    (strip_px wide, about 40 m) on both sides have equal contrast (log g_i + log sd_i = log g_j + log sd_j) and then
    equal mean (g_i mu_i + b_i = g_j mu_j + b_j). Gauge: the mean log gain and the mean offset are zero, so the photo
    keeps its overall brightness and contrast."""
    rows, cols = len(N_KM), len(E_KM)
    side = photo.shape[0] // cols
    index = {(r, c): r * cols + c for r in range(rows) for c in range(cols)}
    edges = []  # (i, j, strip i, strip j): strips that face each other across the edge
    for r in range(rows):
        for c in range(cols):
            y0, x0 = r * side, c * side
            if c + 1 < cols:
                edges.append((index[r, c], index[r, c + 1],
                              photo[y0:y0 + side, x0 + side - strip_px:x0 + side], photo[y0:y0 + side, x0 + side:x0 + side + strip_px]))
            if r + 1 < rows:
                edges.append((index[r, c], index[r + 1, c],
                              photo[y0 + side - strip_px:y0 + side, x0:x0 + side], photo[y0 + side:y0 + side + strip_px, x0:x0 + side]))
    n = rows * cols
    gains = np.ones((n, 3))
    offsets = np.zeros((n, 3))
    for ch in range(3):
        a = np.zeros((len(edges) + 1, n))
        y = np.zeros(len(edges) + 1)
        for k, (i, j, si, sj) in enumerate(edges):
            a[k, i], a[k, j] = 1.0, -1.0
            y[k] = np.log(max(sj[..., ch].std(), 1.0)) - np.log(max(si[..., ch].std(), 1.0))
        a[-1, :] = 1.0
        log_g = np.linalg.lstsq(a, y, rcond=None)[0]
        gains[:, ch] = np.clip(np.exp(log_g), 0.5, 2.0)
        for k, (i, j, si, sj) in enumerate(edges):
            y[k] = gains[j, ch] * sj[..., ch].mean() - gains[i, ch] * si[..., ch].mean()
        offsets[:, ch] = np.linalg.lstsq(a, y, rcond=None)[0]
    out = photo.copy()
    for (r, c), i in index.items():
        block = photo[r * side:(r + 1) * side, c * side:(c + 1) * side]
        out[r * side:(r + 1) * side, c * side:(c + 1) * side] = block * gains[i] + offsets[i]
    return out


def bake():
    core2, _ = load_core()
    mosaic = np.zeros((16000, 16000, 3), np.uint8)
    present = []
    trees = []
    roof = np.full((8000, 8000), np.nan, np.float32)
    ground_all = np.zeros((8000, 8000), np.float32)
    for e, n, path in sheets():
        data = np.load(path)
        r0 = (N_KM.stop - 1 - n) * 2000
        c0 = (e - E_KM.start) * 2000
        mosaic[r0:r0 + 2000, c0:c0 + 2000] = data["rgb"]
        ground = ground_1m(core2, e, n)
        trees.append(trees_for_sheet(data, ground, e, n))
        roof[r0 // 2:r0 // 2 + 1000, c0 // 2:c0 // 2 + 1000] = data["bld_top"]
        ground_all[r0 // 2:r0 // 2 + 1000, c0 // 2:c0 // 2 + 1000] = ground
        present.append(f"{e}_{n}")

    # Photo: 0.5 m mosaic -> 8192 px, holes filled at the reduced size.
    valid_half = mosaic.any(axis=2)
    small = np.asarray(Image.fromarray(mosaic).resize((PHOTO_PX, PHOTO_PX), Image.Resampling.BOX), np.float64)
    weight = np.asarray(Image.fromarray(valid_half.astype(np.uint8) * 255).resize((PHOTO_PX, PHOTO_PX),
                                                                                 Image.Resampling.BOX), np.float64) / 255.0
    # BOX averaged black holes into the colour: undo that, then fill the empty pixels.
    colour = np.where(weight[..., None] > 0, small / np.maximum(weight, 1e-9)[..., None], 0.0)
    filled = push_pull_fill(colour, weight > 0.5)
    if R.get("photo_harmonize"):
        filled = harmonize_sheets(filled)
    photo = Image.fromarray(np.clip(np.rint(filled), 0, 255).astype(np.uint8))
    buf = io.BytesIO()
    photo.save(buf, "JPEG", quality=JPEG_QUALITY, optimize=True, subsampling=0)
    coverage = Image.fromarray((weight > 0.5).astype(np.uint8) * 255).resize((COVERAGE_PX, COVERAGE_PX),
                                                                             Image.Resampling.BOX)
    cov_buf = io.BytesIO()
    coverage.save(cov_buf, "PNG", optimize=True)

    east = np.concatenate([t[0] for t in trees]) if trees else np.zeros(0)
    north = np.concatenate([t[1] for t in trees]) if trees else np.zeros(0)
    height = np.concatenate([t[2] for t in trees]) if trees else np.zeros(0)
    radius = np.concatenate([t[3] for t in trees]) if trees else np.zeros(0)
    conifer = np.concatenate([t[4] for t in trees]) if trees else np.zeros(0, bool)
    order = np.lexsort((east, north))
    rec = np.zeros(len(order), dtype=[("e", "<u2"), ("n", "<u2"), ("g", "<u2"), ("h", "u1"), ("r", "u1"), ("k", "u1"),
                                      ("x", "u1")])
    rec["e"] = np.clip(np.rint(east[order] * 5), 0, 40000)        # 0.2 m units
    rec["n"] = np.clip(np.rint(north[order] * 5), 0, 40000)
    # Ground at the stored (rounded) position, so a record is self-consistent even on a cliff.
    rec["g"] = np.clip(np.rint((core_height(core2, rec["e"] * 0.2, rec["n"] * 0.2) - TREE_GROUND_BASE_M) * 32.0), 0, 65535)
    rec["h"] = np.clip(np.rint(height[order] * 4), 0, 255)
    rec["r"] = np.clip(np.rint(radius[order] * 10), 0, 255)
    rec["k"] = np.where(conifer[order], 0, 1)
    tree_buf = io.BytesIO()
    with gzip.GzipFile(fileobj=tree_buf, mode="wb", compresslevel=9, mtime=0) as handle:
        handle.write(rec.tobytes())

    records, building_cells = building_records(roof, ground_all)
    bld_buf = io.BytesIO()
    with gzip.GzipFile(fileobj=bld_buf, mode="wb", compresslevel=9, mtime=0) as handle:
        handle.write(b"".join(records))

    files = {
        "buildings/buildings.bin.gz": bld_buf.getvalue(),
        "photo/ortho.jpg": buf.getvalue(),
        "photo/coverage.png": cov_buf.getvalue(),
        "vegetation/trees.bin.gz": tree_buf.getvalue(),
    }
    common = {"sheets": present, "source": CREDIT, "generator": "research/triglav/TG-02/bake_gkot.py",
              "origin": f"core south-west corner, D96/TM E {E_KM.start * 1000} m, N {N_KM.start * 1000} m; grid north"}
    files["photo/ortho.json"] = (json.dumps({
        "format": "openrc-orthophoto v1", **common, "pixels": PHOTO_PX, "size_m": 8000.0,
        "row_order": "north to south; column order west to east",
        "pillow": PIL.__version__, "jpeg_quality": JPEG_QUALITY,
        "data_sha256": hashlib.sha256(files["photo/ortho.jpg"]).hexdigest(),
        "coverage_sha256": hashlib.sha256(files["photo/coverage.png"]).hexdigest(),
        "real_fraction": round(float((weight > 0.5).mean()), 4)}, indent=1) + "\n").encode()
    files["vegetation/trees.json"] = (json.dumps({
        "format": "openrc-trees v1", **common, "count": int(len(rec)),
        "record": f"10 bytes LE: uint16 east, uint16 north (0.2 m units from the origin), uint16 ground ({TREE_GROUND_BASE_M:.0f} m + "
                  "value / 32), uint8 height (0.25 m), uint8 crown radius (0.1 m), uint8 kind (0 conifer, 1 broadleaf), "
                  "uint8 spare",
        "order": "by north, then east", "min_height_m": TREE_MIN_M,
        "conifers": int((rec["k"] == 0).sum()),
        "data_sha256": hashlib.sha256(files["vegetation/trees.bin.gz"]).hexdigest()}, indent=1) + "\n").encode()
    files["buildings/buildings.json"] = (json.dumps({
        "format": "openrc-buildings v1", **common, "count": len(records), "cells": building_cells,
        "record": "uint16 east and uint16 north of the south-west cell (m from the origin), uint8 columns, "
                  "uint8 rows, uint16 base height (dm above the datum; the lowest ground under the roof minus 0.3 m), "
                  "then rows x columns uint8 roof heights above the base in 0.2 m units (0: no roof), rows south "
                  "to north, columns west to east; cells are 1 m",
        "min_roof_m": BUILDING_MIN_M, "min_cells": BUILDING_MIN_CELLS,
        "data_sha256": hashlib.sha256(files["buildings/buildings.bin.gz"]).hexdigest()}, indent=1) + "\n").encode()
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--out", type=Path, default=OUT, help="write here instead (trial bakes)")
    args = parser.parse_args()
    out = args.out
    files = bake()
    if args.check:
        stale = [name for name, data in files.items() if not (out / name).exists() or (out / name).read_bytes() != data]
        print(f"{'FAIL' if stale else 'ok'}: {len(files) - len(stale)}/{len(files)} files current {stale}")
        return 1 if stale else 0
    for name, data in files.items():
        (out / name).parent.mkdir(parents=True, exist_ok=True)
        (out / name).write_bytes(data)
        print(f"wrote {(out / name)} ({len(data) / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
