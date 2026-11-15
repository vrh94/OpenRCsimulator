#!/usr/bin/env python3
"""FC-4 (14b): long-range FPV landmarks, written to app/data/scenery/long_range.json.

A visual-only backdrop beyond the club's horizon ring, like the distant ridges: three towns with churches, two
farmsteads and two wind farms, linked by one gravel ring road. A pilot flying out in any open direction crosses the
road and can follow it from landmark to landmark. Everything stands on the flat ground past the 6 km horizon relief
and clear of the visual mountains (render/landscape_upgrade/ridges.gd). Existing prefabs only (scenery/prefabs.gd);
estimated layout, not surveyed.

  python3 tools/scenery/long_range.py           # write the layout
  python3 tools/scenery/long_range.py --check   # fail if the committed file differs
"""
import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from place import dumps, h01, polar  # noqa: E402  (the scenery tool's hash, polar convention and row format)

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "app/data/scenery/long_range.json"
MIN_M = 6500.0  # past the 6 km horizon relief: flat ground
MAX_M = 18000.0  # inside the 20 km ground and the 21 km camera far plane
RIDGES = (1600.0, 8600.0, 6500.0)  # visual mountains: north min/max, |east| max (ridges.gd)
RIDGE_MARGIN_M = 400.0
ROAD_WIDTH_M = 6.0
ROAD_STEP_M = 250.0
ROAD_MEANDER_M = 35.0


def clear(n, e):
    r = math.hypot(n, e)
    in_ridges = RIDGES[0] - RIDGE_MARGIN_M <= n <= RIDGES[1] + RIDGE_MARGIN_M and abs(e) <= RIDGES[2] + RIDGE_MARGIN_M
    return MIN_M <= r <= MAX_M and not in_ridges


def seg_dist(p, a, b):
    ab = (b[0] - a[0], b[1] - a[1])
    t = max(0.0, min(1.0, ((p[0] - a[0]) * ab[0] + (p[1] - a[1]) * ab[1]) / max(ab[0] ** 2 + ab[1] ** 2, 1e-9)))
    return math.hypot(p[0] - a[0] - t * ab[0], p[1] - a[1] - t * ab[1])


def road_dist(p, road):
    return min(seg_dist(p, a, b) for a, b in zip(road, road[1:]))


CENTRES = {"west-town": polar(8000.0, 262.0), "east-village": polar(13000.0, 97.0),
           "north-village": polar(15000.0, 8.0), "southeast-farm": polar(7000.0, 135.0),
           "northwest-farm": polar(9500.0, 300.0)}


def ring_road():
    """Nodes through every landmark; legs split every ~250 m with a hashed meander that is zero at the nodes."""
    nw, se = CENTRES["northwest-farm"], CENTRES["southeast-farm"]
    nodes = [CENTRES["west-town"], (nw[0] - 70.0, nw[1] + 60.0), (9300.0, -7200.0), CENTRES["north-village"],
             (9500.0, 8000.0), CENTRES["east-village"], (se[0] + 70.0, se[1] - 60.0), polar(9800.0, 180.0),
             polar(15700.0, 222.0), CENTRES["west-town"]]
    road = [nodes[0]]
    for leg, (a, b) in enumerate(zip(nodes, nodes[1:])):
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        steps = max(1, round(length / ROAD_STEP_M))
        side = (-(b[1] - a[1]) / length, (b[0] - a[0]) / length)
        for i in range(1, steps + 1):
            t = i / steps
            wiggle = 0.0 if i == steps else ROAD_MEANDER_M * math.sin(math.pi * t) * (h01(leg, i, 41) * 2.0 - 1.0)
            road.append((a[0] + t * (b[0] - a[0]) + wiggle * side[0], a[1] + t * (b[1] - a[1]) + wiggle * side[1]))
    for n, e in road:
        assert clear(n, e), ("ring road", n, e)
    return road


