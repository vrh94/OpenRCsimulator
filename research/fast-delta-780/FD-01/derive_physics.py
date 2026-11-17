#!/usr/bin/env python3
"""FD-01: physics for the fast delta 780 (step 16), an original swept flying-wing pusher in the FunJet speed-wing class.

Reads the authored design (assets/aircraft/fast-delta-780/design.json, also the source of the visual model) and the
estimates in inputs.json. Writes the ideal-bus file app/data/aircraft/fast_delta_780.json and the finite 4S 2200 mAh
pack variant app/data/aircraft/battery/fast_delta_780_4s_pack.json.

Method: textbook build-up on the tailless law the Skywalker X8 introduced (X8-04): DATCOM/Helmbold swept-wing lift
slope, strip integrals over the tapered swept planform for the pitch, roll and elevon derivatives (the same three
equal-area strips per side the simulator uses), Gilruth/Munk body destabilisation, thin-airfoil elevon effectiveness and
camber couple, fins sized to carry the directional stability (as X8-06 does for its winglets), the X8-05 pusher, X8-07
hand launch (no landing gear) and X8-08 EPO tolerant hull. Unlike X8-06 nothing here is flight identified: every
coefficient is an estimate on an original design.

    python3 research/fast-delta-780/FD-01/derive_physics.py           # writes both files and prints a summary
    python3 research/fast-delta-780/FD-01/derive_physics.py --check   # fails if either is stale

Python standard library only.
"""
import copy
import hashlib
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "research/aircraft-standardization"))
from physical_identity import validate_physical_identity  # noqa: E402

HERE = Path(__file__).resolve().parent
SCRIPT = "research/fast-delta-780/FD-01/derive_physics.py"
DESIGN = ROOT / "assets/aircraft/fast-delta-780/design.json"
OUTPUT = ROOT / "app/data/aircraft/fast_delta_780.json"
PACK_OUTPUT = ROOT / "app/data/aircraft/battery/fast_delta_780_4s_pack.json"
PACK_ID = "lipo-4s1p-2200-30c-class"
PACK_FILE = ROOT / "app/data/batteries/packs" / (PACK_ID + ".json")
G = 9.80665
RHO = 1.225
N_STATIONS = 3  # Aero.WING_STATIONS_PER_SIDE
STEPS = 4000    # spanwise integration steps per semi-span


def q(value, unit, kind="derived", source=""):
    return dict(value=value, unit=unit, kind=kind, source=source or SCRIPT + ": estimated geometry/textbook derivation; not flight identified")


def flap_tau(fraction):
    """Thin-airfoil plain-flap lift effectiveness for a flap of `fraction` of the chord."""
    theta = math.acos(2 * fraction - 1)
    return 1 - (theta - math.sin(theta)) / math.pi


def flap_moment(fraction):
    """Thin-airfoil quarter-chord pitching moment per radian of a plain flap of `fraction` of the chord."""
    theta = math.acos(2 * fraction - 1)
    return -0.5 * math.sin(theta) * (1 - math.cos(theta))


def seq_sum(values):
    total = 0.0
    for value in values:
        total += value
    return total


def tensor(items, cg):
    j = [0.0] * 6
    for it in items:
        m, p, s = it["mass"]["value"], it["position"]["value"], it["size"]["value"]
        x, y, z = -(p[0] - cg[0]), p[1] - cg[1], -(p[2] - cg[2])
        j[0] += m * (y * y + z * z + (s[1] ** 2 + s[2] ** 2) / 12)
        j[1] += m * (x * x + z * z + (s[0] ** 2 + s[2] ** 2) / 12)
        j[2] += m * (x * x + y * y + (s[0] ** 2 + s[1] ** 2) / 12)
        j[3] -= m * x * y
        j[4] -= m * x * z
        j[5] -= m * y * z
    return j


def strip_edges(h, cr, ct):
    """Equal-area strip edges on one semi-span, root -> tip (aircraft_data.gd station_edges)."""
    slope = (ct - cr) / h
    total = cr * h + slope * h * h / 2
    edges = [0.0]
    for k in range(N_STATIONS):
        target = total * (k + 1) / N_STATIONS
        edges.append(h if k == N_STATIONS - 1 else (-cr + math.sqrt(cr * cr + 2 * slope * target)) / slope)
    return edges


