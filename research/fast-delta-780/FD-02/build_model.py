#!/usr/bin/env python3
"""FD-02: the fast delta 780's visual model, generated from its design (no Blender, no third-party mesh).

Reads assets/aircraft/fast-delta-780/design.json (the same source as the FD-01 physics) and writes:

- app/assets/aircraft/fast-delta-780/fast_delta_780.glb: the game model (glTF 2.0 binary), original white/blue foam
  livery; nodes beneath `FastDelta780` at D0 (model frame +X right, +Y up, -Z nose; D0 = wing root leading edge on the
  symmetry plane at the chord plane); hinges elevon_left/right with local +X on the hinge line; a pusher `thrust_frame`
  (local +X at the nose) holding `propeller_spin` -> `propeller_rotor`; every mesh and pivot tagged with
  `extras.openrc_section`.
- assets/aircraft/fast-delta-780/model-geometry.json and app/aircraft/fast_delta_780_geometry.gd: the geometry record
  model-bindings.json points at (rest transforms read back from the written GLB, hinge ranges, app signs checked
  against the geometry, thrust frame, sections, dimensions).

    python3 research/fast-delta-780/FD-02/build_model.py           # writes the three outputs
    python3 research/fast-delta-780/FD-02/build_model.py --check   # fails if any is stale

Python standard library only; deterministic bytes. Presentation only; the physics model is FD-01. The mesh helpers and
glTF writer are TB-02's (research/twin-boom-1800/TB-02/build_model.py), copied so each generator stays standalone.
"""
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = "research/fast-delta-780/FD-02/build_model.py"
DESIGN = ROOT / "assets/aircraft/fast-delta-780/design.json"
OUT_GLB = ROOT / "app/assets/aircraft/fast-delta-780/fast_delta_780.glb"
OUT_JSON = ROOT / "assets/aircraft/fast-delta-780/model-geometry.json"
OUT_GD = ROOT / "app/aircraft/fast_delta_780_geometry.gd"
ROOT_NODE = "FastDelta780"

MATERIALS = [  # name, base colour (linear RGBA), roughness
    ("foam_white", [0.86, 0.87, 0.88, 1.0], 0.75),
    ("foam_blue", [0.03, 0.16, 0.62, 1.0], 0.65),
    ("foam_yellow", [0.95, 0.72, 0.05, 1.0], 0.7),
    ("foam_grey", [0.22, 0.24, 0.27, 1.0], 0.8),
    ("canopy", [0.02, 0.03, 0.05, 1.0], 0.15),
    ("propeller", [0.05, 0.05, 0.05, 1.0], 0.5),
    ("motor", [0.55, 0.56, 0.6, 1.0], 0.35),
]
MAT = {name: i for i, (name, _, _) in enumerate(MATERIALS)}


# ---------------------------------------------------------------------------------------------------- vector helpers
def sub(a, b): return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
def add(a, b): return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
def mul(a, k): return [a[0] * k, a[1] * k, a[2] * k]
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def norm(a):
    length = math.sqrt(dot(a, a))
    return [a[0] / length, a[1] / length, a[2] / length] if length > 0 else [0.0, 0.0, 0.0]


def model(p):
    """LE frame [x_aft, y_right, z_up] -> model frame [+X right, +Y up, +Z aft]."""
    return [p[1], p[2], p[0]]


def basis_from_x(x_axis, up_hint=(0.0, 1.0, 0.0)):
    """Orthonormal columns (x, y, z) with x along `x_axis` and y as close to `up_hint` as possible."""
    x = norm(x_axis)
    z = norm(cross(x, list(up_hint)))
    y = cross(z, x)
    return {"x": x, "y": y, "z": z}


