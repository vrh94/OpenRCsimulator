#!/usr/bin/env python3
"""XM-02: the X-Maxx 8S replica's visual model, generated from its design (no Blender, no third-party mesh).

Reads assets/vehicles/x-maxx/design.json (the same source as the XM-01 physics) and writes
app/assets/vehicles/x-maxx/x_maxx.glb: glTF 2.0 binary, model frame +X right, +Y up, -Z forward, origin on the centre
line at the chassis datum (the tub's flat underside). Shape and proportions only: no logos, decals or graphics.

Node contract (read by app/vehicles/ground/x_maxx_model.gd, which poses them from the physics state):

    XMaxx_Root
      Chassis, Body                      fixed to the chassis (Body is the shell the damage view dents)
      Bumper_F, Bumper_R                 the bumpers, which the damage view pushes in
      <C>_ArmLower, <C>_ArmUpper         origin at the inner hinge, the arm along +-X (C = FL, FR, RL, RR)
      <C>_Shock -> <C>_ShockRod          origin at the top mount, the shock along local -Y; the rod slides along -Y
      <C>_Driveshaft                     origin at the differential output, unit length along local +X (scaled)
      <C>_Suspension -> <C>_Steer -> <C>_Hub, <C>_Spin -> <C>_WheelMesh
                                         origin at the free-length wheel centre; spin about local +X

    python3 research/x-maxx/XM-02/build_model.py           # writes the GLB
    python3 research/x-maxx/XM-02/build_model.py --check   # fails if it is stale

Python standard library only; deterministic bytes. The mesh helpers and glTF writer are FD-02's
(research/fast-delta-780/FD-02/build_model.py), copied so each generator stays standalone. Modders: change the
`visual` block of the design (or this file) and rerun; XM-01 records the new GLB hash in the vehicle data.
"""
import json
import math
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = "research/x-maxx/XM-02/build_model.py"
DESIGN = ROOT / "assets/vehicles/x-maxx/design.json"
OUT_GLB = ROOT / "app/assets/vehicles/x-maxx/x_maxx.glb"
ROOT_NODE = "XMaxx_Root"
CORNERS = ["FL", "FR", "RL", "RR"]

# Rig constants shared with app/vehicles/ground/x_maxx_model.gd (the test checks they agree).
ARM_LOWER_Y = -0.035      # lower inner hinge height above the datum
ARM_UPPER_Y = 0.020       # upper inner hinge height
SHOCK_TOP = (0.085, 0.13)  # top mount: lateral, height
SHOCK_ARM = (0.13, 0.01)   # lower mount on the lower arm: along the arm, above it
SHOCK_BODY_LEN = 0.10
SHOCK_ROD_LEN = 0.10
DIFF_OUT_X = 0.065
DIFF_Y = -0.012
HUB_INSET = 0.04          # driveshaft outer joint inboard of the wheel centre

MATERIALS = [  # name, base colour (linear RGBA), roughness, metallic
    ("XM_Paint", [0.58, 0.006, 0.027, 1.0], 0.2, 0.0),
    ("XM_Trim_Black", [0.008, 0.008, 0.009, 1.0], 0.55, 0.0),
    ("XM_Plastic_Black", [0.012, 0.012, 0.013, 1.0], 0.5, 0.0),
    ("XM_Glass", [0.004, 0.005, 0.007, 1.0], 0.05, 0.0),
    ("XM_Tire_Rubber", [0.016, 0.016, 0.017, 1.0], 0.92, 0.0),
    ("XM_Wheel", [0.02, 0.02, 0.022, 1.0], 0.35, 0.3),
    ("XM_Metal", [0.55, 0.56, 0.6, 1.0], 0.35, 0.9),
    ("XM_Spring", [0.05, 0.05, 0.055, 1.0], 0.4, 0.5),
    ("XM_Light", [0.95, 0.9, 0.7, 1.0], 0.1, 0.0),
    ("XM_Accent", [0.5, 0.5, 0.52, 1.0], 0.45, 0.0),
]
MAT = {m[0]: i for i, m in enumerate(MATERIALS)}