def _vortex_z(px, py, x1, y1, x2, y2):
    """z-velocity at (px, py) from a unit vortex segment in the wing plane (aircraft_data.gd _vortex_z)."""
    r1x, r1y, r2x, r2y = px - x1, py - y1, px - x2, py - y2
    cross = r1x * r2y - r1y * r2x
    if abs(cross) < 1e-14:
        return 0.0
    n1, n2 = math.hypot(r1x, r1y), math.hypot(r2x, r2y)
    return ((x2 - x1) * (r1x / n1 - r2x / n2) + (y2 - y1) * (r1y / n1 - r2y / n2)) / (4.0 * math.pi * cross)


def strip_map(b, cr, ct, cla):
    """The simulator's tailless strip law (aircraft_data.gd station_ys/_induced_map): three equal-area strips per side
    with the Weissinger influence matrix, the strip slope a0 that reproduces CLa, and E = (I + a0·K)^-1.
    Returns (ys left tip -> right tip, a0, E row-major)."""
    h = b / 2
    right = strip_edges(h, cr, ct)
    edges = [-e for e in reversed(right[1:])] + right
    slope = (ct - cr) / h
    centres = []
    for k in range(N_STATIONS):
        y0, y1 = right[k], right[k + 1]
        area = lambda y: cr * y + slope * y * y / 2
        moment = lambda y: cr * y * y / 2 + slope * y ** 3 / 3
        centres.append((moment(y1) - moment(y0)) / (area(y1) - area(y0)))
    ys = [-y for y in reversed(centres)] + centres
    n = len(ys)
    chord = [cr + (ct - cr) * abs(y) / h for y in ys]
    kmap = [[0.0] * n for _ in range(n)]
    for i in range(n):
        px, py = chord[i] / 2, ys[i]
        for j in range(n):
            a, bb = edges[j], edges[j + 1]
            wz = _vortex_z(px, py, 1e5, a, 0.0, a) + _vortex_z(px, py, 0.0, a, 0.0, bb) + _vortex_z(px, py, 0.0, bb, 1e5, bb)
            kmap[i][j] = -wz * 0.5 * chord[j] - (1 / (2 * math.pi) if i == j else 0.0)

    def inverse(a0):
        m = [[(1.0 if i == j else 0.0) + a0 * kmap[i][j] for j in range(n)] + [1.0 if i == j else 0.0 for j in range(n)] for i in range(n)]
        for col in range(n):
            piv = max(range(col, n), key=lambda r: abs(m[r][col]))
            m[col], m[piv] = m[piv], m[col]
            d = m[col][col]
            m[col] = [x / d for x in m[col]]
            for r in range(n):
                if r != col:
                    f = m[r][col]
                    m[r] = [x - f * y for x, y in zip(m[r], m[col])]
        return [row[n:] for row in m]

    lo, hi = 0.1, 50.0
    for _ in range(80):
        a0 = 0.5 * (lo + hi)
        e = inverse(a0)
        if a0 * seq_sum(seq_sum(row) for row in e) / n < cla:
            lo = a0
        else:
            hi = a0
    a0 = 0.5 * (lo + hi)
    return ys, a0, inverse(a0)