def town(key, centre, count, spread_m, road):
    """A church beside the road and `count` houses round it, clear of the road, the church and each other."""
    cn, ce = centre
    church = (cn + 45.0, ce + 20.0)
    assert road_dist(church, road) >= 22.0, ("church on the road", key)
    items = [("church", church[0], church[1], h01(key, 7) * 360.0)]
    houses, i = [], 0
    while len(houses) < count:
        a = math.radians(h01(key, i, 1) * 360.0)
        d = 40.0 + h01(key, i, 2) * spread_m
        n, e = cn + d * math.cos(a), ce + d * math.sin(a)
        if all(math.hypot(n - m[0], e - m[1]) >= 28.0 for m in houses) and road_dist((n, e), road) >= 16.0 \
                and math.hypot(n - church[0], e - church[1]) >= 30.0:
            houses.append((n, e))
            items.append(("village_house", n, e, h01(key, i, 3) * 360.0))
        i += 1
    return items


def farmstead(centre, turn, road):
    cn, ce = centre
    items = [("barn", cn, ce, turn), ("silo", cn + 16.0, ce + 12.0, 0.0), ("farmhouse", cn - 30.0, ce - 22.0, turn + 90.0)]
    for _prefab, n, e, _h in items:
        assert road_dist((n, e), road) >= 20.0, ("farm building on the road", centre)
    return items


def build():
    road = ring_road()
    clusters = []
    for key, (name, houses, spread) in enumerate((("west-town", 30, 380.0), ("east-village", 18, 260.0),
                                                  ("north-village", 14, 230.0))):
        clusters.append((name, "Town: church and houses along the ring road", town(key + 1, CENTRES[name], houses, spread, road)))
    for name, turn in (("southeast-farm", 20.0), ("northwest-farm", 65.0)):
        clusters.append((name, "Farmstead: barn, silo and farmhouse beside the ring road", farmstead(CENTRES[name], turn, road)))
    # Wind farms: rows across the line of sight, rotors facing the SW breeze like the near farm.
    clusters.append(("south-wind-farm", "Six turbines in a row", [("turbine", *polar(10000.0, 172.0 + i * 3.2), 250.0) for i in range(6)]))
    clusters.append(("southwest-wind-farm", "Five turbines, staggered",
                     [("turbine", *polar(16000.0 + (i % 2) * 300.0, 218.0 + i * 2.0), 250.0) for i in range(5)]))
    out = []
    for c, (name, what, items) in enumerate(clusters):
        rows = []
        for i, (prefab, n, e, heading) in enumerate(items):
            assert clear(n, e), (name, n, e)
            rows.append({"prefab": prefab, "north": round(n, 2), "east": round(e, 2), "heading": round(heading % 360.0, 1),
                         "seed": int(h01(c, i, 99) * 1_000_000)})
        cn = sum(r["north"] for r in rows) / len(rows)
        ce = sum(r["east"] for r in rows) / len(rows)
        out.append({"id": name, "what": what, "distance_m": round(math.hypot(cn, ce)),
                    "bearing_deg": round(math.degrees(math.atan2(ce, cn)) % 360.0), "items": rows})
    return {
        "format": "openrc-long-range v1",
        "generator": "tools/scenery/long_range.py",
        "source": "FC-4 art-directed long-range FPV landmarks; estimated metres north/east of the field origin; "
                  "existing scenery prefabs; visual only (no collision), like the distant ridges",
        "physical": False,
        "road": {"id": "ring-road", "surface": "gravel", "width_m": ROAD_WIDTH_M,
                 "points": [[round(n, 1), round(e, 1)] for n, e in road]},
        "clusters": out,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the committed file differs from a fresh layout")
    a = ap.parse_args()
    text = dumps(build())
    if a.check:
        if not OUT.exists() or OUT.read_text() != text:
            print(f"{OUT} differs from a fresh layout: run tools/scenery/long_range.py", file=sys.stderr)
            sys.exit(1)
        print("long-range layout matches the committed file")
        return
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
