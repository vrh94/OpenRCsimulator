#!/usr/bin/env python3
"""TB-01: physics for the twin-boom 1800 (step 15), an original twin-boom EPO pusher in the Skyhunter 1800 class.

Reads the authored design (assets/aircraft/twin-boom-1800/design.json, also the source of the visual model) and the
estimates in inputs.json. Writes the ideal-bus file app/data/aircraft/twin_boom_1800.json and the finite 4S 5000 mAh
pack variant app/data/aircraft/battery/twin_boom_1800_4s_pack.json.

Method: the TT-07 (Turbo Lumber Evolution) wing-tail derivation (Helmbold finite wing and tails, thin-airfoil flap
effectiveness, strip and tail-volume derivatives) on a straight-tapered wing, with the X8-05 pusher, X8-07 hand launch
(no landing gear) and X8-08 EPO tolerant hull. Every number is an estimate or a class figure; not flight identified.

    python3 research/twin-boom-1800/TB-01/derive_physics.py           # writes both files and prints a summary
    python3 research/twin-boom-1800/TB-01/derive_physics.py --check   # fails if either is stale

Python standard library only.
"""
import copy
import hashlib
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "research/aero"))
from aileron_effectiveness import derive_effectiveness  # noqa: E402
sys.path.insert(0, str(ROOT / "research/aircraft-standardization"))
from physical_identity import validate_physical_identity  # noqa: E402

HERE = Path(__file__).resolve().parent
SCRIPT = "research/twin-boom-1800/TB-01/derive_physics.py"
DESIGN = ROOT / "assets/aircraft/twin-boom-1800/design.json"
OUTPUT = ROOT / "app/data/aircraft/twin_boom_1800.json"
PACK_OUTPUT = ROOT / "app/data/aircraft/battery/twin_boom_1800_4s_pack.json"
PACK_ID = "lipo-4s1p-5000-30c-class"
PACK_FILE = ROOT / "app/data/batteries/packs" / (PACK_ID + ".json")
G = 9.80665
RHO = 1.225


def q(value, unit, kind="derived", source=""):
    return dict(value=value, unit=unit, kind=kind, source=source or SCRIPT + ": estimated geometry/textbook derivation; not flight identified")


def slope(ar, kappa=0.9):
    """Helmbold finite-surface lift slope per radian."""
    return 2 * math.pi * kappa * ar / (2 + math.sqrt(4 + ar * ar))


def flap_tau(fraction):
    """Thin-airfoil plain-flap effectiveness for a flap of `fraction` of the chord."""
    theta = math.acos(2 * fraction - 1)
    return 1 - (theta - math.sin(theta)) / math.pi


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