def derive(inputs=None):
    i = copy.deepcopy(inputs if inputs is not None else json.loads((HERE / "inputs.json").read_text(encoding="utf-8")))
    d = json.loads(DESIGN.read_text(encoding="utf-8"))
    v = lambda name: i["estimates"][name]["value"]
    eq = lambda name: q(v(name), i["estimates"][name]["unit"], "estimated", i["estimates"][name]["source"])
    dsrc = "assets/aircraft/fast-delta-780/design.json (original design d1)"
    w, fin, th = d["wing"], d["fins"], d["thrust"]
    b, cr, ct = w["span"], w["root_chord"], w["tip_chord"]
    h = b / 2
    s = b * (cr + ct) / 2
    c, ar, lam = s / b, b * b / s, ct / cr
    tan_le = math.tan(math.radians(w["le_sweep_deg"]))
    chord_at = lambda y: cr - (cr - ct) * abs(y) / h
    x_le = lambda y: abs(y) * tan_le
    x_frac = lambda y, f: x_le(y) + f * chord_at(y)
    mac = 2 / 3 * cr * (1 + lam + lam * lam) / (1 + lam)
    y_mac = b / 6 * (1 + 2 * lam) / (1 + lam)
    x_ac = x_frac(y_mac, 0.25)  # the wing's aerodynamic centre: quarter chord of the MAC
    tan_half = (x_frac(h, 0.5) - x_frac(0.0, 0.5)) / h
    tan_quarter = (x_frac(h, 0.25) - x_frac(0.0, 0.25)) / h
    mass, cg_x = d["flying_mass_kg"], d["cg_aft_of_root_le_m"]

    # Inventory and the balancing residue that puts the CG at the design station.
    items = []
    for it in i["inventory"]:
        item = dict(id=it["id"], name=it["name"], mass=q(it["mass_kg"], "kg", "estimated", i["inventory_source"]),
                    position=q(list(it["position"]), "m", "estimated", i["inventory_source"] + "; LE frame"),
                    size=q(list(it["size"]), "m", "estimated", i["inventory_source"] + "; aligned box inertia envelope"))
        if "energy_source" in it:
            item["energy_source"] = it["energy_source"]
        items.append(item)
    residue = mass - seq_sum(it["mass"]["value"] for it in items)
    if residue < 0.001:
        raise ValueError("FD-01: inventory leaves no positive balancing mass")
    xb = (mass * cg_x - seq_sum(it["mass"]["value"] * it["position"]["value"][0] for it in items)) / residue
    if not -0.3 <= xb <= 0.3:
        raise ValueError("FD-01: virtual balancing station %.3f m outside the centre body" % xb)
    items.append(dict(id="ballast_reference", name="virtual reference-build balancing mass (wiring, connectors, hardware)",
                      mass=q(residue, "kg", source=SCRIPT + ": design flying mass minus the estimated component inventory; NOT measured hardware"),
                      position=q([xb, 0.0, 0.0], "m", source=SCRIPT + ": residual moment for the design CG; NOT measured ballast"),
                      size=q([0.06, 0.04, 0.03], "m", "estimated", "FD-01 virtual balancing mass envelope (centre body interior)")))
    cg = [seq_sum(it["mass"]["value"] * it["position"]["value"][k] for it in items) / mass for k in range(3)]
    j = tensor(items, cg)

    # Lift slope: DATCOM/Helmbold for a swept wing (half-chord sweep).
    kappa = v("section_slope_factor")
    aw = 2 * math.pi * ar / (2 + math.sqrt(ar * ar / (kappa * kappa) * (1 + tan_half * tan_half) + 4))
    # Body: Gilruth/Munk destabilisation about the wing's aerodynamic centre (moves the neutral point forward).
    stations = d["fuselage"]["stations"]
    body_len = stations[-1][0] - stations[0][0]
    body_w = 2 * max(row[1] for row in stations)
    dcma_body = v("fuselage_munk_factor") * body_w * body_w * body_len / (s * c)
    x_np = x_ac - dcma_body / aw * c
    xarp = cg_x  # moments about the design CG (the loader requires a stable, negative Cma about the ARP)
    cla = aw

    # Strip integrals over the semi-span (both sides by symmetry).
    dy = h / STEPS
    ys = [(k + 0.5) * dy for k in range(STEPS)]
    ein, eout = w["elevon_y"]
    covered = lambda y: ein <= y <= eout
    washout = math.radians(v("washout_deg"))
    edges = strip_edges(h, cr, ct)
    station_x, coverage, twist = [], [], []
    for k in range(N_STATIONS):
        seg = [y for y in ys if edges[k] <= y < edges[k + 1]]
        area = seq_sum(chord_at(y) * dy for y in seg)
        station_x.append(seq_sum(chord_at(y) * x_frac(y, 0.25) * dy for y in seg) / area)
        coverage.append(seq_sum(chord_at(y) * dy for y in seg if covered(y)) / area)
        centre = seq_sum(chord_at(y) * y * dy for y in seg) / area
        twist.append(-washout * centre / h)  # linear washout, nose-down toward the tip
    mean_twist = seq_sum(twist) / N_STATIONS
    twist = [t - mean_twist for t in twist]  # zero mean: CL0 carries the mean incidence

    tau = flap_tau(w["elevon_chord_fraction"]) * v("control_efficiency")
    km = flap_moment(w["elevon_chord_fraction"]) * v("control_efficiency")
    twist_at = lambda y: twist[min(N_STATIONS - 1, max(k for k in range(N_STATIONS) if edges[k] <= y))]
    two = 2.0  # both semi-spans
    cl0 = aw * (-v("wing_zero_lift_angle") + mean_twist)
    cm0 = (v("wing_section_moment") * two * seq_sum(chord_at(y) ** 2 * dy for y in ys) / (s * c)
           - two * seq_sum(aw * twist_at(y) * chord_at(y) * (x_frac(y, 0.25) - xarp) * dy for y in ys) / (s * c)
           - cl0 * (x_np - xarp) / c)  # the mean zero-lift lift acts at the neutral point
    clde = two * seq_sum(aw * tau * chord_at(y) * dy for y in ys if covered(y)) / s
    cmde = (-two * seq_sum(aw * tau * chord_at(y) * (x_frac(y, 0.25) - xarp) * dy for y in ys if covered(y)) / (s * c)
            + km * two * seq_sum(chord_at(y) ** 2 * dy for y in ys if covered(y)) / (s * c))
    clda = -seq_sum(aw * tau * chord_at(y) * y * dy for y in ys if covered(y)) / (s * b)
    clda_each = seq_sum(aw * tau * chord_at(y) * dy for y in ys if covered(y)) / s
    cmda_each = cmde / 2  # each elevon carries half the symmetric pitch effectiveness
    clp = -two * 2 * aw * seq_sum(chord_at(y) * y * y * dy for y in ys) / (s * b * b)
    cma = -cla * (x_np - xarp) / c  # about the ARP at the CG: the static margin
    # Pitch damping and CLq from the simulator's own strip law (strip stations shifted to the oracle's neutral point,
    # exactly as the loader does), so the two flight regimes agree. A continuous strip integral gives about twice the
    # damping and DATCOM's swept-wing formula about 2.5 times: tailless pitch damping is uncertain.
    s_ys, a0, e_map = strip_map(b, cr, ct, cla)
    n_all = len(s_ys)
    x0 = list(reversed(station_x)) + station_x  # left tip ... right tip
    rows = [seq_sum(row) for row in e_map]
    shift = (-cma * n_all * c - seq_sum(a0 * rows[i] * (x0[i] - xarp) for i in range(n_all))) / seq_sum(a0 * r for r in rows)
    arm = [x0[i] + shift - cg_x for i in range(n_all)]
    cmq = -2 / (c * c * n_all) * a0 * seq_sum(e_map[i][k] * arm[k] * arm[i] for i in range(n_all) for k in range(n_all))
    clq = 2 / (c * n_all) * a0 * seq_sum(e_map[i][k] * arm[k] for i in range(n_all) for k in range(n_all))
    cmq_continuous = -two * 2 * aw * seq_sum(chord_at(y) * (x_frac(y, 0.25) - cg_x) ** 2 * dy for y in ys) / (s * c * c)

    # Lateral: two fins sized by the end-plated slope; the centre element carries the whole directional stability
    # (body destabilisation folded into its effective slope), as X8-06 does for the winglets.
    hv = fin["height"]
    sv_each = hv * (fin["root_chord"] + fin["tip_chord"]) / 2
    sv = 2 * sv_each
    xv = fin["root_le_x"] + 0.25 * fin["root_chord"] + 0.5 * hv * math.tan(math.radians(fin["le_sweep_deg"]))
    zv = fin["root_z"] + 0.45 * hv
    av_geom = 2 * math.pi * 0.9 * (v("fin_endplate_factor") * hv * hv / sv_each) / (2 + math.sqrt(4 + (v("fin_endplate_factor") * hv * hv / sv_each) ** 2)) * v("fin_pressure_ratio")
    lv = xv - cg_x
    side_area = seq_sum((stations[k + 1][0] - stations[k][0]) * ((stations[k][3] - stations[k][2]) + (stations[k + 1][3] - stations[k + 1][2])) / 2
                        for k in range(len(stations) - 1))
    cnb_body = -v("fuselage_yaw_factor") * side_area / s * body_len / b
    cnb = av_geom * sv / s * lv / b + cnb_body
    if cnb <= 0.005:
        raise ValueError("FD-01: fins too small for directional stability (Cnb %.4f)" % cnb)
    av = cnb * s * b / (sv * lv)  # effective slope at the fins' arm
    cyb_v = -av * sv / s
    body_side = -0.1  # small slim-body side-force slope per radian (as TB-01's pod)
    vs = math.sqrt(2 * mass * G / (RHO * s * v("CL_max")))
    speed = 1.5 * vs
    # The lateral lift-dependent terms use the cruise lift: the CL that trims with the elevons neutral.
    cl_cruise = cl0 + cm0 / ((x_np - cg_x) / c)
    if not 0.05 < cl_cruise < v("CL_max"):
        raise ValueError("FD-01: neutral-elevon trim CL %.3f outside the flight envelope" % cl_cruise)
    clb_wing = -4 * cl_cruise * tan_quarter * seq_sum(chord_at(y) * y * dy for y in ys) / (s * b)
    cd0 = v("skin_drag_coefficient") + v("excrescence_drag_area") / s
    k = 1 / (math.pi * v("span_efficiency") * ar)
    values = dict(CL0=cl0, CLa=cla, CLq=clq, CLde=clde, CLda_each=0.0, CD0=cd0, CL_minD=v("minimum_drag_lift"), k_induced=k,
                  CDda_each=v("control_drag_roll"), CDdr=0.0, CDde=v("control_drag_elevon"),
                  CYb=cyb_v + body_side, CYp=2 * cyb_v * (zv - cg[2]) / b, CYr=-2 * cyb_v * lv / b, CYdr=0.0,
                  Clb=clb_wing + cyb_v * zv / b, Clp=clp, Clr=cl_cruise / 4 - 2 * lv * (zv - cg[2]) / b ** 2 * cyb_v,
                  Clda_right=clda, Clda_left=-clda, Cldr=0.0,
                  Cm0=cm0, Cma=cma, Cmq=cmq, Cmde=cmde, Cmda_each=0.0,
                  Cnb=cnb, Cnp=-cl_cruise / 8, Cnr=2 * (lv / b) ** 2 * cyb_v - cd0 / 3,
                  Cnda_right=-v("adverse_yaw_factor") * cl_cruise * clda, Cnda_left=v("adverse_yaw_factor") * cl_cruise * clda, Cndr=0.0)
    unitless = ["CL0", "CD0", "CL_minD", "k_induced", "Cm0"]
    coefficients = {name: q(val, "1" if name in unitless else "1/rad",
                            source=SCRIPT + ": DATCOM/Helmbold swept wing, strip integrals on the tapered swept planform, thin-airfoil elevons, Gilruth body, fin build-up on the design d1 geometry")
                    for name, val in values.items()}
    for name in ["Cmq", "CLq"]:
        coefficients[name]["source"] = SCRIPT + ": the simulator's tailless strip law (three equal-area strips per side, Weissinger induced map, stations at the oracle's neutral point); a continuous strip integral gives Cmq %.2f, DATCOM's swept-wing formula about 2.5 times the strip law: uncertain" % cmq_continuous
    surfaces = {
        "wing_station_incidence": q(twist, "rad", "estimated", SCRIPT + ": %.1f° linear washout on the strips (root → tip), zero mean" % v("washout_deg")),
        "body_cy_beta": q(body_side, "1/rad", "estimated", SCRIPT + ": CYβ minus the fins' side force (slim centre body)"),
        "body_crossflow_area": q(v("crossflow_efficiency") * v("crossflow_drag") * side_area, "m2", source=SCRIPT + ": Allen-Perkins crossflow η·c_d·S_side on the design centre-body side area %.4f m2" % side_area),
        "wing_body_cl_beta": q(clb_wing, "1/rad", source=SCRIPT + ": Clβ minus the fins' rolling term: the swept wing's dihedral effect at the neutral-elevon cruise lift"),
        "attached_limit": eq("attached_limit"), "tail_local_limit": eq("tail_local_limit"), "tail_stall_end": eq("tail_stall_end"),
        "tail_CD0": eq("tail_CD0"), "tail_k": eq("tail_k"), "tail_CD90": q(1.11 + 0.018 * ar, "1"),
        "vertical": dict(area=q(sv, "m2", "derived", dsrc + ": both fins, trapezoids on the wing"), position=q([xv, 0.0, zv], "m"),
                         lift_slope=q(av, "1/rad", source=SCRIPT + ": effective slope that carries Cnβ (fins %.3f/rad end-plated, body destabilisation folded in) at the fins' arm" % av_geom),
                         control_effectiveness=q(0.0, "1", source=SCRIPT + ": no rudder: fixed fins"), incidence=q(0.0, "rad", source=dsrc + ": fins without toe")),
        "tailless": dict(station_x=q(station_x, "m", source=SCRIPT + ": area-weighted quarter-chord stations of the three equal-area strips (root → tip) on the swept planform"),
                         elevon_coverage=q(coverage, "1", source=SCRIPT + ": elevon share of each strip's area (elevons %.2f-%.2f m)" % (ein, eout)),
                         elevon_chord_fraction=q(w["elevon_chord_fraction"], "1", "estimated", dsrc)),
    }

    hub = th["hub"]
    prop_r = th["propeller_diameter"] / 2
    propulsion = copy.deepcopy(i["propulsion"])
    propulsion["id"] = "propulsion_main"
    motor = propulsion["motor"]
    motor["resistance_ohm"] = eq("motor_resistance")
    motor["no_load_current_a"] = eq("motor_no_load_current")
    voltage = v("bus_voltage")
    propulsion["battery"]["voltage_v"] = eq("bus_voltage")
    motor["no_load_context"] = dict(voltage_v=eq("bus_voltage"),
                                    rpm=q((voltage - v("motor_resistance") * v("motor_no_load_current")) * motor["kv_rpm_per_volt"]["value"], "rpm", source=SCRIPT + ": Kv·(V − R·I0)"),
                                    temperature_c=eq("winding_temperature"))
    prop = propulsion["propeller"]
    prop["rotating_inertia"] = eq("rotor_inertia")
    prop["thrust_angles"] = q([th["downthrust_deg"], th["right_thrust_deg"]], "deg", "estimated", dsrc + ": motor axis along the body axis")
    prop["thrust_line_offset"] = q([hub[0] - cg[0], hub[1] - cg[1], hub[2] - cg[2]], "m",
                                   source=SCRIPT + ": design propeller hub minus inventory CG; pusher aft of the CG")

    # Crash hull: wing tips, nose and body belly, pusher disc bottom, fin tops, elevon root corners. No landing gear.
    tip_x = x_le(h)
    fin_tip_te = fin["root_le_x"] + hv * math.tan(math.radians(fin["le_sweep_deg"])) + fin["tip_chord"]
    probes = [
        ("probe_wing_left_tip", [tip_x, -h, 0.0], "left_wing_tip"),
        ("probe_wing_right_tip", [tip_x, h, 0.0], "right_wing_tip"),
        ("probe_wing_left_tip_te", [tip_x + ct, -h, 0.0], "left_wing_tip"),
        ("probe_wing_right_tip_te", [tip_x + ct, h, 0.0], "right_wing_tip"),
        ("probe_nose", [stations[0][0], 0.0, stations[0][2]], "nose"),
        ("probe_propeller_bottom", [hub[0], 0.0, hub[2] - prop_r], "propeller"),
        ("probe_fin_left_top", [fin_tip_te, -fin["y"], fin["root_z"] + hv], "fin_top"),
        ("probe_fin_right_top", [fin_tip_te, fin["y"], fin["root_z"] + hv], "fin_top"),
        ("probe_tail", [stations[-1][0], 0.0, stations[-1][2]], "tail_end"),
    ]
    for ident, row in (("probe_belly_nose", stations[2]), ("probe_belly_forward", stations[3]), ("probe_belly_centre", stations[4]),
                       ("probe_belly_wing", stations[5]), ("probe_belly_aft", stations[6])):
        probes.append((ident, [row[0], 0.0, row[2]], "belly"))

    tolerance_src = "EPO foam airframe, the MoonRunner X99's X8-08 estimate (five times the shared 2.5 J/kg); drop tests pending"
    throws = d["throws_deg"]
    rate = lambda value, why: q(value, "1", "estimated", why)
    model = dict(
        format="openrc-aircraft v2", physical_identity_version=1, id="fast-delta-780",
        description="EXPERIMENTAL FD-01: original fast swept flying-wing EPO pusher in the 0.78 m speed-wing class (FunJet class figures: 783 mm, 14.5 dm2, 875 g, 4S). Geometry/textbook tailless aerodynamics, estimated inventory, borrowed APC 7x6 propeller map, estimated electric drive; no landing gear (hand launch), tougher foam airframe. Not flight validated.",
        convention_id="openrc-le-frd-v1",
        capabilities=dict(controls="elevon", gear="locked_up", propulsion_layout="single_pusher", energy="fixed_voltage",
                          damage="tolerant_hull", flaps="not_simulated", airframe_layout="tailless"),
        frames=dict(le_frame="D0: [x_aft,y_right,z_up] = [model Z,model X,model Y], metres; wing root leading edge on the symmetry plane", body="FRD about inventory CG"),
        reference=dict(wing_area=q(s, "m2", "derived", dsrc + ": straight taper, span x (root + tip) / 2 (class 14.5 dm2)"),
                       wing_span=q(b, "m", "manual", "FunJet class span 783 mm (retail listings); design d1 0.78 m"),
                       mean_chord=q(c, "m", source=SCRIPT + ": S/b; MAC %.4f m at %.3f m semi-span" % (mac, y_mac)),
                       aero_reference_point=q([xarp, 0.0, 0.0], "m", source=SCRIPT + ": the design CG station on the chord plane; the wing's aerodynamic centre (MAC quarter chord) is at %.4f m" % x_ac),
                       planform="tapered", root_chord=q(cr, "m", "estimated", dsrc), tip_chord=q(ct, "m", "estimated", dsrc)),
        balance=dict(plan_cg=q(cg, "m", source=SCRIPT + ": design longitudinal CG (%.0f mm aft of the root LE, %.1f %% MAC static margin), inventory-derived lateral/vertical CG" % (cg_x * 1000, 100 * (x_np - cg_x) / c)),
                     firewall=q([hub[0] - 0.05, 0.0, hub[2]], "m", "estimated", dsrc + ": motor mount in the centre body's tail"),
                     configuration="virtual-balanced-reference-v1", cg_tolerance=q(0.001, "m", "estimated", "FD-01 reference build tolerance")),
        inventory=items,
        start=dict(level_speed=q(speed, "m/s", source=SCRIPT + ": 1.5 times clean 1-g stall (%.1f m/s) at the design mass and estimated CL_max: a firm hand-launch speed for a loaded speed wing" % vs)),
        controls=dict(surface_ids={"elevon_left": "surface_elevon_left", "elevon_right": "surface_elevon_right"},
                      max_throw=dict(aileron=q(throws["aileron"], "deg", "estimated", dsrc + ": speed-wing roll share of the elevon travel"),
                                     elevator=q(throws["elevator"], "deg", "estimated", dsrc + ": speed-wing pitch share of the elevon travel"),
                                     elevon=q(throws["elevon"], "deg", "estimated", dsrc + ": full elevon servo travel")),
                      servo_full_throw_time=eq("servo_full_throw_time"),
                      rates=dict(normal=dict(aileron=rate(1.0, "full mixed throw on the normal rate"), elevator=rate(1.0, "full mixed throw on the normal rate"),
                                             aileron_expo=rate(0.35, "common speed-wing expo"), elevator_expo=rate(0.35, "common speed-wing expo")))),
        aero=dict(source=SCRIPT + ": geometry/textbook estimate on the tailless strip law, no identified aerodynamics", conventions=i["conventions"], coefficients=coefficients,
                  reference_coefficients=dict(CLadot=q(0.0, "1/rad", source=SCRIPT + ": tailless: no tail downwash lag")),
                  envelope=dict(CL_max=eq("CL_max"), CL_min=eq("CL_min"), stall_blend_width=eq("stall_blend_width"), CD90=q(1.11 + 0.018 * ar, "1"),
                                sideslip_blend=q([15, 25], "deg", "estimated", "FD-01 linear-to-sine sideslip blend (fleet value)")),
                  surfaces=surfaces),
        propulsion=propulsion,
        crash_hull=q([p for _, p, _ in probes], "m", source=SCRIPT + ": design wing tips, nose and belly stations, pusher disc bottom, fin tops, body tail"),
        crash_hull_ids=[ident for ident, _, _ in probes],
        crash_hull_components=[name for _, _, name in probes],
        crash_tolerance=dict(terminal_specific_energy=q(12.5, "J/kg", "estimated", tolerance_src),
                             crash_depth=q(0.1, "m", "estimated", "a small foam nose can bury about 10 cm in turf (X8-08 estimate scaled)"),
                             presentation_durability=q(4.0, "1", "estimated", "EPO against balsa/ply crash presentation divisor (X8-08 estimate)")),
        plausibility=dict(mass_range=q([0.75, 1.05], "kg", "estimated", "FunJet class: flying weight 875 g (retail listings); 3S-4S builds"),
                          inertia_reference=q(j[:3], "kg·m2", source=SCRIPT + ": same inventory box estimate; self-reference is no independent plausibility evidence")))
    validate_physical_identity(model)
    summary = dict(mass=mass, cg=cg, inertia=j, wing_area=s, aspect_ratio=ar, mac=mac, x_ac=x_ac, x_np=x_np, stall_speed=vs, start_speed=speed,
                   static_margin=(x_np - cg_x) / c, trim_CL_at_zero_elevon=cl_cruise, cruise_speed=math.sqrt(2 * mass * G / (RHO * s * cl_cruise)),
                   CD0=cd0, Cmq_continuous=cmq_continuous, strip_shift=shift, virtual_mass=residue, virtual_station=xb, tau=tau, km=km, station_x=station_x, coverage=coverage, twist=twist,
                   **{key: values[key] for key in ["CL0", "CLa", "Cm0", "Cma", "CLde", "Cmde", "Clda_right", "Clp", "Cmq", "CLq", "Cnb", "Clb", "CYb"]})
    return model, summary


