#!/usr/bin/env python3
"""KM-03: Ljubljana's skyline for the Kamnik landscape, from the GURS CLSS 2023-25 point clouds.

Inputs: the rasterised city sheets `tmp/ljubljana_city/gkot_raster/<E>_<N>.npz` (research/triglav/TG-02/raster_gkot.py
--region ljubljana_city): 1 m ground and roof tops, 0.5 m colour. The city is 17 km from the Kamnik pilot, so it is
drawn as blocks, not as the core's detailed roofs: every CELL_M square cell that is mostly roof (at least
MIN_COVERAGE of its 1 m pixels carry a GKOT class-6 top) becomes one block from the cell's ground to the 90th
percentile of its roof heights (so towers keep their height), coloured by the mean colour of its roof pixels.

Output in `app/landscapes/kamnik_duplica/city/`:
- `city.bin.gz`: gzip (mtime 0) of 12-byte little-endian records: uint16 column, uint16 row (cells east and north of
  the origin), uint16 ground (dm above the height datum), uint16 height (dm above that ground), uint8 red, green,
  blue (sRGB), uint8 roof coverage (0-255).
- `city.json`: header (origin, cell size, count, record layout, checksum, source).

    tmp/triglav/venv/bin/python research/kamnik/KM-03/bake_city.py [--check] [--partial]
"""
import argparse
import gzip
import hashlib
import io
import json
import sys
import warnings
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "research/triglav"))
import region as regions  # noqa: E402

CITY = regions.REGIONS["ljubljana_city"]
RASTER = CITY["cache"] / "gkot_raster"
OUT = regions.REGIONS["kamnik"]["landscape"] / "city"
E_KM = range(CITY["core_e_km"], CITY["core_e_km"] + CITY["core_km"])
N_KM = range(CITY["core_n_km"], CITY["core_n_km"] + CITY["core_km"])
CELL_M = 12.5
PER_KM = int(1000 / CELL_M)       # 80 cells a sheet side
MIN_COVERAGE = 0.35
MIN_HEIGHT_M = 3.0
CREDIT = ("Cyclic laser scanning of Slovenia 2023-2025 (CLSS), classified point cloud GKOT: Surveying and Mapping "
          "Authority of the Republic of Slovenia (GURS), CC BY 4.0")


def cells(a: np.ndarray, k: int) -> np.ndarray:
    """(rows, cols, ...) -> (rows/k, cols/k, k*k, ...) blocks."""
    r, c = a.shape[0] // k, a.shape[1] // k
    rest = a.shape[2:]
    return a[:r * k, :c * k].reshape(r, k, c, k, *rest).swapaxes(1, 2).reshape(r, c, k * k, *rest)


def sheet_records(e: int, n: int):
    data = np.load(RASTER / f"{e}_{n}.npz")
    ground = data["ground"][::-1].astype(np.float64)    # rows south to north
    roof = data["bld_top"][::-1].astype(np.float64)
    rgb = data["rgb"][::-1].astype(np.float64)          # 0.5 m
    # 12.5 m cells hold 12.5 x 12.5 one-metre pixels: work on 25 x 25 half-metre pixels, the 1 m grids upsampled.
    k = int(CELL_M * 2)
    g2 = np.repeat(np.repeat(ground, 2, 0), 2, 1)
    r2 = np.repeat(np.repeat(roof, 2, 0), 2, 1)
    gc, rc, cc = cells(g2, k), cells(r2, k), cells(rgb.reshape(2000, 2000, 3), k)
    # Ground per cell: the median of its ground pixels; cells without any take the sheet's nearest ring of cells.
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)   # cells wholly under roofs have no ground pixel
        g_cell = np.nanmedian(gc, axis=2)
    if np.isnan(g_cell).any():
        valid = np.isfinite(g_cell)
        fill = np.where(valid, g_cell, 0.0)
        weight = valid.astype(np.float64)
        for _ in range(40):
            if weight.all():
                break
            pad_f = np.pad(fill * weight, 1)
            pad_w = np.pad(weight, 1)
            s = sum(pad_f[1 + dy:pad_f.shape[0] - 1 + dy, 1 + dx:pad_f.shape[1] - 1 + dx]
                    for dy in (-1, 0, 1) for dx in (-1, 0, 1))
            w = sum(pad_w[1 + dy:pad_w.shape[0] - 1 + dy, 1 + dx:pad_w.shape[1] - 1 + dx]
                    for dy in (-1, 0, 1) for dx in (-1, 0, 1))
            grow = (weight == 0) & (w > 0)
            fill = np.where(grow, s / np.maximum(w, 1e-9), fill)
            weight = np.where(grow, 1.0, weight)
        g_cell = np.where(weight > 0, fill, np.nan)
    is_roof = np.isfinite(rc)
    coverage = is_roof.mean(axis=2)
    out = []
    rows_c, cols_c = coverage.shape
    for r in range(rows_c):
        for c in range(cols_c):
            if coverage[r, c] < MIN_COVERAGE or not np.isfinite(g_cell[r, c]):
                continue
            tops = rc[r, c][is_roof[r, c]]
            height = float(np.percentile(tops, 90)) - g_cell[r, c]
            if height < MIN_HEIGHT_M:
                continue
            colour = cc[r, c][is_roof[r, c]].mean(axis=0)
            out.append((
                (e - E_KM.start) * PER_KM + c, (n - N_KM.start) * PER_KM + r,
                int(round(g_cell[r, c] * 10)), int(round(height * 10)),
                *[int(round(v)) for v in colour], int(round(coverage[r, c] * 255)),
            ))
    return out


