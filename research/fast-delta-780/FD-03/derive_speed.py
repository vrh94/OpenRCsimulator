#!/usr/bin/env python3
"""FD-03: the Dartwing 780 6S speed variant (step 17): the same d1 airframe and aerodynamics as FD-01 on a 6S speed drive.

Reads FD-01's inputs and this folder's inputs.json, which replaces the motor, propeller, ESC and battery items, the
drive estimates, the 2000 Kv motor and the measured UIUC APC Sport 7x9 propeller map, and sets the heavier flying mass.
FD-01's derive() then builds the aircraft exactly as for the base model. Writes the ideal 22.2 V bus file
app/data/aircraft/fast_delta_780_6s.json and the finite 6S 4000 mAh pack variant
app/data/aircraft/battery/fast_delta_780_6s_pack.json.

    python3 research/fast-delta-780/FD-03/derive_speed.py           # writes both files and prints a summary
    python3 research/fast-delta-780/FD-03/derive_speed.py --check   # fails if either is stale
    python3 research/fast-delta-780/FD-03/derive_speed.py --summary # prints the summary only

Python standard library only.
"""
import copy
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SCRIPT = "research/fast-delta-780/FD-03/derive_speed.py"
OUTPUT = ROOT / "app/data/aircraft/fast_delta_780_6s.json"
PACK_OUTPUT = ROOT / "app/data/aircraft/battery/fast_delta_780_6s_pack.json"

_spec = importlib.util.spec_from_file_location("fd01", HERE.parent / "FD-01/derive_physics.py")
fd01 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fd01)


def variant_inputs():
    """FD-01's inputs with this variant's replacements applied, plus the variant record."""
    over = json.loads((HERE / "inputs.json").read_text(encoding="utf-8"))
    base = json.loads((ROOT / over["base_inputs"]).read_text(encoding="utf-8"))
    merged = copy.deepcopy(base)
    merged["estimates"].update(over["estimates"])
    replace = {item["id"]: item for item in over["inventory_replace"]}
    unknown = set(replace) - {item["id"] for item in base["inventory"]}
    if unknown:
        raise ValueError("FD-03: inventory_replace names unknown items %s" % sorted(unknown))
    merged["inventory"] = [replace.get(item["id"], item) for item in base["inventory"]]
    merged["inventory_source"] = "%s (motor, propeller, ESC, battery); other items: %s" % (over["inventory_source"], base["inventory_source"])
    merged["propulsion"]["motor"].update(over["propulsion"]["motor"])
    merged["propulsion"]["propeller"] = copy.deepcopy(over["propulsion"]["propeller"])
    return merged, over["variant"]


def derive():
    inputs, var = variant_inputs()
    mass = var["flying_mass_kg"]["value"]
    description = ("EXPERIMENTAL FD-03: 6S speed variant of the Dartwing 780 (FD-01), an original fast swept flying-wing EPO pusher in "
                   "the 0.78 m speed-wing class. Same d1 airframe and textbook tailless aerodynamics; %.2f kg 6S speed build "
                   "(2000 Kv-class motor, measured UIUC APC Sport 7x9 map, 6S 4000 mAh pack), estimated electric drive, built to hold "
                   "360 km/h level. No landing gear (hand launch), tougher foam airframe. Not flight validated." % mass)
    model, summary = fd01.derive(inputs, dict(id=var["id"], description=description, flying_mass_kg=mass,
                                               mass_range=var["mass_range"]["value"], mass_range_source=var["mass_range"]["source"],
                                               hand_launch_speed=dict(var["hand_launch_speed"], kind="estimated"),
                                               start_level_speed=dict(var["start_level_speed"], kind="estimated")))
    battery = next(item for item in model["inventory"] if item["id"] == "battery_main")
    pack = dict(id=var["pack_id"], label=var["pack_label"], auxiliary_current_a=0.27,
                auxiliary="flight controller, receiver, FPV camera, video transmitter and two servos, about 5 W through an assumed 80 % BEC, referred to a 23 V pack; not measured",
                cutoff_per_cell_v=3.0,
                esc="speed-pass ESC setting: cutoff lowered to 3.0 V/cell (the 3.2 V default trips under the 150-200 A loaded sag of a speed run on this pack); installed setting unknown")
    if battery["mass"]["value"] != json.loads((ROOT / "app/data/batteries/packs" / (pack["id"] + ".json")).read_text(encoding="utf-8"))["mass_kg"]["value"]:
        raise ValueError("FD-03: battery_main mass must equal the pack's mass")
    return model, fd01.pack_variant(model, pack), summary


def main():
    model, pack_model, summary = derive()
    outputs = {OUTPUT: fd01.render(model), PACK_OUTPUT: fd01.render(pack_model)}
    if "--check" in sys.argv:
        stale = [p for p, data in outputs.items() if not p.exists() or p.read_bytes() != data]
        for p in stale:
            print("stale or missing: %s (run %s)" % (p.relative_to(ROOT).as_posix(), SCRIPT))
        if not stale:
            print("FD-03 speed variant data current (%d files)" % len(outputs))
        return 1 if stale else 0
    if "--summary" not in sys.argv:
        for p, data in outputs.items():
            p.write_bytes(data)
            print("wrote", p.relative_to(ROOT).as_posix())
    print(json.dumps({k: ([round(x, 4) for x in v] if isinstance(v, list) else round(v, 5)) for k, v in summary.items()}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