def pack_variant(model):
    """The same airframe and inventory on the finite 4S 2200 mAh class pack (pack_ecm)."""
    pack_bytes = PACK_FILE.read_bytes()
    pack = json.loads(pack_bytes.decode("utf-8"))
    battery_item = next(item for item in model["inventory"] if item["id"] == "battery_main")
    if pack["mass_kg"]["value"] != battery_item["mass"]["value"]:
        raise ValueError("FD-01: pack mass must equal the battery_main inventory mass")
    variant = copy.deepcopy(model)
    variant["description"] = model["description"].replace("estimated electric drive", "estimated electric drive on the finite 4S 2200 mAh class pack (pack_ecm)")
    variant["capabilities"]["energy"] = "pack_ecm"
    src = SCRIPT + " pack variant: "
    est = lambda value, unit, source: q(value, unit, "estimated", src + source)
    der = lambda value, unit, source: q(value, unit, "derived", src + source)
    variant["propulsion"]["battery"] = {
        "kind": "pack_ecm",
        "pack": {"id": PACK_ID, "sha256": hashlib.sha256(pack_bytes).hexdigest()},
        "mount_inventory_id": "battery_main",
        "initial_soc": est(1.0, "1", "freshly charged pack at rest; the session may override it"),
        "auxiliary_current_a": est(0.4, "A", "flight controller, receiver, FPV camera, video transmitter and two servos, about 5 W through an assumed 80 % BEC, referred to a 15 V pack; not measured"),
        "cooling_airflow_fraction": est(0.1, "1", "enclosed foam bay under the hatch; ram air past the pack assumed 10 % of airspeed (fleet value)"),
        "weak_cell": {"capacity_factor": der(1.0, "1", "new balanced pack"), "resistance_factor": der(1.0, "1", "new balanced pack"),
                      "soc_offset": der(0.0, "1", "balanced charge")},
    }
    variant["propulsion"]["esc"] = {
        "kind": "ideal_motoring", "command_mapping": "identity",
        "low_voltage_cutoff": {
            "mode": "soft", "cell_detection": "auto",
            "detection_max_cell_v": est(4.3, "V", "Betaflight-style 4.30 V/cell auto-detection maximum (BAT-00 F7, fleet value)"),
            "cutoff_per_cell_v": est(3.2, "V", "common 60 A ESC default 3.2 V/cell; installed setting unknown"),
            "soft_limit": est(0.5, "1", "soft cutoff to 50 % output (fleet value)"),
            "soft_ramp_s": est(3.0, "s", "soft cutoff ramp (fleet value)"),
            "debounce_s": est(0.5, "s", "brief punch-out sag does not trip (fleet value)"),
            "recovery": "throttle_reset",
            "reset_throttle_max": der(0.05, "1", "app/input/rc_input.gd ARM_THROTTLE 0.05: the same idle-stick threshold"),
            "voltage_filter_s": est(0.1, "s", "ESC voltage low-pass (fleet value)"),
        },
    }
    validate_physical_identity(variant)
    return variant


def render(model):
    # .gitattributes checks aircraft JSON out with CRLF; write those exact bytes so hashes match any checkout.
    return (json.dumps(model, indent=2, ensure_ascii=False, allow_nan=False) + "\n").replace("\n", "\r\n").encode("utf-8")


def main():
    model, summary = derive()
    outputs = {OUTPUT: render(model), PACK_OUTPUT: render(pack_variant(model))}
    if "--check" in sys.argv:
        stale = [p for p, data in outputs.items() if not p.exists() or p.read_bytes() != data]
        for p in stale:
            print("stale or missing: %s (run %s)" % (p.relative_to(ROOT).as_posix(), SCRIPT))
        if not stale:
            print("FD-01 physics data current (%d files)" % len(outputs))
        return 1 if stale else 0
    if "--summary" not in sys.argv:
        for p, data in outputs.items():
            p.write_bytes(data)
            print("wrote", p.relative_to(ROOT).as_posix())
    print(json.dumps({k: ([round(x, 4) for x in v] if isinstance(v, list) else round(v, 5)) for k, v in summary.items()}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
