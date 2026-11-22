"""The surveyed Slovenian landscapes the TG pipeline bakes. Every script takes `--region <id>` (default `triglav`, so
the Triglav commands and bytes are unchanged); `select()` removes the option from sys.argv before the script's own
argument parser runs.

- triglav: Planica/Tamar, Triglav National Park (step 21, research/triglav/README.md).
- kamnik: the Kamnik (Duplica) airstrip in the Ljubljana basin with the Kamnik Alps (option 7, research/kamnik/README.md).
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

REGIONS = {
    "triglav": {
        "name": "Planica/Tamar, Triglav National Park, Slovenia",
        "cache": REPO / "tmp/triglav",
        "sources": REPO / "research/triglav/sources.json",
        "landscape": REPO / "app/landscapes/triglav_tamar",
        # The playable core, owner decision 2026-11-18: 8 x 8 km, D96/TM kilometre indices E 399-406, N 144-151.
        "core_e_km": 399,
        "core_n_km": 144,
        "core_km": 8,
        "ring_size_m": 24000.0,
        "ring_step_m": 16.0,
        # ARSO serves the tiles in survey blocks; the core spans two (found by probing 2026-11-18).
        "arso_blocks": (37, 31),
        # One skadi tile covers 46-47 N, 13-14 E: the whole valley and the ring.
        "srtm_tiles": {"N46E013": "https://s3.amazonaws.com/elevation-tiles-prod/skadi/N46/N46E013.hgt.gz"},
        "srtm_north_deg": 47.0,
        "srtm_west_deg": 13.0,
        "clss_search": "Rateče",
        "core_base_m": 600.0,       # lowest storable height; the region's valleys are above 800 m
        "core_step_m": 1.0 / 32.0,  # 3.1 cm; 65535 steps reach 2648 m: Jalovec is 2645 m
        "ring_base_m": 600.0,
        "ring_step_m_height": 1.0 / 32.0,
    },
    "kamnik": {
        "name": "Kamnik (Duplica) airstrip, Ljubljana basin, with the Kamnik Alps, Slovenia",
        "cache": REPO / "tmp/kamnik",
        "sources": REPO / "research/kamnik/sources.json",
        "landscape": REPO / "app/landscapes/kamnik_duplica",
        # 8 x 8 km around the airstrip (reference point D96/TM E 467660, N 117567): Kamnik town, Duplica and the
        # foothills of the Kamnik Alps. E 464-471, N 114-121 km.
        "core_e_km": 464,
        "core_n_km": 114,
        "core_km": 8,
        # 48 x 48 km: the whole Kamnik Alps ridge (Grintovec 18 km, Kamnisko sedlo 20 km north), Krvavec, Rasica
        # (8 km), Smarna gora (12 km) and Ljubljana (17 km south).
        "ring_size_m": 48000.0,
        "ring_step_m": 16.0,
        "arso_blocks": (36,),  # every core tile (probed 2026-11-22)
        "srtm_tiles": {
            "N46E014": "https://s3.amazonaws.com/elevation-tiles-prod/skadi/N46/N46E014.hgt.gz",
            "N45E014": "https://s3.amazonaws.com/elevation-tiles-prod/skadi/N45/N45E014.hgt.gz",
        },
        "srtm_north_deg": 47.0,
        "srtm_west_deg": 14.0,
        # The viewer searches addresses; Enter alone does not move the map here, so the fetch clicks this suggestion
        # (Kamnik old town, inside the core). Without it the zoom lands east of Ljubljana.
        "clss_search": "Kamnik",
        "clss_pick": "Zaprice 4, Kamnik",
        # Fetch nearest first: the airstrip's sheet and its neighbours are needed to place the field.
        "fetch_first": (467, 117),
        # The core's sheets were flown on many days: bake_gkot.py evens their colour against the ring photo.
        "photo_harmonize": True,
        "core_base_m": 250.0,       # the Kamniska Bistrica plain is about 330 m; 1/32 m steps reach 2298 m
        "core_step_m": 1.0 / 32.0,
        "ring_base_m": 200.0,       # Ljubljana and the Sava are near 270 m; Grintovec is 2558 m
        "ring_step_m_height": 1.0 / 16.0,
        # Option 7b: under Ljubljana the ring takes the GKOT ground of the city sheets (region ljubljana_city)
        # instead of SRTM, so the castle hill and the river banks are real; it fades back to SRTM over 1 km.
        "ring_lidar": ["ljubljana_city"],
    },
    # Option 7b: Ljubljana's skyline for the Kamnik landscape (research/kamnik/README.md). Only the GKOT sheets are
    # fetched and rasterised under this region; research/kamnik/KM-03/bake_city.py bakes them into the Kamnik
    # landscape (far city blocks, and the ring's ground under the city).
    "ljubljana_city": {
        "name": "Ljubljana city, for the Kamnik landscape's skyline, Slovenia",
        "cache": REPO / "tmp/ljubljana_city",
        "sources": REPO / "research/kamnik/sources_city.json",
        "landscape": REPO / "app/landscapes/kamnik_duplica",
        # 8 x 8 km: the centre and castle, Bezigrad, Siska, Vic, Moste, BTC and Stozice. E 458-465, N 98-105 km.
        "core_e_km": 458,
        "core_n_km": 98,
        "core_km": 8,
        "clss_search": "Prešernov trg",
        "clss_pick": "Prešernov trg 1, Ljubljana",
        "fetch_first": (462, 101),
    },
}


def select(argv: list = None) -> dict:
    """The region named by --region (or --region=), removed from argv; triglav by default."""
    argv = sys.argv if argv is None else argv
    region_id = "triglav"
    for index, arg in enumerate(list(argv)):
        if arg == "--region" and index + 1 < len(argv):
            region_id = argv[index + 1]
            del argv[index:index + 2]
            break
        if arg.startswith("--region="):
            region_id = arg.split("=", 1)[1]
            del argv[index]
            break
    if region_id not in REGIONS:
        raise SystemExit(f"unknown region {region_id!r}; known: {', '.join(REGIONS)}")
    return {"id": region_id, **REGIONS[region_id]}


def sheets(region: dict) -> list:
    """The core's 1 km sheets (E km, N km), north rows first as the viewer fetch walks them."""
    e0, n0, k = region["core_e_km"], region["core_n_km"], region["core_km"]
    return [(e, n) for n in range(n0 + k - 1, n0 - 1, -1) for e in range(e0, e0 + k)]