# ---------------------------------------------------------------------------------------------------- vector helpers
def sub(a, b): return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
def add(a, b): return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
def mul(a, k): return [a[0] * k, a[1] * k, a[2] * k]
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def norm(a):
    n = math.sqrt(dot(a, a))
    return [a[0] / n, a[1] / n, a[2] / n] if n > 0 else [0.0, 0.0, 0.0]


def P(fwd, right, up):
    """Physics-style forward/right/up to the model frame."""
    return [right, up, -fwd]


# ---------------------------------------------------------------------------------------------------- mesh building
class Mesh:
    """Indexed triangles grouped by material: {material: (positions, normals, indices)}."""

    def __init__(self):
        self.parts = {}

    def _part(self, material):
        return self.parts.setdefault(material, ([], [], []))

    def grid(self, rings, material, closed=True):
        pos, nor, idx = self._part(material)
        n = len(rings[0])
        base = len(pos)
        for ring in rings:
            for p in ring:
                pos.append(list(p))
                nor.append([0.0, 0.0, 0.0])
        for r in range(len(rings) - 1):
            for k in range(n if closed else n - 1):
                a, b = base + r * n + k, base + r * n + (k + 1) % n
                c, d = base + (r + 1) * n + (k + 1) % n, base + (r + 1) * n + k
                for tri in ((a, b, c), (a, c, d)):
                    fn = cross(sub(pos[tri[1]], pos[tri[0]]), sub(pos[tri[2]], pos[tri[0]]))
                    for v in tri:
                        nor[v] = add(nor[v], fn)
                    idx.extend(tri)
        for v in range(base, len(pos)):
            nor[v] = norm(nor[v]) if dot(nor[v], nor[v]) > 0 else [0.0, 1.0, 0.0]

    def triangles_flat(self, points, tris, material, normal=None):
        pos, nor, idx = self._part(material)
        base = len(pos)
        for k, p in enumerate(points):
            pos.append(list(p))
            nor.append(normal or [0.0, 1.0, 0.0])
        for t in tris:
            idx.extend([base + t[0], base + t[1], base + t[2]])
        if normal is None:
            acc = [[0.0, 0.0, 0.0] for _ in points]
            for t in tris:
                fn = cross(sub(points[t[1]], points[t[0]]), sub(points[t[2]], points[t[0]]))
                for v in t:
                    acc[v] = add(acc[v], fn)
            for k in range(len(points)):
                nor[base + k] = norm(acc[k]) if dot(acc[k], acc[k]) > 0 else [0.0, 1.0, 0.0]

    def polygon(self, points, material):
        fn = [0.0, 0.0, 0.0]
        for k in range(1, len(points) - 1):
            fn = add(fn, cross(sub(points[k], points[0]), sub(points[k + 1], points[0])))
        self.triangles_flat(points, [(0, k, k + 1) for k in range(1, len(points) - 1)], material, norm(fn))

    def quad(self, points, material):
        self.polygon(points, material)

    def hexa(self, c, material):
        """Eight corners indexed by three bits (a, b, c) = 4a + 2b + c of any three independent directions; each face is
        wound to face away from the centre, so the corner order's handedness does not matter."""
        centre = mul([sum(p[i] for p in c) for i in range(3)], 1.0 / 8.0)
        for f in [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]:
            pts = [c[i] for i in f]
            fn = cross(sub(pts[1], pts[0]), sub(pts[2], pts[0]))
            mid = mul([sum(p[i] for p in pts) for i in range(3)], 0.25)
            self.polygon(pts if dot(fn, sub(mid, centre)) >= 0 else pts[::-1], material)

    def box(self, centre, half, material):
        cx, cy, cz = centre
        hx, hy, hz = half
        self.hexa([[cx + sx * hx, cy + sy * hy, cz + sz * hz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)], material)

    def triangles(self):
        return sum(len(idx) // 3 for _, _, idx in self.parts.values())


def cylinder(mesh, a, b, radius, material, sides=12, cap=True, radius_b=None):
    axis = norm(sub(b, a))
    ref = [0.0, 0.0, 1.0] if abs(axis[2]) < 0.9 else [1.0, 0.0, 0.0]
    u = norm(cross(axis, ref))
    v = cross(axis, u)
    rings = []
    for end, r in ((a, radius), (b, radius if radius_b is None else radius_b)):
        rings.append([add(end, add(mul(u, r * math.cos(2 * math.pi * k / sides)), mul(v, r * math.sin(2 * math.pi * k / sides))))
                      for k in range(sides)])
    mesh.grid(rings, material)
    if cap:
        mesh.polygon(rings[0][::-1], material)
        mesh.polygon(rings[1], material)


def ear_clip(poly):
    """Triangulate a simple 2D polygon (list of (x, y)); returns index triples wound counter-clockwise."""
    area = sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1] for i in range(len(poly)))
    order = list(range(len(poly))) if area > 0 else list(range(len(poly)))[::-1]
    tris = []

    def cross2(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    guard = 0
    while len(order) > 3 and guard < 10000:
        guard += 1
        for k in range(len(order)):
            i0, i1, i2 = order[k - 1], order[k], order[(k + 1) % len(order)]
            a, b, c = poly[i0], poly[i1], poly[i2]
            if cross2(a, b, c) <= 1e-12:
                continue
            if any(cross2(a, b, poly[j]) >= 0 and cross2(b, c, poly[j]) >= 0 and cross2(c, a, poly[j]) >= 0
                   for j in order if j not in (i0, i1, i2)):
                continue
            tris.append((i0, i1, i2))
            order.pop(k)
            break
        else:
            raise SystemExit("XM-02: body profile could not be triangulated")
    tris.append(tuple(order))
    return tris


# ---------------------------------------------------------------------------------------------------- the truck
class Design:
    def __init__(self, data):
        pub, est, vis = data["published"], data["estimates"], data["visual"]
        self.wheelbase = pub["wheelbase"]["value"]
        self.tire_r = pub["tire_diameter"]["value"] / 2.0
        self.tire_w = pub["tire_width"]["value"]
        self.wheel_y = (pub["width"]["value"] - self.tire_w) / 2.0
        self.rest_y = -est["wheel_center_rest_below_datum"]["value"]
        self.arm_in = est["arm_inner_offset"]["value"]
        self.v = vis


def arch_points(cx, r, a0, a1, steps):
    return [(cx + r * math.cos(a0 + (a1 - a0) * k / steps), r * math.sin(a0 + (a1 - a0) * k / steps)) for k in range(steps + 1)]


def body_profile(d):
    """Lower body side profile in (forward, up), with the two wheel arches cut out; the arch spans are returned too."""
    v = d.v
    xa = d.wheelbase / 2.0
    r = v["arch_radius"]
    skirt = v["skirt"]
    nose_low = (v["nose"] + 0.01, 0.075)
    a_nose = math.atan2(nose_low[1], nose_low[0] - xa)
    a_skirt = math.asin(skirt / r)
    front = arch_points(xa, r, a_nose, math.pi - a_skirt, 14)
    rear = arch_points(-xa, r, a_skirt, math.pi - a_nose, 14)
    cab_front = v["cab_front"]
    pts = [nose_low] + front[1:] + rear + [(v["tail"] - 0.01, 0.075), (v["tail"], v["beltline"]),
           (cab_front, v["beltline"] + 0.005), (0.26, 0.135), (v["nose"] - 0.015, v["hood_front"] + 0.006),
           (v["nose"], v["hood_front"])]
    arch_edges = set(range(0, len(front) - 1)) | set(range(len(front), len(front) + len(rear) - 1))
    return pts, arch_edges


def half_width(d, up, cab=False):
    """Slight tumblehome: the sides draw in above the beltline."""
    v = d.v
    if cab:
        return v["cab_half_width"] + 0.03 * max(0.0, (v["roof"] - up) / (v["roof"] - v["beltline"]))
    return v["body_half_width"] - 0.012 * max(0.0, (up - 0.12) / (v["beltline"] - 0.12))


def prism(mesh, d, profile, cab, side_mat, edge_mats):
    """Extrude a side profile across the car; edge_mats(i) names each edge strip's material (None = side paint)."""
    tris = ear_clip(profile)
    for s in (-1.0, 1.0):
        pts = [P(f, s * half_width(d, u, cab), u) for f, u in profile]
        mesh.triangles_flat(pts, tris if s > 0 else [(a, c, b) for a, b, c in tris], side_mat, [s, 0.0, 0.0])
    area = sum(profile[i][0] * profile[(i + 1) % len(profile)][1] - profile[(i + 1) % len(profile)][0] * profile[i][1]
               for i in range(len(profile)))
    for i in range(len(profile)):
        a, b = profile[i], profile[(i + 1) % len(profile)]
        quad = [P(a[0], -half_width(d, a[1], cab), a[1]), P(b[0], -half_width(d, b[1], cab), b[1]),
                P(b[0], half_width(d, b[1], cab), b[1]), P(a[0], half_width(d, a[1], cab), a[1])]
        mesh.quad(quad if area > 0 else quad[::-1], edge_mats(i) or side_mat)


def build_body(d):
    v = d.v
    mesh = Mesh()
    profile, arches = body_profile(d)
    prism(mesh, d, profile, False, "XM_Paint", lambda i: "XM_Trim_Black" if i in arches else None)
    belt = v["beltline"]
    cf = v["cab_front"]
    cab = [(cf, belt), (cf - 0.11, v["roof"]), (cf - 0.20, v["roof"]), (cf - 0.235, belt)]
    prism(mesh, d, cab, True, "XM_Paint", lambda i: {0: "XM_Glass", 2: "XM_Glass", 3: "XM_Plastic_Black"}.get(i))
    # side windows, just proud of the cab sides
    win = [(cf - 0.03, belt + 0.012), (cf - 0.105, v["roof"] - 0.012), (cf - 0.19, v["roof"] - 0.012), (cf - 0.22, belt + 0.012)]
    for s in (-1.0, 1.0):
        pts = [P(f, s * (half_width(d, u, True) + 0.0015), u) for f, u in win]
        mesh.polygon(pts if s > 0 else pts[::-1], "XM_Glass")
    # fender flares: an arched band over each tire, flush with the body side and standing out over the tread
    xa = d.wheelbase / 2.0
    r0, r1 = v["arch_radius"] + 0.002, v["arch_radius"] + 0.026
    for cx in (xa, -xa):
        a0 = math.asin(v["skirt"] / r0)
        for s in (-1.0, 1.0):
            w0, w1 = s * (v["body_half_width"] - 0.002), s * (v["body_half_width"] + 0.036)
            steps = 16
            inner, outer, top_in, top_out = [], [], [], []
            for k in range(steps + 1):
                a = a0 + (math.pi - 2 * a0) * k / steps
                c, sn = math.cos(a), math.sin(a)
                inner.append(P(cx + r0 * c, w0, r0 * sn))
                outer.append(P(cx + r0 * c, w1, r0 * sn))
                top_in.append(P(cx + r1 * c, w0, r1 * sn))
                top_out.append(P(cx + r1 * c, w1, r1 * sn))
            for k in range(steps):
                under = [inner[k], outer[k], outer[k + 1], inner[k + 1]]
                over = [top_in[k], top_in[k + 1], top_out[k + 1], top_out[k]]
                face = [outer[k], top_out[k], top_out[k + 1], outer[k + 1]]
                if s < 0:
                    under, over, face = under[::-1], over[::-1], face[::-1]
                mesh.quad(under, "XM_Trim_Black")
                mesh.quad(over, "XM_Trim_Black")
                mesh.quad(face, "XM_Trim_Black")
    # hood scoop, roof light bar, headlights, tail lights, grille
    roof_mid = cf - 0.155
    mesh.box(P(0.235, 0.0, 0.147), [0.05, 0.01, 0.035], "XM_Trim_Black")                 # hood scoop
    mesh.box(P(roof_mid + 0.03, 0.0, v["roof"] + 0.008), [0.10, 0.008, 0.016], "XM_Plastic_Black")  # light bar
    for k in range(-3, 4):
        mesh.box(P(roof_mid + 0.0295, k * 0.026, v["roof"] + 0.012), [0.009, 0.006, 0.004], "XM_Light")
    bed_front, bed_back = cf - 0.25, v["tail"] + 0.02                                      # bed liner
    mesh.box(P((bed_front + bed_back) / 2.0, 0.0, belt + 0.0015), [v["body_half_width"] - 0.03, 0.0015, (bed_front - bed_back) / 2.0], "XM_Plastic_Black")
    for s in (-1.0, 1.0):
        mesh.box(P(v["nose"] + 0.003, s * 0.13, v["hood_front"] - 0.018), [0.04, 0.012, 0.004], "XM_Light")
        mesh.box(P(v["tail"] - 0.004, s * 0.15, v["beltline"] - 0.03), [0.025, 0.02, 0.004], "XM_Paint")
    mesh.box(P(v["nose"] + 0.004, 0.0, v["hood_front"] - 0.022), [0.07, 0.012, 0.003], "XM_Trim_Black")
    return mesh


def build_chassis(d):
    mesh = Mesh()
    xa = d.wheelbase / 2.0
    mesh.box(P(0.0, 0.0, 0.028), [0.09, 0.028, 0.29], "XM_Plastic_Black")             # tub
    for s in (-1.0, 1.0):
        mesh.box(P(0.0, s * 0.125, 0.04), [0.04, 0.035, 0.1], "XM_Plastic_Black")      # battery pods
        mesh.box(P(0.0, s * 0.125, 0.077), [0.042, 0.003, 0.102], "XM_Accent")         # pod straps
    cylinder(mesh, P(-0.04, -0.045, 0.075), P(-0.04, 0.045, 0.075), 0.028, "XM_Metal", 16)   # motor
    mesh.box(P(-0.04, 0.0, 0.112), [0.03, 0.008, 0.025], "XM_Plastic_Black")           # fan
    mesh.box(P(0.08, 0.0, 0.07), [0.045, 0.025, 0.035], "XM_Plastic_Black")             # ESC
    for fx in (xa, -xa):
        mesh.box(P(fx, 0.0, DIFF_Y), [0.045, 0.035, 0.03], "XM_Plastic_Black")           # differentials
        mesh.box(P(fx, 0.0, 0.085), [0.115, 0.06, 0.006], "XM_Plastic_Black")            # shock towers
        mesh.box(P(fx, 0.0, 0.14), [0.1, 0.006, 0.012], "XM_Plastic_Black")
        for s in (-1.0, 1.0):
            mesh.box(P(fx, s * 0.045, ARM_LOWER_Y + 0.02), [0.012, 0.03, 0.035], "XM_Plastic_Black")  # bulkheads
    cylinder(mesh, P(xa, 0.0, 0.0), P(-xa, 0.0, 0.0), 0.009, "XM_Metal", 8, False)          # centre driveshaft
    return mesh


def build_bumper(sign):
    """Front (sign +1) or rear (-1) bumper and skid; its own node so the damage view can push it in."""
    mesh = Mesh()
    x0, x1 = sign * 0.30, sign * 0.385
    mesh.hexa([P(x, y, u) for x in sorted((x0, x1)) for y in (-0.12, 0.12) for u in (0.0, 0.016)], "XM_Trim_Black")
    mesh.box(P(sign * 0.375, 0.0, 0.05), [0.12, 0.03, 0.012], "XM_Trim_Black")
    mesh.box(P(sign * 0.35, 0.0, 0.03), [0.03, 0.03, 0.035], "XM_Trim_Black")
    return mesh


def build_wheel(d, s):
    """Tire and wheel about the local +X axis; the wheel face looks outboard (s = -1 left, +1 right)."""
    mesh = Mesh()
    r, w = d.tire_r, d.tire_w / 2.0
    carcass = r - 0.009
    rim_r = d.v["rim_diameter"] / 2.0
    sides = 44
    profile = [(rim_r - 0.004, -w + 0.006), (carcass - 0.02, -w), (carcass - 0.004, -w + 0.006), (carcass, -w + 0.02),
               (carcass, w - 0.02), (carcass - 0.004, w - 0.006), (carcass - 0.02, w), (rim_r - 0.004, w - 0.006)]
    rings = [[[x, rr * math.cos(2 * math.pi * k / sides), rr * math.sin(2 * math.pi * k / sides)] for k in range(sides)]
             for rr, x in profile]
    mesh.grid(rings, "XM_Tire_Rubber")
    lugs = d.v["tread_lugs"]
    pitch = 2 * math.pi / lugs
    for k in range(lugs):
        for half, (x0, x1) in enumerate(((-w - 0.002, -0.004), (0.004, w + 0.002))):
            centre = pitch * (k + 0.5 * half)
            span = 0.5 * pitch

            def at(x, th, rr):
                skew = 0.9 * (abs(x) / w) * pitch * 0.6  # chevron: the lug sweeps back toward the shoulder
                a = th + skew
                return [x, rr * math.cos(a), rr * math.sin(a)]
            c = []
            for x in (x0, x1):
                for th in (centre - span / 2, centre + span / 2):
                    for rr in (carcass - 0.003, r):
                        c.append(at(x, th, rr))
            mesh.hexa(c, "XM_Tire_Rubber")
    # wheel: barrel, outer lip, six spokes, centre hub and nut, all black but the nut
    face = s * (w - 0.012)
    cylinder(mesh, [-face, 0, 0], [face, 0, 0], rim_r - 0.003, "XM_Wheel", 28, False)
    lip = [[[face + s * 0.004 * t, rr * math.cos(2 * math.pi * k / 28), rr * math.sin(2 * math.pi * k / 28)] for k in range(28)]
           for rr, t in ((rim_r - 0.003, 0.0), (rim_r + 0.003, 0.0), (rim_r + 0.003, 1.0), (rim_r - 0.012, 1.0))]
    mesh.grid(lip if s > 0 else lip[::-1], "XM_Wheel")
    for k in range(6):
        a = 2 * math.pi * k / 6
        for rr0, rr1, wdt in ((0.016, rim_r - 0.008, 0.009),):
            cy, cz = math.cos(a), math.sin(a)
            ny, nz = -cz, cy
            pts = []
            for x in (face - s * 0.012, face + s * 0.002):
                for t in (-1, 1):
                    for rr in (rr0, rr1):
                        ww = wdt * (1.4 if rr == rr0 else 0.8)
                        pts.append([x, rr * cy + t * ww * ny, rr * cz + t * ww * nz])
            mesh.hexa(pts, "XM_Wheel")
    cylinder(mesh, [face - s * 0.014, 0, 0], [face + s * 0.004, 0, 0], 0.022, "XM_Wheel", 16)
    cylinder(mesh, [face + s * 0.004, 0, 0], [face + s * 0.012, 0, 0], 0.009, "XM_Metal", 6)
    return mesh


def build_arm(d, s, upper):
    mesh = Mesh()
    length = (d.wheel_y - d.arm_in) - (0.026 if upper else 0.022)
    t = 0.006 if upper else 0.009
    root_half, tip_half = (0.028, 0.008) if upper else (0.04, 0.012)
    pts = []
    for x in (0.0, length):
        for y in (-t, t):
            hz = root_half if x == 0.0 else tip_half
            for z in (-hz, hz):
                pts.append([s * x, y, z])
    mesh.hexa(pts, "XM_Plastic_Black")
    return mesh


def build_shock():
    body = Mesh()
    cylinder(body, [0, 0.008, 0], [0, -SHOCK_BODY_LEN, 0], 0.013, "XM_Metal", 14)
    cylinder(body, [0, 0.012, 0], [0, -0.006, 0], 0.016, "XM_Plastic_Black", 14)
    coils = 9
    for k in range(coils):
        y = -0.012 - k * (SHOCK_BODY_LEN + 0.03) / coils
        cylinder(body, [0, y, 0], [0, y - 0.006, 0], 0.021, "XM_Spring", 14, False)
        cylinder(body, [0, y - 0.006, 0], [0, y, 0], 0.017, "XM_Spring", 14, False)
    rod = Mesh()
    cylinder(rod, [0, 0, 0], [0, -SHOCK_ROD_LEN, 0], 0.0045, "XM_Metal", 10)
    cylinder(rod, [0, -SHOCK_ROD_LEN + 0.012, 0], [0, -SHOCK_ROD_LEN, 0], 0.011, "XM_Plastic_Black", 10)
    cylinder(rod, [0, -0.025, 0], [0, -0.035, 0], 0.02, "XM_Spring", 14)
    return body, rod


def build_driveshaft():
    mesh = Mesh()
    cylinder(mesh, [0.0, 0, 0], [1.0, 0, 0], 0.0065, "XM_Metal", 8)
    return mesh


def build_hub(s):
    mesh = Mesh()
    mesh.box([-s * 0.03, 0.012, 0.0], [0.012, 0.035, 0.022], "XM_Plastic_Black")
    return mesh


def build(d):
    nodes = []

    def node(name, parent, translation=None, mesh=None, section=None):
        nodes.append({"name": name, "parent": parent, "translation": translation, "rotation": None, "mesh": mesh, "section": section})

    node("Chassis", ROOT_NODE, None, build_chassis(d), "chassis")
    node("Body", ROOT_NODE, None, build_body(d), "body")
    node("Bumper_F", ROOT_NODE, None, build_bumper(1.0), "bumper")
    node("Bumper_R", ROOT_NODE, None, build_bumper(-1.0), "bumper")
    shock_body, shock_rod = build_shock()
    shaft = build_driveshaft()
    for c in CORNERS:
        s = -1.0 if c[1] == "L" else 1.0
        za = -d.wheelbase / 2.0 if c[0] == "F" else d.wheelbase / 2.0
        node(c + "_ArmLower", ROOT_NODE, [s * d.arm_in, ARM_LOWER_Y, za], build_arm(d, s, False), "suspension")
        node(c + "_ArmUpper", ROOT_NODE, [s * d.arm_in, ARM_UPPER_Y, za], build_arm(d, s, True), "suspension")
        node(c + "_Shock", ROOT_NODE, [s * SHOCK_TOP[0], SHOCK_TOP[1], za], shock_body, "suspension")
        node(c + "_ShockRod", c + "_Shock", [0.0, -SHOCK_BODY_LEN, 0.0], shock_rod, "suspension")
        node(c + "_Driveshaft", ROOT_NODE, [s * DIFF_OUT_X, DIFF_Y, za], shaft, "drivetrain")
        node(c + "_Suspension", ROOT_NODE, [s * d.wheel_y, d.rest_y, za], None, "suspension")
        node(c + "_Steer", c + "_Suspension", None, None, "suspension")
        node(c + "_Hub", c + "_Steer", None, build_hub(s), "suspension")
        node(c + "_Spin", c + "_Steer", None, None, "wheel")
        node(c + "_WheelMesh", c + "_Spin", None, build_wheel(d, s), "wheel")
    return nodes


# ---------------------------------------------------------------------------------------------------- glTF writer
def write_glb(nodes):
    buffer = bytearray()
    accessors, views, meshes = [], [], []
    mesh_index = {}

    def blob(data, target):
        while len(buffer) % 4:
            buffer.append(0)
        views.append({"buffer": 0, "byteOffset": len(buffer), "byteLength": len(data), "target": target})
        buffer.extend(data)
        return len(views) - 1

    def r6(x):
        return float(struct.unpack("<f", struct.pack("<f", x))[0])

    gl_nodes = []
    for n in nodes:
        entry = {"name": n["name"]}
        if n["translation"] is not None:
            entry["translation"] = [r6(c) for c in n["translation"]]
        if n["section"]:
            entry["extras"] = {"openrc_section": n["section"]}
        if n["mesh"] is not None:
            key = id(n["mesh"])
            if key not in mesh_index:
                prims = []
                for material, (pos, nor, idx) in sorted(n["mesh"].parts.items(), key=lambda kv: MAT[kv[0]]):
                    pv = blob(b"".join(struct.pack("<3f", *p) for p in pos), 34962)
                    accessors.append({"bufferView": pv, "componentType": 5126, "count": len(pos), "type": "VEC3",
                                      "min": [r6(min(p[i] for p in pos)) for i in range(3)], "max": [r6(max(p[i] for p in pos)) for i in range(3)]})
                    pa = len(accessors) - 1
                    nv = blob(b"".join(struct.pack("<3f", *v) for v in nor), 34962)
                    accessors.append({"bufferView": nv, "componentType": 5126, "count": len(nor), "type": "VEC3"})
                    na = len(accessors) - 1
                    iv = blob(b"".join(struct.pack("<I", i) for i in idx), 34963)
                    accessors.append({"bufferView": iv, "componentType": 5125, "count": len(idx), "type": "SCALAR"})
                    prims.append({"attributes": {"POSITION": pa, "NORMAL": na}, "indices": len(accessors) - 1, "material": MAT[material]})
                meshes.append({"name": n["name"], "primitives": prims})
                mesh_index[key] = len(meshes) - 1
            entry["mesh"] = mesh_index[key]
        gl_nodes.append(entry)
    names = [n["name"] for n in nodes]
    root = {"name": ROOT_NODE, "children": [names.index(n["name"]) for n in nodes if n["parent"] == ROOT_NODE]}
    for n, entry in zip(nodes, gl_nodes):
        kids = [names.index(c["name"]) for c in nodes if c["parent"] == n["name"]]
        if kids:
            entry["children"] = kids
    gl_nodes.append(root)
    gltf = {
        "asset": {"version": "2.0", "generator": SCRIPT},
        "scene": 0, "scenes": [{"nodes": [len(gl_nodes) - 1]}],
        "nodes": gl_nodes, "meshes": meshes,
        # The flares and arch liners are open strips: their trim material is drawn from both sides.
        "materials": [dict({"name": name, "pbrMetallicRoughness": {"baseColorFactor": col, "metallicFactor": metal, "roughnessFactor": rough}},
                           **({"doubleSided": True} if name == "XM_Trim_Black" else {}))
                      for name, col, rough, metal in MATERIALS],
        "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(buffer)}],
    }
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    while len(buffer) % 4:
        buffer.append(0)
    return (struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(buffer)) + struct.pack("<II", len(js), 0x4E4F534A) + js
            + struct.pack("<II", len(buffer), 0x004E4942) + bytes(buffer))


def outputs():
    d = Design(json.loads(DESIGN.read_text(encoding="utf-8")))
    nodes = build(d)
    tris = sum(n["mesh"].triangles() for n in nodes if n["mesh"] is not None)
    return write_glb(nodes), tris


def main():
    glb, tris = outputs()
    if "--check" in sys.argv[1:]:
        if not OUT_GLB.exists() or OUT_GLB.read_bytes() != glb:
            print("XM-02 model is stale: rerun research/x-maxx/XM-02/build_model.py")
            return 1
        print("XM-02 model current")
        return 0
    OUT_GLB.parent.mkdir(parents=True, exist_ok=True)
    OUT_GLB.write_bytes(glb)
    print("wrote %s (%d triangles drawn)" % (OUT_GLB.relative_to(ROOT), tris))
    return 0


if __name__ == "__main__":
    sys.exit(main())
