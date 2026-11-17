#!/usr/bin/env python3
"""XM-01: the X-Maxx 8S replica's ground-vehicle data, derived from its design file.

Reads assets/vehicles/x-maxx/design.json (published figures and labelled estimates) and the XM-02 model
(app/assets/vehicles/x-maxx/x_maxx.glb, run XM-02 first) and writes app/data/vehicles/ground/x_maxx_8s.json in the
`openrc-ground-vehicle` v1 format the production loader (app/physics/ground_vehicle/vehicle_data.gd) checks.

    python3 research/x-maxx/XM-01/derive_vehicle.py            # writes the data file
    python3 research/x-maxx/XM-01/derive_vehicle.py --check    # fails if it is stale
    python3 research/x-maxx/XM-01/derive_vehicle.py --summary  # prints the derived drive

The electric drive is the simulator's straight torque-speed line per wheel, T = T0 (1 - w / w0), which is what a DC
motor at constant voltage gives:
- w0 (drive_torque_fade_rad_s) is the no-load wheel speed. The overall gear ratio is not published in a source this
  project could read, so it is derived: the claimed top speed is taken as 95 % of the no-load ground speed at the
  8S nominal voltage and the motor's Kv.
- T0 (drive_torque_per_wheel_nm) is the motor torque at the ESC's (estimated) current limit through that ratio and
  the driveline efficiency, shared by four wheels.

Modders: change the design's numbers (or add your own) and rerun; the tests check this file is current.
"""
import hashlib
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = "research/x-maxx/XM-01/derive_vehicle.py"
DESIGN_REL = "assets/vehicles/x-maxx/design.json"
GLB_REL = "app/assets/vehicles/x-maxx/x_maxx.glb"
OUT = ROOT / "app/data/vehicles/ground/x_maxx_8s.json"
G = 9.80665
CELL_NOMINAL_V = 3.7


