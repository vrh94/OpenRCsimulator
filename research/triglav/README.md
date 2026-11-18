# Triglav National Park terrain: Planica and Tamar (Step 21)

Real terrain, photo, trees and buildings for the Planica/Tamar landscape
([plan](../../docs/plans/triglav-planica-tamar.md)). This folder holds the data pipeline; the landscape itself is
`app/landscapes/triglav_tamar/`.

| Step | Script | Writes |
| --- | --- | --- |
| TG-01 fetch and pin | `TG-01/fetch_dem.py [--check]` (standard library) | ARSO and SRTM tiles in `tmp/triglav/` (about 1.6 GB, not committed); `sources.json` pins every file's size and SHA-256 |
| TG-01b fetch GKOT | `TG-01/fetch_gkot.py [--record]` (Playwright) | the GURS classified point clouds in `tmp/triglav/gkot/` (about 40 GB, not committed); `--record` pins them in `sources.json` |
| TG-02b stage 1 | `TG-02/raster_gkot.py` (laspy, numpy) | one cache file per sheet in `tmp/triglav/gkot_raster/`: 0.5 m top-down colour, 1 m ground, vegetation and roof tops |
| TG-02 bake terrain | `TG-02/bake_terrain.py [--check]` (numpy) | `app/landscapes/triglav_tamar/terrain/core.*` (8 × 8 km at 2 m) and `ring.*` (24 × 24 km at 16 m) |
| TG-02b stage 2 | `TG-02/bake_gkot.py [--check]` (numpy, Pillow) | `photo/` (orthophoto), `vegetation/` (tree tops) and `buildings/` (roof grids) in the landscape folder |

Run TG-01, TG-01b, TG-02b stage 1, TG-02, then TG-02b stage 2 (it reads the baked core as bare earth). `--check` rebakes
in memory and compares the committed bytes. The Python packages live in a local venv, `tmp/triglav/venv` (see the
docstring of `fetch_gkot.py`); `fetch_dem.py` and `bake_terrain.py` need only the standard library and numpy.

## Sources

- **ARSO LiDAR DMR1**: the 1 m bare-earth terrain model of the 2014–15 national laser scan, served as 1 km tiles in
  D96/TM (EPSG:3794) from `gis.arso.gov.si`. The core uses the 62 tiles E 399–406 km × N 144–151 km (blocks `b_37` and
  `b_31`). The two tiles at E 399, N 150–151 lie in Italy and are not served.
  Credit: *Ministry of the Environment and Spatial Planning, Slovenian Environment Agency (ARSO).* The terms ("free to
  use, modify and reuse" with that credit) are as recorded by [OpenDEM](https://opendem.info/opendemeu_meta_slovenia.html);
  confirm them with ARSO before a public release.
- **GURS CLSS GKOT**: the classified point cloud of the cyclic laser scanning of Slovenia 2023–25 (LAS 1.4, point
  format 8: colour and near-infrared per point; ASPRS classes ground 2, vegetation 3–5, buildings 6). The core's
  sheets were surveyed from August 2024 to November 2025 (area "Jesenice"), about 20–60 points per m². Fetched one
  1 km sheet at a time through the public viewer [clss.si](https://clss.si/), as a person would; GURS publishes no
  bulk endpoint, and the viewer serves each sheet's files from `assets.flycom.si`. Sheets wholly in Italy do not
  exist (E 399, N 150–151). Credit: *Surveying and Mapping Authority of the Republic of Slovenia (GURS), cyclic laser
  scanning 2023–2025*, CC BY 4.0 ([terms](https://www.e-prostor.gov.si/en/access-to-geodetic-data/)); the page does
  not name the LiDAR products, so confirm with GURS before a public release.
- **SRTM** 1 arc-second, Mapzen Terrain Tiles `N46E013` (public domain): the ring outside the core and the two Italian
  tiles. Credit: *SRTM data courtesy of the U.S. Geological Survey; Mapzen Terrain Tiles.*

## The grids

- Format `openrc-heightfield v1`:
  - Each grid is a JSON header plus `*.u16.gz`: gzip of little-endian uint16, height = 600 m + value / 32.
  - Rows run south to north, columns west to east, in grid north.
  - D96/TM grid north is 0.94° east of true north here; the meridian convergence at 13.7° E.
- **Core:** 4000 × 4000 nodes. Each node is the mean of the GKOT ground points in its 2 × 2 m cell (the 2024–25
  survey, which matches the photo, trees and buildings). Cells without ground points (dense canopy) take the ARSO
  2014–15 value plus a smooth GKOT − ARSO offset field, so no step appears; the two surveys differ by a median of a
  few centimetres (the datum change between them). Where neither has data (Italy) SRTM fills, shifted by the mean
  LiDAR − SRTM difference along the hole's edge (−8.8 m).
- **Ring:** 1500 × 1500 nodes. The core's area is averaged from the core, the rest is SRTM; it is for the far view
  only.

## Photo, trees and buildings (TG-02b)

- **Orthophoto** (`photo/ortho.jpg`, 8192 × 8192, 0.98 m per pixel): the colour of the highest point in each 0.5 m
  cell, reduced by box averaging. That is a true orthophoto: crowns and roofs stand where they are, without the lean
  of an aerial frame. Points outside the photo's coverage carry pure white or black; they count as holes and are
  filled by a push-pull pyramid from the surrounding colour. `coverage.png` marks the real pixels, and the landscape
  blends to procedural alpine colour where the photo is filled.
- **Trees** (`vegetation/trees.bin.gz`): local maxima of the 1 m canopy height (vegetation top minus bare earth)
  in a 5 × 5 m window, at least 3 m tall. A top that stands at least 2 m above the mean of its crown's cells in that
  window is a spire, so a conifer; the rest are broadleaf. Crown radius is estimated from height. Each record also
  stores the ground under it, sampled at its stored position.
- **Buildings** (`buildings/buildings.bin.gz`): connected regions of class 6 roof points at least 2.5 m over the
  bare earth and at least 12 m², each a 1 m grid of roof heights over its lowest ground. The landscape rebuilds real
  footprints and roof shapes from them.

## Validation (2026-11-18)

| Point | Baked | Published |
| --- | --- | --- |
| Dom v Tamarju (46.44605 N, 13.71341 E) | 1108.1 m | 1108 m |
| Rateče | 864.5 m | about 870 m |
| Planica Nordic Centre (approximate point) | 953.8 m | about 930 m (user-submitted route data) |

The core spans 793 m (the Sava valley floor at its east edge, towards Kranjska Gora) to 2379 m (the ridge at its south
edge). No height was clamped.