def quat_from_basis(b):
    m = [[b["x"][r], b["y"][r], b["z"][r]] for r in range(3)]
    tr = m[0][0] + m[1][1] + m[2][2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        w, x, y, z = 0.25 * s, (m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s
    elif m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        s = math.sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2
        w, x, y, z = (m[2][1] - m[1][2]) / s, 0.25 * s, (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s
    elif m[1][1] > m[2][2]:
        s = math.sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2
        w, x, y, z = (m[0][2] - m[2][0]) / s, (m[0][1] + m[1][0]) / s, 0.25 * s, (m[1][2] + m[2][1]) / s
    else:
        s = math.sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2
        w, x, y, z = (m[1][0] - m[0][1]) / s, (m[0][2] + m[2][0]) / s, (m[1][2] + m[2][1]) / s, 0.25 * s
    return [x, y, z, w]


def basis_from_quat(q):
    x, y, z, w = q
    rows = ((1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)),
            (2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)),
            (2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)))
    return {axis: [rows[r][c] for r in range(3)] for c, axis in enumerate("xyz")}


def to_local(p, pivot, basis):
    d = sub(p, pivot)
    return [dot(d, basis["x"]), dot(d, basis["y"]), dot(d, basis["z"])]


# ---------------------------------------------------------------------------------------------------- mesh building
class Mesh:
    """Indexed triangles grouped by material: {material: (positions, normals, indices)}."""

    def __init__(self):
        self.parts = {}

    def _part(self, material):
        return self.parts.setdefault(material, ([], [], []))

    def grid(self, rings, material, closed=True, smooth=True):
        """Quad strip between consecutive rings (each a list of points, same count); rings closed around."""
        pos, nor, idx = self._part(material)
        n = len(rings[0])
        if not smooth:
            for r in range(len(rings) - 1):
                for k in range(n if closed else n - 1):
                    a, b = rings[r][k], rings[r][(k + 1) % n]
                    c, d = rings[r + 1][(k + 1) % n], rings[r + 1][k]
                    self.quad([a, b, c, d], material)
            return
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

    def polygon(self, points, material):
        """Flat convex-ish cap (fan), wound as given."""
        pos, nor, idx = self._part(material)
        fn = [0.0, 0.0, 0.0]
        for k in range(1, len(points) - 1):
            fn = add(fn, cross(sub(points[k], points[0]), sub(points[k + 1], points[0])))
        fn = norm(fn)
        base = len(pos)
        for p in points:
            pos.append(list(p))
            nor.append(fn)
        for k in range(1, len(points) - 1):
            idx.extend([base, base + k, base + k + 1])

    def quad(self, points, material):
        self.polygon(points, material)

    def box(self, centre, half, material, xform=None):
        cx, cy, cz = centre
        hx, hy, hz = half
        corners = [[cx + sx * hx, cy + sy * hy, cz + sz * hz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
        if xform:
            corners = [xform(p) for p in corners]
        faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
        for f in faces:
            self.polygon([corners[i] for i in f], material)

    def triangles(self):
        return sum(len(idx) // 3 for _, _, idx in self.parts.values())

    def bounds(self):
        pts = [p for pos, _, _ in self.parts.values() for p in pos]
        return [min(p[i] for p in pts) for i in range(3)] + [max(p[i] for p in pts) for i in range(3)]


def airfoil(xc, thickness=0.12, camber=0.03, peak=0.3):
    """Upper and lower surface heights (fractions of chord) at chord fraction xc (NACA 4-digit form)."""
    t = 5 * thickness * (0.2969 * math.sqrt(xc) - 0.126 * xc - 0.3516 * xc ** 2 + 0.2843 * xc ** 3 - 0.1036 * xc ** 4)
    yc = camber / peak ** 2 * (2 * peak * xc - xc * xc) if xc < peak else camber / (1 - peak) ** 2 * (1 - 2 * peak + 2 * peak * xc - xc * xc)
    return yc + t, yc - t


def chord_ring(xc0, xc1, samples, thickness, camber):
    """Closed section outline between two chord fractions: upper surface forward to aft, lower aft to forward."""
    xs = [xc0 + (xc1 - xc0) * (0.5 - 0.5 * math.cos(math.pi * k / samples)) for k in range(samples + 1)]
    upper = [(x, airfoil(x, thickness, camber)[0]) for x in xs]
    lower = [(x, airfoil(x, thickness, camber)[1]) for x in reversed(xs)]
    ring = upper + lower[1:-1] if xc0 == 0.0 else upper + lower
    return ring


class Design:
    def __init__(self, d):
        self.d = d
        w = d["wing"]
        self.b, self.cr, self.ct = w["span"], w["root_chord"], w["tip_chord"]
        self.tan_le = math.tan(math.radians(w["le_sweep_deg"]))
        self.dihedral = math.radians(w["dihedral_deg"])
        self.thick = w["thickness_ratio"]
        self.hinge_xc = 1.0 - w["elevon_chord_fraction"]

    def chord(self, y):
        return self.cr - (self.cr - self.ct) * abs(y) / (self.b / 2)

    def wing_point(self, y, xc, zc):
        """LE frame point on the swept wing at span y, chord fraction xc, height zc (fraction of chord)."""
        c = self.chord(y)
        return [abs(y) * self.tan_le + xc * c, y, abs(y) * math.tan(self.dihedral) + zc * c]


def wing_panel(design, mesh, y0, y1, xc0, xc1, material, xform, steps=1, cap0=True, cap1=True, samples=12):
    """Loft of the (near-symmetric reflex) section between chord fractions xc0..xc1 over span y0..y1."""
    rings = []
    for k in range(steps + 1):
        y = y0 + (y1 - y0) * k / steps
        ring = chord_ring(xc0, xc1, samples, design.thick, 0.01)
        pts = [xform(model(design.wing_point(y, xc, zc))) for xc, zc in ring]
        if y1 < y0:
            pts = pts[::-1]
        rings.append(pts)
    mesh.grid(rings, material)
    if cap0:
        mesh.polygon(rings[0][::-1], material)
    if cap1:
        mesh.polygon(rings[-1], material)


def flat_surface(mesh, outline_le, material, thickness, xform, axis="z"):
    """A thin plate: `outline_le` is a planar polygon in the LE frame; extruded ±thickness/2 along LE z (or y)."""
    off = [0.0, 0.0, thickness / 2] if axis == "z" else [0.0, thickness / 2, 0.0]
    top = [xform(model(add(p, off))) for p in outline_le]
    bot = [xform(model(sub(p, off))) for p in outline_le]
    mesh.polygon(top, material)
    mesh.polygon(bot[::-1], material)
    n = len(outline_le)
    for k in range(n):
        mesh.polygon([bot[k], bot[(k + 1) % n], top[(k + 1) % n], top[k]], material)


def cylinder(mesh, a, b, radius, material, xform, sides=10, cap=True):
    axis = norm(sub(b, a))
    ref = [0.0, 0.0, 1.0] if abs(axis[2]) < 0.9 else [1.0, 0.0, 0.0]
    u = norm(cross(axis, ref))
    v = cross(axis, u)
    rings = []
    for end in (a, b):
        rings.append([xform(add(end, add(mul(u, radius * math.cos(2 * math.pi * k / sides)), mul(v, radius * math.sin(2 * math.pi * k / sides)))))
                      for k in range(sides)])
    mesh.grid(rings, material)
    if cap:
        mesh.polygon(rings[0][::-1], material)
        mesh.polygon(rings[1], material)


def superellipse_ring(x, half_w, bottom, top, n=16, exponent=2.2):
    """Centre-body cross-section in the LE frame at station x (rounded)."""
    cz, hz = (top + bottom) / 2, (top - bottom) / 2
    pts = []
    for k in range(n):
        a = 2 * math.pi * k / n
        c, s = math.cos(a), math.sin(a)
        y = half_w * math.copysign(abs(c) ** (2 / exponent), c)
        z = cz + hz * math.copysign(abs(s) ** (2 / exponent), s)
        pts.append([x, y, z])
    return pts


def body_top(stations, x):
    """Centre-body top height at station x (linear between stations)."""
    for a, b in zip(stations, stations[1:]):
        if a[0] <= x <= b[0]:
            t = (x - a[0]) / (b[0] - a[0])
            return a[3] + (b[3] - a[3]) * t
    return stations[-1][3]


# ---------------------------------------------------------------------------------------------------- the aircraft
def build(d):
    design = Design(d)
    ident = lambda p: p
    nodes = []  # (name, parent, translation, rotation quat or None, mesh or None, section)

    def node(name, parent, translation=None, basis=None, mesh=None, section=None):
        nodes.append(dict(name=name, parent=parent, translation=translation, rotation=quat_from_basis(basis) if basis else None,
                          mesh=mesh, section=section))

    # Wing: fixed panels to the hinge line, the trailing edge inboard of the elevons, elevons on hinges; blue tips.
    ein, eout = d["wing"]["elevon_y"]
    half = design.b / 2
    hinge_xc = design.hinge_xc
    articulations = {}
    for side, sign in (("left", -1), ("right", 1)):
        wing = Mesh()
        wing_panel(design, wing, 0.0, sign * (half - 0.05), 0.0, hinge_xc, "foam_white", ident, steps=6, cap0=False, cap1=False)
        wing_panel(design, wing, sign * (half - 0.05), sign * half, 0.0, hinge_xc, "foam_blue", ident, steps=1, cap0=False)
        wing_panel(design, wing, 0.0, sign * ein, hinge_xc, 1.0, "foam_white", ident, steps=1, cap0=False)
        wing_panel(design, wing, sign * eout, sign * half, hinge_xc, 1.0, "foam_blue", ident, steps=1)
        # Yellow chevron on the upper surface (livery): a thin raised band along the 30 % chord line.
        band = [design.wing_point(sign * yy, xc, 0.5 * design.thick + 0.012) for yy, xc in ((0.1, 0.3), (half - 0.06, 0.3), (half - 0.06, 0.4), (0.1, 0.4))]
        flat_surface(wing, band if sign > 0 else band[::-1], "foam_yellow", 0.001, ident)
        node(f"wing_{side}", ROOT_NODE, mesh=wing, section=f"wing_{side}")
        # Elevon hinge: on the hinge line at mid-thickness, local +X toward model +X (right) on both sides.
        mid = sum(airfoil(hinge_xc, design.thick, 0.01)) / 2
        p_in = model(design.wing_point(sign * ein, hinge_xc, mid))
        p_out = model(design.wing_point(sign * eout, hinge_xc, mid))
        axis = sub(p_out, p_in) if sign > 0 else sub(p_in, p_out)
        basis = basis_from_x(axis)
        pivot = mul(add(p_in, p_out), 0.5)
        elevon = Mesh()
        wing_panel(design, elevon, sign * ein, sign * eout, hinge_xc, 1.0, "foam_blue", lambda p, pv=pivot, bs=basis: to_local(p, pv, bs), steps=2)
        node(f"elevon_{side}_hinge", ROOT_NODE, pivot, basis, section=f"wing_{side}")
        node(f"elevon_{side}", f"elevon_{side}_hinge", mesh=elevon, section=f"wing_{side}")
        articulations[f"elevon_{side}_hinge"] = dict(surface_node=f"elevon_{side}", range=d["throws_deg"]["elevon"],
                                                     positive="trailing edge down", section=f"wing_{side}", sense="te_down")

    # Centre body with a tinted canopy; the motor sits in its tail.
    stations = d["fuselage"]["stations"]
    body = Mesh()
    rings = [superellipse_ring(x, max(w, 0.003), bot, top) for x, w, bot, top in stations[1:]]
    body.grid([[model(p) for p in r] for r in rings], "foam_white")
    tip = model([stations[0][0], 0.0, stations[0][2]])
    first = [model(p) for p in rings[0]]
    for k in range(len(first)):
        body.polygon([tip, first[(k + 1) % len(first)], first[k]], "foam_grey")
    body.polygon([model(p) for p in rings[-1]], "foam_grey")
    # Grey belly skid under the flat part of the centre body (belly landings; the Home scene rests the model on it).
    skid_x0, skid_x1, skid_z = -0.16, 0.06, -0.0415
    body.box(model([(skid_x0 + skid_x1) / 2, 0.0, skid_z]), [0.012, 0.0015, (skid_x1 - skid_x0) / 2], "foam_grey")
    node("fuselage", ROOT_NODE, mesh=body, section="core")
    canopy = Mesh()
    cx0, cx1 = d["fuselage"]["canopy"]["x"]
    hw, hh = d["fuselage"]["canopy"]["half_width"], d["fuselage"]["canopy"]["height"]
    crings = []
    for k in range(9):
        t = k / 8
        x = cx0 + (cx1 - cx0) * t
        bump = math.sin(math.pi * t) ** 0.6
        hgt = max(0.002, hh * bump)
        wdt = max(0.005, hw * (0.55 + 0.45 * bump))
        base = body_top(stations, x) - 0.006
        crings.append([model([x, wdt * math.cos(math.pi * j / 10), base + hgt * math.sin(math.pi * j / 10)]) for j in range(11)])
    canopy.grid(crings, "canopy", closed=False)
    node("canopy", ROOT_NODE, mesh=canopy, section="canopy")

    # Two fixed fins on the wing's upper surface.
    fn = d["fins"]
    sweep = math.tan(math.radians(fn["le_sweep_deg"]))
    for side, sign in (("left", -1), ("right", 1)):
        y = sign * fn["y"]
        root_le, root_te = fn["root_le_x"], fn["root_le_x"] + fn["root_chord"]
        tip_le = root_le + fn["height"] * sweep
        tip_te = tip_le + fn["tip_chord"]
        z0, z1 = fn["root_z"], fn["root_z"] + fn["height"]
        fin = Mesh()
        flat_surface(fin, [[root_le, y, z0], [root_te, y, z0], [tip_te, y, z1], [tip_le, y, z1]], "foam_blue", fn["thickness"], ident, axis="y")
        node(f"fin_{side}", ROOT_NODE, mesh=fin, section="vertical_tail")

    # Motor (fixed, engine section) and the pusher rotor.
    th = d["thrust"]
    hub = model(th["hub"])
    motor = Mesh()
    cylinder(motor, model([th["hub"][0] - 0.035, 0.0, th["hub"][2]]), model([th["hub"][0] - 0.008, 0.0, th["hub"][2]]), 0.0165, "motor", ident, sides=14)
    node("motor", ROOT_NODE, mesh=motor, section="engine")
    thrust_basis = {"x": [0.0, 0.0, -1.0], "y": [0.0, 1.0, 0.0], "z": [1.0, 0.0, 0.0]}  # local +X at the nose (-Z)
    node("thrust_frame", ROOT_NODE, hub, thrust_basis)
    node("propeller_spin", "thrust_frame", section="propeller")
    rotor = Mesh()
    r = th["propeller_diameter"] / 2
    # Spinner cone pointing aft (local -X), hub and two twisted blades in the local Y-Z plane.
    cylinder(rotor, [0.008, 0.0, 0.0], [-0.003, 0.0, 0.0], 0.011, "propeller", ident, sides=12)
    cone_ring = [[-0.003, 0.011 * math.cos(2 * math.pi * k / 12), 0.011 * math.sin(2 * math.pi * k / 12)] for k in range(12)]
    for k in range(12):
        rotor.polygon([[-0.022, 0.0, 0.0], cone_ring[(k + 1) % 12], cone_ring[k]], "propeller")
    for blade in (1, -1):
        sections = []
        for k in range(9):
            rr = 0.009 + (r - 0.009) * k / 8
            chord = 0.016 * (1.0 - 0.55 * (k / 8) ** 1.6) + 0.004
            pitch = math.atan2(0.1524, 2 * math.pi * max(rr, 0.02)) * blade  # 6 in pitch
            t = 0.003 * (1 - 0.6 * k / 8)
            sec = []
            for (cx, cz) in ((-0.5, 0.0), (0.0, t), (0.5, 0.0), (0.0, -t)):
                lx = cz * math.cos(pitch) - cx * chord * math.sin(pitch)
                lt = cx * chord * math.cos(pitch) + cz * math.sin(pitch)
                sec.append([lx, blade * rr, lt])
            sections.append(sec)
        rotor.grid(sections, "propeller")
        rotor.polygon(sections[-1] if blade > 0 else sections[-1][::-1], "propeller")
    node("propeller_rotor", "propeller_spin", mesh=rotor, section="propeller")
    articulations["propeller_spin"] = dict(surface_node="propeller_rotor", section="propeller")
    return nodes, articulations


# ---------------------------------------------------------------------------------------------------- glTF writer
def write_glb(nodes):
    buffer = bytearray()
    accessors, views, meshes = [], [], []

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
        if n["rotation"] is not None:
            entry["rotation"] = [r6(c) for c in n["rotation"]]
        if n["section"]:
            entry["extras"] = {"openrc_section": n["section"]}
        if n["mesh"] is not None:
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
            entry["mesh"] = len(meshes) - 1
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
        "materials": [{"name": name, "pbrMetallicRoughness": {"baseColorFactor": col, "metallicFactor": 0.0, "roughnessFactor": rough}}
                      for name, col, rough in MATERIALS],
        "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(buffer)}],
    }
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    while len(buffer) % 4:
        buffer.append(0)
    return (struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(buffer)) + struct.pack("<II", len(js), 0x4E4F534A) + js
            + struct.pack("<II", len(buffer), 0x004E4942) + bytes(buffer))


# ---------------------------------------------------------------------------------------------------- geometry record
def compile_geometry(d, nodes, articulations, glb):
    sys.path.insert(0, str(ROOT / "research/f4u-corsair/F4U-04"))
    import preflight_glb as glb_reader  # stdlib glTF reader shared with F4U-04/05 and X8-02
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "model.glb"
        path.write_bytes(glb)
        gltf, binary = glb_reader.read_glb(path)
    by_name = {n["name"]: n for n in gltf["nodes"]}
    parent = {gltf["nodes"][c]["name"]: n["name"] for n in gltf["nodes"] for c in n.get("children", [])}

    def rest(name):
        n = by_name[name]
        return {"node": name, "parent": parent[name], "rest_translation": n.get("translation", [0.0, 0.0, 0.0]),
                "rest_basis": basis_from_quat(n.get("rotation", [0.0, 0.0, 0.0, 1.0]))}

    def edge_sense(hinge, surface, kind):
        """Model-frame motion of the surface's trailing-edge vertices when the hinge turns +1 degree about local +X."""
        mesh = gltf["meshes"][by_name[surface]["mesh"]]
        verts = sorted({v for p in mesh["primitives"] for v in glb_reader.accessor_values(gltf, binary, p["attributes"]["POSITION"])})
        basis = basis_from_quat(by_name[hinge]["rotation"])
        pivot = by_name[hinge]["translation"]
        to_model = lambda v: add(pivot, add(add(mul(basis["x"], v[0]), mul(basis["y"], v[1])), mul(basis["z"], v[2])))
        aft = max(to_model(v)[2] for v in verts)
        edge = [v for v in verts if to_model(v)[2] >= aft - 0.002]
        c, s = math.cos(math.radians(1.0)), math.sin(math.radians(1.0))
        turned = lambda v: [v[0], c * v[1] - s * v[2], s * v[1] + c * v[2]]
        component = 1 if kind == "te_down" else 0  # te_down: model Y must fall; te_right: model X must rise
        delta = sum(to_model(turned(v))[component] - to_model(v)[component] for v in edge) / len(edge)
        return delta, len(edge)

    out = {}
    for name, record in articulations.items():
        if name == "propeller_spin":
            out[name] = dict(rest(name), surface_node=record["surface_node"], section="propeller",
                             positive="pusher: clockwise viewed from behind looking toward the nose (right-handed about +X = thrust direction)")
            continue
        delta, count = edge_sense(name, record["surface_node"], record["sense"])
        if record["sense"] == "te_down":
            assert delta < -1e-5, f"{name}: +1 degree about local +X must lower the trailing edge ({delta})"
            app_sign = -1  # app convention: positive = trailing edge up
        else:
            assert delta > 1e-5, f"{name}: +1 degree about local +X must swing the trailing edge right ({delta})"
            app_sign = 1  # app rudder convention as the Turbo Lumber: positive = trailing edge right
        out[name] = dict(rest(name), surface_node=record["surface_node"], range_deg=[-record["range"], record["range"]], app_sign=app_sign,
                         positive=record["positive"], section=record["section"],
                         range_source="assets/aircraft/fast-delta-780/design.json throws_deg elevon (estimated; equal to the physical elevon end point)",
                         sense_check={"model_axis": "Y" if record["sense"] == "te_down" else "X", "edge_motion_m_per_plus_1_deg": round(delta, 9),
                                      "edge_vertices": count})
    thrust = dict(rest("thrust_frame"), spin_node="propeller_spin", axis_local="+X",
                  propeller_diameter={"value": d["thrust"]["propeller_diameter"], "unit": "m", "kind": "manual",
                                      "source": "design.json: 7x6 propeller, drawn at its nominal diameter"},
                  layout="pusher: the propeller turns behind the centre body's tail, aft of the wing root; thrust points at the nose")
    sections = {n["name"]: n["extras"]["openrc_section"] for n in gltf["nodes"] if "mesh" in n}
    pts = []
    for n in gltf["nodes"]:
        if "mesh" in n:
            for p in gltf["meshes"][n["mesh"]]["primitives"]:
                a = gltf["accessors"][p["attributes"]["POSITION"]]
                pts.append((a["min"], a["max"]))
    tris = sum(gltf["accessors"][p["indices"]]["count"] // 3 for m in gltf["meshes"] for p in m["primitives"])
    w = d["wing"]
    return {
        "schema": "openrc-fast-delta-model v1",
        "catalog_id": d["catalog_id"],
        "revision": d["revision"] + "-" + hashlib.sha256(glb).hexdigest()[:12],
        "source_alias": "Fast delta 780 procedural model %s (OpenRC original, %s)" % (d["revision"], SCRIPT),
        "status": "Generated presentation: two elevons, two fixed fins, a pusher propeller, no gear.",
        "generator": SCRIPT,
        "units": "m",
        "axes": {"nose": "-Z", "right": "+X", "up": "+Y"},
        "datum": {"origin": "D0: wing root leading edge on the symmetry plane at the chord plane (design.json frame)",
                  "physics_le_frame": "[x_aft, y_right, z_up] = [z, x, y]; the physics LE datum is D0, so AirplaneBuilder.datum() = (0, 0)"},
        "inputs": {"design_sha256": hashlib.sha256(DESIGN.read_bytes()).hexdigest(), "glb_sha256": hashlib.sha256(glb).hexdigest()},
        "dimensions": {"span_m": w["span"], "length_m": round(max(p[1][2] for p in pts) - min(p[0][2] for p in pts), 6),
                       "height_m": round(max(p[1][1] for p in pts) - min(p[0][1] for p in pts), 6),
                       "propeller_diameter_m": d["thrust"]["propeller_diameter"], "triangles": tris},
        "articulations": out,
        "elevon_presentation": {"app_convention": "surface angles in degrees, + = trailing edge up (app/physics/control_surfaces.gd)",
                                "render": "elevon_right = elevator + aileron_right, elevon_left = elevator + aileron_left (app/aircraft/imported_model.gd role_degrees)"},
        "sections": sections,
        "thrust": thrust,
    }


def outputs():
    d = json.loads(DESIGN.read_text(encoding="utf-8"))
    nodes, articulations = build(d)
    glb = write_glb(nodes)
    data = compile_geometry(d, nodes, articulations, glb)
    text = json.dumps(data, indent=1, ensure_ascii=False, allow_nan=False) + "\n"
    script = (f"# Generated by {SCRIPT}; do not edit.\n# Presentation measurements only; physical validation is separate.\n"
              "extends RefCounted\n\nconst DATA := " + json.dumps(data, ensure_ascii=False, indent="\t", allow_nan=False) + "\n")
    return {OUT_GLB: glb, OUT_JSON: text.encode("utf-8"), OUT_GD: script.encode("utf-8")}, data


def main():
    files, data = outputs()
    if "--check" in sys.argv:
        stale = [p for p, b in files.items() if not p.exists() or p.read_bytes() != b]
        if stale:
            sys.exit("stale: " + ", ".join(p.name for p in stale) + f" (run {SCRIPT})")
        print("fast delta 780 model, geometry record and script are up to date")
        return
    for p, b in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b)
        print("wrote", p.relative_to(ROOT).as_posix())
    print(json.dumps(data["dimensions"]), {k: v.get("app_sign") for k, v in data["articulations"].items()})


if __name__ == "__main__":
    main()
