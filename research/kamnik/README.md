# Kamnik (Duplica) airstrip and the Kamnik Alps (option 7)

Real terrain, photo, trees and buildings for the Ljubljana basin around the Kamnik airstrip, with the Kamnik Alps,
Krvavec, Rašica and Šmarna gora in view. The landscape is `app/landscapes/kamnik_duplica/`.

The pipeline is the Triglav one ([research/triglav/README.md](../triglav/README.md)) run with `--region kamnik`.
`research/triglav/region.py` holds both regions' extents, caches, sources and height encodings; the default region is
`triglav`, so the Triglav commands and committed bytes are unchanged (`--check` passes).

| Step | Command | Writes |
| --- | --- | --- |
| KM-01 DEM | `python3 research/triglav/TG-01/fetch_dem.py --region kamnik [--check]` | ARSO DMR1 core tiles and SRTM `N46E014`, `N45E014` in `tmp/kamnik/`; pins in `sources.json` |
| KM-01 GKOT | `tmp/triglav/venv/bin/python research/triglav/TG-01/fetch_gkot.py --region kamnik [--record]` | the GURS point clouds of the 64 core sheets in `tmp/kamnik/gkot/` |
| KM-01 ring photo | `tmp/triglav/venv/bin/python research/kamnik/KM-01/ring_photo.py fetch` | Sentinel-2 cloudless 2016 tiles in `tmp/kamnik/s2cloudless/`; pins in `sources.json` |
| KM-02 raster | `tmp/triglav/venv/bin/python research/triglav/TG-02/raster_gkot.py --region kamnik` | per-sheet rasters in `tmp/kamnik/gkot_raster/` |
| KM-02 terrain | `tmp/triglav/venv/bin/python research/triglav/TG-02/bake_terrain.py --region kamnik [--check]` | `terrain/core.*` (8 × 8 km at 2 m), `terrain/ring.*` (48 × 48 km at 16 m) |
| KM-02 GKOT products | `tmp/triglav/venv/bin/python research/triglav/TG-02/bake_gkot.py --region kamnik [--check]` | `photo/ortho.jpg`, `photo/coverage.png`, `vegetation/`, `buildings/` |
| KM-02 ring photo | `tmp/triglav/venv/bin/python research/kamnik/KM-01/ring_photo.py bake [--check]` | `photo/ring.jpg` (3600 px over 48 km), `photo/ring.json` |

## Extents

- **Core:** D96/TM E 464–471 km × N 114–121 km (64 ARSO tiles, block `b_36`; 64 GKOT sheets). It holds the airstrip,
  Kamnik town, Duplica, Mekinje and the first foothills of the Kamnik Alps.
- **Ring:** 48 × 48 km centred on the core, E 444–492 km × N 94–142 km: north to beyond Grintovec (2558 m, 18 km) and
  Kamniško sedlo (1903 m, 20 km), Krvavec (11 km); south-west to Rašica (8 km), Šmarna gora (12 km) and Ljubljana
  (17 km). Heights are SRTM (bilinear) outside the core; stored as 200 m + value / 16 (the Sava near Litija is about
  220 m, Grintovec 2558 m).
- **Core heights** are stored as 250 m + value / 32 (the plain is about 330–380 m, the core's highest foothill under
  1300 m). Tree records use the same base (`TREE_GROUND_BASE_M`).
- The camera far plane is 36 km on this landscape (`CAMERA_FAR_M`), so the ring's mountains are not clipped.
  How clearly they show depends on the sky's visibility: at the default 23 km meteorological visibility the Alps
  at 20 km keep about 3 % contrast, so they appear as a faint skyline; a clear sky shows them well.

## The airstrip (field)

From the LZS operating manual *Vzletišče Kamnik* (2021): reference point 46°11'49.540" N, 14°34'51.544" E (WGS84),
D96/TM E 467660, N 117567; elevation 349 m; runway 11/29, true bearing 112°/292°, 425 × 25 m grass (manual: "Trava") in a 465 × 30 m
strip; model aircraft use the first 50 m from threshold 29 (the east end). D96/TM grid north is 0.30° west of true
north here, so the runway's grid bearing is 112.3°. Field surfaces in this simulator are axis-aligned with grid
north, so the field's `strip` is a 36 × 10 m east-west box that lies inside the real 25 m runway near threshold 29;
the photo shows the real runway at its real angle.

## Core photo: sheet colour balance

The 2023–25 scan of this core was flown on many days, so its 1 km sheets differ in haze and exposure; unbalanced,
the photo is a visible patchwork (and a bright band across the ground at low view angles). `bake_gkot.py` therefore
balances the sheets for this region (`photo_harmonize` in `region.py`): one gain and offset per sheet and channel,
solved by least squares so that along all 112 shared sheet edges the 40 m strips on both sides have equal contrast
and mean, with the mean log gain and mean offset held at zero. Triglav's sheets come from one campaign and are not
balanced (its bytes are unchanged).

## Ring photo

Sentinel-2 cloudless 2016 (EOX, CC BY 4.0), WMTS layer `s2cloudless_3857` at zoom 13 (about 13 m per pixel here),
reprojected bilinearly to D96/TM and stored as one 3600 × 3600 JPEG. Inside the core the GKOT photo replaces it,
fading over the last 400 m to the core edge. Later EOX mosaics are CC BY-NC-SA and are not used.