def derive(inputs=None):
    i = copy.deepcopy(inputs if inputs is not None else json.loads((HERE / "inputs.json").read_text(encoding="utf-8")))
    d = json.loads(DESIGN.read_text(encoding="utf-8"))
    v = lambda name: i["estimates"][name]["value"]
    eq = lambda name: q(v(name), i["estimates"][name]["unit"], "estimated", i["estimates"][name]["source"])
    dsrc = "assets/aircraft/twin-boom-1800/design.json (original design d1)"
    w, st, fin, th = d["wing"], d["stabilizer"], d["fins"], d["thrust"]
    b, cr, ct = w["span"], w["root_chord"], w["tip_chord"]
    s = b * (cr + ct) / 2
    c, ar = s / b, b * b / s
    chord_at = lambda y: cr - (cr - ct) * abs(y) / (b / 2)
    mac = 2 / 3 * cr * (1 + ct / cr + (ct / cr) ** 2) / (1 + ct / cr)
    xarp = 0.25 * cr  # straight (unswept) quarter-chord line
    mass, cg_x = d["flying_mass_kg"], d["cg_aft_of_root_le_m"]

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
        raise ValueError("TB-01: inventory leaves no positive balancing mass")
    xb = (mass * cg_x - seq_sum(it["mass"]["value"] * it["position"]["value"][0] for it in items)) / residue
    if not -0.43 <= xb <= 0.3:
        raise ValueError("TB-01: virtual balancing station %.3f m outside the pod" % xb)
    items.append(dict(id="ballast_reference", name="virtual reference-build balancing mass (wiring, connectors, hardware)",
                      mass=q(residue, "kg", source=SCRIPT + ": design flying mass minus the estimated component inventory; NOT measured hardware"),
                      position=q([xb, 0.0, -0.07], "m", source=SCRIPT + ": residual moment for the design CG; NOT measured ballast"),
                      size=q([0.1, 0.06, 0.04], "m", "estimated", "TB-01 virtual balancing mass envelope (pod interior)")))
    cg = [seq_sum(it["mass"]["value"] * it["position"]["value"][k] for it in items) / mass for k in range(3)]
    j = tensor(items, cg)

    # Tail surfaces. The vertical element is one centreline surface carrying both fins (as the X8's winglets).
    sh, bh = st["chord"] * st["span"], st["span"]
    xh, zh = st["le_x"] + 0.25 * st["chord"], st["z"]
    hv = fin["height"]
    sv_each = hv * (fin["root_chord"] + fin["tip_chord"]) / 2
    sv = 2 * sv_each
    xv = fin["root_le_x"] + 0.25 * fin["root_chord"] + 0.5 * hv * math.tan(math.radians(fin["le_sweep_deg"]))
    zv = fin["root_z"] + 0.45 * hv
    arp_up = 0.0  # D0 is on the root chord plane; the quarter-chord line is at the datum height on the centreline

    aw = slope(ar, v("section_slope_factor"))
    ah_free = slope(bh * bh / sh) * v("tail_pressure_ratio")
    deps = 2 * aw / (math.pi * ar)
    ah = ah_free * (1 - deps)
    # Each fin's slope from its own end-plated aspect ratio; the slope applies to their combined area.
    av = slope(v("fin_endplate_factor") * hv * hv / sv_each) * v("fin_pressure_ratio")
    tau_e = flap_tau(st["elevator_chord"] / st["chord"]) * v("control_efficiency")
    tau_a = flap_tau(w["aileron_chord_fraction"]) * v("control_efficiency")
    tau_r = flap_tau(fin["rudder_chord"] / fin["root_chord"]) * v("control_efficiency")
    ceh, cev = tau_e / (1 - deps), tau_r / v("fin_pressure_ratio")
    iw = math.radians(w["incidence_deg"]) - v("wing_zero_lift_angle")
    ih = (v("tail_incidence") - 2 * aw * iw / (math.pi * ar)) / (1 - deps)
    cla = aw + ah * sh / s
    cl0 = aw * iw + ah * sh / s * ih
    clde = ah * sh / s * ceh
    lh, lv = xh - xarp, xv - xarp
    ain, aout = w["aileron_y"]
    n = 200
    dy = (aout - ain) / n
    ys = [ain + (k + 0.5) * dy for k in range(n)]
    clda_each = aw * tau_a * seq_sum(chord_at(y) * dy for y in ys) / s
    clda = -aw * tau_a * seq_sum(chord_at(y) * y * dy for y in ys) / (s * b)
    cyb_v, cydr = -av * sv / s, av * sv / s * cev
    cm0 = v("wing_section_moment") - ah * sh / s * lh / c * ih
    cd0 = v("skin_drag_coefficient") + v("excrescence_drag_area") / s
    k = 1 / (math.pi * v("span_efficiency") * ar)
    vs = math.sqrt(2 * mass * G / (RHO * s * v("CL_max")))
    speed = 1.4 * vs
    clref = mass * G / (0.5 * RHO * speed * speed * s)
    gamma = math.radians(w["dihedral_deg"])
    values = dict(CL0=cl0, CLa=cla, CLq=2 * ah_free * sh / s * (xh - cg_x) / c,
                  CLde=clde, CLda_each=clda_each, CD0=cd0, CL_minD=v("minimum_drag_lift"), k_induced=k,
                  CDda_each=v("control_drag_aileron"), CDdr=v("control_drag_rudder"), CDde=v("control_drag_elevator"),
                  CYb=cyb_v - v("body_side_slope"), CYp=2 * cyb_v * (zv - cg[2]) / b, CYr=-2 * cyb_v * (xv - cg_x) / b, CYdr=cydr,
                  Clb=-aw * gamma / 4 + cyb_v * (zv - cg[2]) / b - v("high_wing_dihedral_effect"),
                  Clp=-aw / 6, Clr=clref / 4 - 2 * (xv - cg_x) * (zv - cg[2]) / b ** 2 * cyb_v,
                  Clda_right=clda, Clda_left=-clda, Cldr=cydr * (zv - arp_up) / b,
                  Cm0=cm0, Cma=-ah * sh / s * lh / c, Cmq=-2 * ah_free * sh / s * ((xh - cg_x) / c) ** 2,
                  Cmde=-clde * lh / c, Cmda_each=-clda_each * (0.4 * c - 0.15 * c) / c,
                  Cnb=av * sv / s * lv / b, Cnp=-clref / 8, Cnr=2 * ((xv - cg_x) / b) ** 2 * cyb_v - cd0 / 3,
                  Cnda_right=-v("adverse_yaw_factor") * clref * clda, Cnda_left=v("adverse_yaw_factor") * clref * clda,
                  Cndr=-cydr * lv / b)
    coefficients = {name: q(val, "1" if name in ["CL0", "CD0", "CL_minD", "k_induced", "Cm0"] else "1/rad",
                            source=SCRIPT + ": Helmbold finite wing/tails, thin-airfoil flap effectiveness, strip and tail-volume derivatives on the design d1 geometry (TT-07 method)")
                    for name, val in values.items()}
    effectiveness = derive_effectiveness(s, b, cla, ah * sh / s, clda, [cr, ct])
    surfaces = {
        "wing_aileron_effectiveness": q(effectiveness, "1", source=SCRIPT + ": research/aero/aileron_effectiveness.py on the tapered strips; matches Clda_right; model consistency, not flight calibration"),
        "wing_section_cm_ac": eq("wing_section_moment"),
        "attached_limit": eq("attached_limit"), "tail_local_limit": eq("tail_local_limit"), "tail_stall_end": eq("tail_stall_end"),
        "tail_CD0": eq("tail_CD0"), "tail_k": eq("tail_k"), "tail_CD90": q(1.11 + 0.018 * ar, "1"),
        "horizontal": dict(area=q(sh, "m2", "derived", dsrc + ": stabilizer chord x span"), position=q([xh, 0.0, zh], "m"),
                           lift_slope=q(ah, "1/rad"), control_effectiveness=q(ceh, "1"), incidence=q(ih, "rad"), downwash_gradient=q(deps, "1")),
        "vertical": dict(area=q(sv, "m2", "derived", dsrc + ": both fins, trapezoids above the stabilizer"), position=q([xv, 0.0, zv], "m"),
                         lift_slope=q(av, "1/rad"), control_effectiveness=q(cev, "1"), incidence=q(0.0, "rad")),
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

    # Crash hull: wing tips, nose and pod belly, pusher disc bottom, tail extremities. No landing gear.
    tip_z = (b / 2) * math.tan(gamma)
    tip_le = 0.25 * (cr - ct)
    pod = d["pod"]["stations"]
    fin_tip_te = fin["root_le_x"] + hv * math.tan(math.radians(fin["le_sweep_deg"])) + fin["tip_chord"]
    probes = [
        ("probe_wing_left_tip", [tip_le, -b / 2, tip_z], "left_wing_tip"),
        ("probe_wing_right_tip", [tip_le, b / 2, tip_z], "right_wing_tip"),
        ("probe_nose", [pod[0][0], 0.0, pod[0][2]], "nose"),
        ("probe_propeller_bottom", [hub[0], 0.0, hub[2] - prop_r], "propeller"),
        ("probe_stabilizer_left_tip", [st["le_x"] + st["chord"], -st["span"] / 2, st["z"]], "left_stab_tip"),
        ("probe_stabilizer_right_tip", [st["le_x"] + st["chord"], st["span"] / 2, st["z"]], "right_stab_tip"),
        ("probe_fin_left_top", [fin_tip_te, -fin["y"], fin["root_z"] + hv], "fin_top"),
        ("probe_fin_right_top", [fin_tip_te, fin["y"], fin["root_z"] + hv], "fin_top"),
        ("probe_boom_left_end", [d["booms"]["x"][1], -d["booms"]["y"], d["booms"]["z"] - d["booms"]["radius"]], "tail_end"),
        ("probe_boom_right_end", [d["booms"]["x"][1], d["booms"]["y"], d["booms"]["z"] - d["booms"]["radius"]], "tail_end"),
    ]
    for ident, row in (("probe_belly_nose", pod[2]), ("probe_belly_forward", pod[3]), ("probe_belly_centre", pod[4]),
                       ("probe_belly_wing", pod[5]), ("probe_belly_aft", pod[6])):
        probes.append((ident, [row[0], 0.0, row[2]], "belly"))

    tolerance_src = "EPO foam airframe, the MoonRunner X99's X8-08 estimate (five times the shared 2.5 J/kg); drop tests pending"
    model = dict(
        format="openrc-aircraft v2", physical_identity_version=1, id="twin-boom-1800",
        description="EXPERIMENTAL TB-01: original twin-boom EPO pusher in the 1.8 m long-range FPV class (Skyhunter 1800 class figures: 1.8 m, 36 dm2, 920 Kv, 11x7). Geometry/textbook aerodynamics, estimated inventory, borrowed APC 11x7 propeller map, estimated electric drive; no landing gear (hand launch), tougher foam airframe. Not flight validated.",
        convention_id="openrc-le-frd-v1",
        capabilities=dict(controls="conventional", gear="locked_up", propulsion_layout="single_pusher", energy="fixed_voltage",
                          damage="tolerant_hull", flaps="not_simulated"),
        frames=dict(le_frame="D0: [x_aft,y_right,z_up] = [model Z,model X,model Y], metres; wing root leading edge on the symmetry plane", body="FRD about inventory CG"),
        reference=dict(wing_area=q(s, "m2", "derived", dsrc + ": straight taper, span x (root + tip) / 2"),
                       wing_span=q(b, "m", "manual", "Skyhunter 1800 class span 1800 mm (retail listings); design d1"),
                       mean_chord=q(c, "m", source=SCRIPT + ": S/b; MAC %.4f m" % mac),
                       aero_reference_point=q([xarp, 0.0, arp_up], "m", source=SCRIPT + ": quarter chord of the unswept quarter-chord line at the datum height"),
                       planform="tapered", root_chord=q(cr, "m", "estimated", dsrc), tip_chord=q(ct, "m", "estimated", dsrc)),
        balance=dict(plan_cg=q(cg, "m", source=SCRIPT + ": design longitudinal CG (%.0f mm aft of the root LE, %.0f %% MAC), inventory-derived lateral/vertical CG" % (cg_x * 1000, 100 * (cg_x - 0.25 * (cr - mac)) / mac)),
                     firewall=q([hub[0] - 0.05, 0.0, hub[2]], "m", "estimated", dsrc + ": motor mount plate at the pod's tail"),
                     configuration="virtual-balanced-reference-v1", cg_tolerance=q(0.001, "m", "estimated", "TB-01 reference build tolerance")),
        inventory=items,
        start=dict(level_speed=q(speed, "m/s", source=SCRIPT + ": 1.4 times clean 1-g stall (%.1f m/s) at the design mass and estimated CL_max: the trim a pilot sets for a hand launch, inside the class's 13-16 m/s cruise" % vs)),
        controls=dict(surface_ids={"aileron_left": "surface_aileron_left", "aileron_right": "surface_aileron_right", "elevator": "surface_elevator", "rudder": "surface_rudder"},
                      max_throw={key: q(d["throws_deg"][key], "deg", "estimated", dsrc + ": typical foam FPV throws; the two rudders move together") for key in ["aileron", "elevator", "rudder"]},
                      servo_full_throw_time=eq("servo_full_throw_time")),
        aero=dict(source=SCRIPT + ": geometry/textbook estimate, no identified aerodynamics", conventions=i["conventions"], coefficients=coefficients, surfaces=surfaces,
                  reference_coefficients=dict(CLadot=q(2 * ah_free * sh / s * (xh - cg_x) / c * deps, "1/rad")),
                  envelope=dict(CL_max=eq("CL_max"), CL_min=eq("CL_min"), stall_blend_width=eq("stall_blend_width"), CD90=q(1.11 + 0.018 * ar, "1"),
                                sideslip_blend=q([15, 25], "deg", "estimated", "TB-01 linear-to-sine sideslip blend (fleet value)"))),
        propulsion=propulsion,
        crash_hull=q([p for _, p, _ in probes], "m", source=SCRIPT + ": design wing tips, nose and pod belly stations, pusher disc bottom, stabilizer and fin tips, boom ends"),
        crash_hull_ids=[ident for ident, _, _ in probes],
        crash_hull_components=[name for _, _, name in probes],
        crash_tolerance=dict(terminal_specific_energy=q(12.5, "J/kg", "estimated", tolerance_src),
                             crash_depth=q(0.12, "m", "estimated", "a foam belly can bury about 12 cm in turf (X8-08 estimate)"),
                             presentation_durability=q(4.0, "1", "estimated", "EPO against balsa/ply crash presentation divisor (X8-08 estimate)")),
        plausibility=dict(mass_range=q([2.3, 3.5], "kg", "estimated", "Skyhunter 1800 class: recommended flying weight 3 kg, maximum 3.5 kg (retail listings); lighter 4S 5000 build"),
                          inertia_reference=q(j[:3], "kg·m2", source=SCRIPT + ": same inventory box estimate; self-reference is no independent plausibility evidence")))
    validate_physical_identity(model)
    summary = dict(mass=mass, cg=cg, inertia=j, wing_area=s, aspect_ratio=ar, mac=mac, stall_speed=vs, start_speed=speed,
                   static_margin=(xarp - values["Cma"] / cla * c - cg_x) / c, tail_volume=sh * lh / (s * c), fin_volume=sv * lv / (s * b),
                   CD0=cd0, virtual_mass=residue, virtual_station=xb, CL0=cl0, CLa=cla, Cm0=cm0, Cma=values["Cma"], Cnb=values["Cnb"], Clb=values["Clb"])
    return model, summary


def pack_variant(model):
    """The same airframe and inventory on the finite 4S 5000 mAh class pack (pack_ecm)."""
    pack_bytes = PACK_FILE.read_bytes()
    pack = json.loads(pack_bytes.decode("utf-8"))
    battery_item = next(item for item in model["inventory"] if item["id"] == "battery_main")
    if pack["mass_kg"]["value"] != battery_item["mass"]["value"]:
        raise ValueError("TB-01: pack mass must equal the battery_main inventory mass")
    variant = copy.deepcopy(model)
    variant["description"] = model["description"].replace("estimated electric drive", "estimated electric drive on the finite 4S 5000 mAh class pack (pack_ecm)")
    variant["capabilities"]["energy"] = "pack_ecm"
    src = SCRIPT + " pack variant: "
    est = lambda value, unit, source: q(value, unit, "estimated", src + source)
    der = lambda value, unit, source: q(value, unit, "derived", src + source)
    variant["propulsion"]["battery"] = {
        "kind": "pack_ecm",
        "pack": {"id": PACK_ID, "sha256": hashlib.sha256(pack_bytes).hexdigest()},
        "mount_inventory_id": "battery_main",
        "initial_soc": est(1.0, "1", "freshly charged pack at rest; the session may override it"),
        "auxiliary_current_a": est(0.7, "A", "flight controller, GPS, receiver, FPV camera, video transmitter and three servos, about 8 W through an assumed 80 % BEC, referred to a 15 V pack; not measured"),
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
            print("TB-01 physics data current (%d files)" % len(outputs))
        return 1 if stale else 0
    for p, data in outputs.items():
        p.write_bytes(data)
        print("wrote", p.relative_to(ROOT).as_posix())
    print(json.dumps({k: ([round(x, 4) for x in v] if isinstance(v, list) else round(v, 5)) for k, v in summary.items()}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
