# Triglav National Park terrain: Planica and Tamar (Step 21)

Real terrain for the planned Planica/Tamar landscape ([plan](../../docs/plans/triglav-planica-tamar.md)). This folder
holds the data pipeline; the landscape adapter, materials and solid ground contact are later steps of the plan.

| Step | Script | Writes |
| --- | --- | --- |
| TG-01 fetch and pin | `TG-01/fetch_dem.py [--check]` (standard library) | raw tiles in `tmp/triglav/` (about 1.6 GB, not committed); `sources.json` pins every file's size and SHA-256 |
| TG-02 bake | `TG-02/bake_terrain.py [--check]` (numpy) | `app/landscapes/triglav_tamar/terrain/core.*` (8 × 8 km at 2 m) and `ring.*` (24 × 24 km at 16 m) |

Run TG-01, then TG-02. `--check` on TG-02 rebakes in memory and compares the committed bytes.

## Sources

- **ARSO LiDAR DMR1**: the 1 m bare-earth terrain model of the 2014–15 national laser scan, served as 1 km tiles in
  D96/TM (EPSG:3794) from `gis.arso.gov.si`. The core uses the 62 tiles E 399–406 km × N 144–151 km (blocks `b_37` and
  `b_31`). The two tiles at E 399, N 150–151 lie in Italy and are not served.
  Credit: *Ministry of the Environment and Spatial Planning, Slovenian Environment Agency (ARSO).* The terms ("free to
  use, modify and reuse" with that credit) are as recorded by [OpenDEM](https://opendem.info/opendemeu_meta_slovenia.html);
  confirm them with ARSO before a public release.
- **SRTM** 1 arc-second, Mapzen Terrain Tiles `N46E013` (public domain): the ring outside the core and the two Italian
  tiles. Credit: *SRTM data courtesy of the U.S. Geological Survey; Mapzen Terrain Tiles.*

## The grids

- Format `openrc-heightfield v1`:
  - Each grid is a JSON header plus `*.u16.gz`: gzip of little-endian uint16, height = 600 m + value / 32.
  - Rows run south to north, columns west to east, in grid north.
  - D96/TM grid north is 0.94° east of true north here; the meridian convergence at 13.7° E.
- **Core:** 4000 × 4000 nodes, each the mean of a 2 × 2 block of 1 m samples. The Italian tiles are filled from SRTM,
  shifted by the mean LiDAR − SRTM difference along their edge (−8.8 m).
- **Ring:** 1500 × 1500 nodes. The core's area is averaged from the core, the rest is SRTM; it is for the far view
  only.

## Validation (2026-11-18)

| Point | Baked | Published |
| --- | --- | --- |
| Dom v Tamarju (46.44605 N, 13.71341 E) | 1108.1 m | 1108 m |
| Rateče | 864.5 m | about 870 m |
| Planica Nordic Centre (approximate point) | 953.8 m | about 930 m (user-submitted route data) |

The core spans 793 m (the Sava valley floor at its east edge, towards Kranjska Gora) to 2379 m (the ridge at its south
edge). No height was clamped.