def sha(path):
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def derive():
    design = json.loads((ROOT / DESIGN_REL).read_text(encoding="utf-8"))
    pub, est = design["published"], design["estimates"]
    design_sha = sha(DESIGN_REL)
    ref = "%s (SHA-256 %s)" % (DESIGN_REL, design_sha)

    def p(key): return float(pub[key]["value"])
    def e(key): return est[key]["value"]

    def q(value, unit, kind, source):
        return {"value": value, "unit": unit, "kind": kind, "source": source}

    def published(key, unit, what=None):
        return q(p(key), unit, "derived", "%s published.%s: %s" % (ref, key, what or pub[key]["source"]))

    def estimated(key, unit, value=None):
        return q(float(e(key)) if value is None else value, unit, "estimated", "%s estimates.%s: %s" % (ref, key, est[key]["source"]))

    # masses and inertia
    total = p("mass_without_battery") + e("battery_mass")
    unsprung = e("unsprung_mass_per_corner")
    sprung = total - 4.0 * unsprung
    length, width, height = e("sprung_envelope")
    k = e("sprung_gyration_factor")
    ixx = k * sprung / 12.0 * (width ** 2 + height ** 2)
    iyy = k * sprung / 12.0 * (length ** 2 + height ** 2)
    izz = k * sprung / 12.0 * (length ** 2 + width ** 2)

    # geometry
    half_wb = p("wheelbase") / 2.0
    tire_r = p("tire_diameter") / 2.0
    wheel_y = (p("width") - p("tire_width")) / 2.0
    arm_in = e("arm_inner_offset")
    rest = e("wheel_center_rest_below_datum")

    # drive
    cells = p("cells")
    volts = cells * CELL_NOMINAL_V
    kv = p("motor_kv")
    motor_free = kv * volts * 2.0 * math.pi / 60.0
    ground_free = p("top_speed_claim") / e("free_speed_margin")
    wheel_free = ground_free / tire_r
    ratio = motor_free / wheel_free
    kt = 60.0 / (2.0 * math.pi * kv)
    t0_total = kt * e("esc_current_limit") * ratio * e("drive_efficiency")
    reflected = e("motor_rotor_inertia") * ratio ** 2 / 4.0

    # suspension
    k_wheel = e("wheel_rate")
    corner_mass = sprung / 4.0
    damping = e("damping_ratio") * 2.0 * math.sqrt(k_wheel * corner_mass)
    sag = corner_mass * G / k_wheel

    drive_note = ("%s: %.0f Kv at %.0fS nominal (%.1f V) turns %.0f rad/s free; the %.2f m/s claim taken as %.0f %% of "
                  "free ground speed gives %.1f m/s on the %.4f m tire, a free wheel speed of %.1f rad/s and an overall "
                  "ratio of %.2f:1" % (SCRIPT, kv, cells, volts, motor_free, p("top_speed_claim"), 100 * e("free_speed_margin"),
                                       ground_free, tire_r, wheel_free, ratio))
    params = {
        "sprung_mass_kg": q(round(sprung, 6), "kg", "derived", "%s: %.2f kg published without battery + %.2f kg estimated packs - 4 x %.2f kg unsprung" % (SCRIPT, p("mass_without_battery"), e("battery_mass"), unsprung)),
        "unsprung_mass_kg": estimated("unsprung_mass_per_corner", "kg"),
        "sprung_inertia_kg_m2": q([round(ixx, 6), round(iyy, 6), round(izz, 6), 0.0, 0.0, 0.0], "kg m^2", "estimated",
                                  "%s: %.2f x a uniform %.2f x %.2f x %.2f m box of the sprung mass (%s estimates.sprung_envelope, sprung_gyration_factor)" % (SCRIPT, k, length, width, height, ref)),
        "wheel_spin_inertia_kg_m2": q(round(e("wheel_inertia_tire") + reflected, 7), "kg m^2", "estimated",
                                      "%s: tire and wheel %.4f plus the motor rotor %.1e reflected through %.2f:1 and shared by four wheels (%.4f)" % (SCRIPT, e("wheel_inertia_tire"), e("motor_rotor_inertia"), ratio, reflected)),
        "gravity_m_per_s2": q(G, "m/s^2", "borrowed", "standard gravity"),
        "corner_x_datum_frd_m": q([half_wb, half_wb, -half_wb, -half_wb], "m", "derived", "%s: half the %.3f m published wheelbase" % (SCRIPT, p("wheelbase"))),
        "corner_y_datum_frd_m": q([-wheel_y, wheel_y, -wheel_y, wheel_y], "m", "derived", "%s: (%.3f m published width - %.3f m tire width) / 2" % (SCRIPT, p("width"), p("tire_width"))),
        "corner_z_datum_frd_m": q([rest] * 4, "m", "estimated", "%s estimates.wheel_center_rest_below_datum: %s" % (ref, est["wheel_center_rest_below_datum"]["source"])),
        "cg_forward_from_datum_m": q(0.0, "m", "estimated", "centred between the axles (battery pods either side of the motor)"),
        "cg_right_from_datum_m": q(0.0, "m", "estimated", "symmetric layout"),
        "cg_height_above_chassis_datum_m": estimated("sprung_cg_above_datum", "m"),
        "arm_inner_offset_m": estimated("arm_inner_offset", "m"),
        "arm_length_m": q(round(wheel_y - arm_in, 6), "m", "derived", "%s: wheel centre %.4f m minus the inner hinge offset" % (SCRIPT, wheel_y)),
        "wheel_center_rest_below_chassis_datum_m": estimated("wheel_center_rest_below_datum", "m"),
        "tire_radius_m": published("tire_diameter", "m", "half of: " + pub["tire_diameter"]["source"]) | {"value": tire_r},
        "suspension_stiffness_n_per_m": q(k_wheel, "N/m", "estimated", "%s estimates.wheel_rate: %s (static sag %.1f mm)" % (ref, est["wheel_rate"]["source"], sag * 1000)),
        "suspension_damping_n_s_per_m": q(round(damping, 4), "N s/m", "derived", "%s: %.2f of critical damping for %.3f kg per corner on %.0f N/m" % (SCRIPT, e("damping_ratio"), corner_mass, k_wheel)),
        "tire_stiffness_n_per_m": estimated("tire_stiffness", "N/m"),
        "tire_damping_n_s_per_m": estimated("tire_damping", "N s/m"),
        "tire_slip_relaxation_s": estimated("tire_slip_relaxation", "s"),
        "travel_droop_m": estimated("travel_droop", "m"),
        "travel_bump_m": estimated("travel_bump", "m"),
        "bump_stop_stiffness_n_per_m": q(15000.0, "N/m", "estimated", "compliant bump stop"),
        "bump_stop_damping_n_s_per_m": q(100.0, "N s/m", "estimated", "compliant bump stop"),
        "droop_stop_stiffness_n_per_m": q(10000.0, "N/m", "estimated", "droop limit (shock fully extended)"),
        "droop_stop_damping_n_s_per_m": q(80.0, "N s/m", "estimated", "droop limit"),
        "drive_torque_per_wheel_nm": q(round(t0_total / 4.0, 6), "N m", "derived",
                                       "%s: Kt %.5f N m/A x %.0f A ESC limit (estimate) x %.2f:1 x %.2f efficiency = %.2f N m at the wheels, over four wheels. %s" % (SCRIPT, kt, e("esc_current_limit"), ratio, e("drive_efficiency"), t0_total, drive_note)),
        "brake_torque_per_wheel_nm": estimated("brake_torque_per_wheel", "N m"),
        "brake_front_fraction": q(0.5, "1", "derived", "shaft-driven 4WD without a centre differential: the motor brake reaches both axles equally"),
        "reverse_torque_fraction": estimated("reverse_fraction", "1"),
        "drive_torque_fade_rad_s": q(round(wheel_free, 6), "rad/s", "derived", drive_note),
        "rolling_resistance_coefficient": estimated("rolling_resistance", "1"),
        "tire_friction_scale": estimated("tire_friction_scale", "1"),
        "max_steer_angle_rad": q(math.radians(e("max_steer_angle")), "rad", "estimated", "%s estimates.max_steer_angle: %s" % (ref, est["max_steer_angle"]["source"])),
        "steer_servo_natural_frequency_rad_s": q(18.0, "rad/s", "estimated", "high-torque steering servo (the fleet's value)"),
        "steer_servo_damping_ratio": q(0.9, "1", "estimated", "the fleet's value"),
        "hull_probe_centers_datum_frd_m": q([
            0.36, 0.0, -0.025,     # front bumper
            -0.36, 0.0, -0.025,    # rear bumper
            0.0, 0.0, -0.035,      # tub underside
            0.22, 0.0, -0.11,      # hood
            0.17, -0.15, -0.1, 0.17, 0.15, -0.1,       # front body corners
            -0.075, -0.11, -0.205, -0.075, 0.11, -0.205,  # roof
            -0.28, -0.15, -0.125, -0.28, 0.15, -0.125,    # bed corners
        ], "m", "derived", "%s: spheres inside the XM-02 body and chassis (%s SHA-256 %s); the tub probe's underside is the datum and the roof reaches the published 350 mm height at ride" % (SCRIPT, GLB_REL, sha(GLB_REL))),
        "hull_probe_radii_m": q([0.03, 0.03, 0.035, 0.05, 0.045, 0.045, 0.045, 0.045, 0.045, 0.045], "m", "derived", "%s: sized to the body and chassis" % SCRIPT),
        "hull_contact_stiffness_n_per_m": q(15000.0, "N/m", "estimated", "the fleet's value"),
        "hull_contact_damping_n_s_per_m": q(150.0, "N s/m", "estimated", "the fleet's value"),
        "hull_contact_friction_scale": q(0.6, "1", "estimated", "the fleet's value"),
    }
    data = {
        "format": "openrc-ground-vehicle",
        "version": 1,
        "id": "x-maxx-8s-replica-v1",
        "name": design["name"],
        "description": ("Replica of the Traxxas X-Maxx 8S from published dimensions, mass, tire size, motor Kv and claimed top "
                        "speed (%s); suspension, inertia, tire, ESC current and drivetrain values are labelled estimates, not "
                        "measured vehicle data. Shape only, no logos or graphics." % DESIGN_REL),
        "drive_configuration": "electric_4wd",
        "geometry_source": {
            "spec_path": DESIGN_REL,
            "spec_sha256": design_sha,
            "glb_path": GLB_REL,
            "glb_sha256": sha(GLB_REL),
            "asset_frame": {"right": "+X", "up": "+Y", "forward": "-Z"},
            "physics_frame": {"forward": "+X", "right": "+Y", "down": "+Z"},
            "rights_status": design["rights"],
        },
        "parameters": params,
    }
    summary = {"total_mass_kg": total, "sprung_mass_kg": sprung, "ratio": ratio, "wheel_free_rad_s": wheel_free,
               "ground_free_m_s": ground_free, "t0_per_wheel_nm": t0_total / 4.0, "static_sag_m": sag,
               "peak_line_power_w": t0_total * wheel_free / 4.0}
    return data, summary


def main():
    data, summary = derive()
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if "--summary" in sys.argv[1:]:
        for k, v in summary.items():
            print("%-20s %.4f" % (k, v))
    if "--check" in sys.argv[1:]:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            print("XM-01 vehicle data is stale: rerun research/x-maxx/XM-01/derive_vehicle.py")
            return 1
        print("XM-01 vehicle data current")
        return 0
    OUT.write_text(text, encoding="utf-8")
    print("wrote %s" % OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