def absent_sheets() -> set:
    """Sheets the viewer has no point cloud for, as pinned by fetch_gkot.py --record (the 2023-25 survey's Ljubljana
    block ends at N 100 km, so the southern rows N 98-99 km, the marsh south of Rudnik, are absent)."""
    pins = json.loads(CITY["sources"].read_text()).get("clss_gkot", [])
    return {pin["sheet"] for pin in pins if "absent" in pin}


def bake(partial: bool = False):
    absent = absent_sheets()
    present = [(e, n) for n in N_KM for e in E_KM if (RASTER / f"{e}_{n}.npz").exists()]
    missing = [f"{e}_{n}" for n in N_KM for e in E_KM if (e, n) not in present and f"{e}_{n}" not in absent]
    if missing and not partial:
        raise SystemExit(f"FAIL: city sheets not rasterised: {missing[:8]}")
    records = []
    for e, n in present:
        records.extend(sheet_records(e, n))
    dtype = np.dtype([("c", "<u2"), ("r", "<u2"), ("g", "<u2"), ("h", "<u2"),
                      ("red", "u1"), ("green", "u1"), ("blue", "u1"), ("cov", "u1")])
    table = np.array(records, dtype=dtype)
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", compresslevel=9, mtime=0) as handle:
        handle.write(table.tobytes())
    payload = buffer.getvalue()
    tallest = table[np.argmax(table["h"])]
    header = {
        "format": "openrc-city-blocks v1",
        "crs": "D96/TM (EPSG:3794); grid north; heights in metres above the Slovenian height datum",
        "origin_east_m": E_KM.start * 1000.0,
        "origin_north_m": N_KM.start * 1000.0,
        "cell_m": CELL_M,
        "columns": len(E_KM) * PER_KM,
        "rows": len(N_KM) * PER_KM,
        "count": int(len(table)),
        "record": "12 bytes LE: uint16 column, uint16 row (cells east and north of the origin), uint16 ground (dm), "
                  "uint16 height above the ground (dm), uint8 red, green, blue (sRGB roof colour), uint8 roof coverage",
        "tallest": {"column": int(tallest["c"]), "row": int(tallest["r"]), "height_m": float(tallest["h"]) / 10.0},
        "sheets": [f"{e}_{n}" for e, n in present],
        "absent_sheets": sorted(absent),
        "data": "city.bin.gz",
        "data_sha256": hashlib.sha256(payload).hexdigest(),
        "source": CREDIT,
        "generator": "research/kamnik/KM-03/bake_city.py",
    }
    return {"city.bin.gz": payload, "city.json": (json.dumps(header, indent=1) + "\n").encode()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--partial", action="store_true", help="preview with the sheets rasterised so far")
    args = parser.parse_args()
    outputs = bake(args.partial)
    if args.check:
        stale = [name for name, data in outputs.items() if not (OUT / name).exists() or (OUT / name).read_bytes() != data]
        print(f"{'FAIL' if stale else 'ok'}: {len(outputs) - len(stale)}/{len(outputs)} city files current {stale}")
        return 1 if stale else 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in outputs.items():
        (OUT / name).write_bytes(data)
        print(f"wrote {(OUT / name).relative_to(REPO)} ({len(data) / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
