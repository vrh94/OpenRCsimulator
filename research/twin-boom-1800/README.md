# Twin-boom 1800 ("Longreach 1800")

An original long-range FPV airplane in the class of the Skyhunter 1800: 1.80 m span, a pod with a nose camera, two
carbon booms, an H-tail with twin fins, and a 4S electric pusher. It is **not** a replica. The class figures come
from retail listings of the Skyhunter 1800 (span, wing area, flying weight, motor, propeller, ESC and servos; see
`class_reference` in the design). The planform, pod, booms, tail, stations and name are this project's own design
(conservative route in [AIRCRAFT-LICENSING](../../docs/AIRCRAFT-LICENSING.md)).

One authored design drives physics and model:
[`assets/aircraft/twin-boom-1800/design.json`](../../assets/aircraft/twin-boom-1800/design.json) (design d1).

| Step | Script | Writes |
| --- | --- | --- |
| TB-01 physics | `TB-01/derive_physics.py [--check]` with `TB-01/inputs.json` | `app/data/aircraft/twin_boom_1800.json` (ideal 14.8 V bus), `app/data/aircraft/battery/twin_boom_1800_4s_pack.json` (finite 4S 5000 mAh pack, default) |
| TB-02 model | `TB-02/build_model.py [--check]` (stdlib only) | `app/assets/aircraft/twin-boom-1800/twin_boom_1800.glb` (2,438 triangles), `assets/aircraft/twin-boom-1800/model-geometry.json`, `app/aircraft/twin_boom_1800_geometry.gd` |

The model is registered as a separately proved **overlay family** (like the MoonRunner and the electric Stik), so the
base model and paint registries and every other aircraft's manifest stay byte-identical:
`assets/aircraft/twin-boom-1800/{model,customization}-bindings.json` → `build_overlay_proof.py`,
`build_models.py --overlay-only`, `build_customization.py`, `build_descriptors.py`.

## Method (TB-01)

The TT-07 textbook build-up, on a tapered wing: Helmbold lift slope, thin-airfoil flap effectiveness, tail volume and
downwash, an H-tail with end-plated twin fins, a skin/form plus excrescence drag build-up, and a borrowed UIUC APC
11x7 propeller table for the 920 Kv pusher. Every estimate in `inputs.json` names its source. The component
inventory (12 items, not weighed) is balanced to the design CG (0.095 m aft of the root leading edge) with a virtual
ballast item (0.289 kg), as the fleet does.

| Result | Value |
| --- | --- |
| Flying mass / wing area / loading | 2.6 kg, 0.378 m², 69 g/dm² |
| Aspect ratio / MAC | 8.57, 0.212 m |
| Static margin / tail volume / fin volume | 14.9 %, 0.713, 0.052 |
| Clean 1-g stall (CL_max 1.3, estimate) | 9.2 m/s |
| Start trim (1.4 × stall) | 12.9 m/s |
| CD0 | 0.031 |
| Level trim, ideal bus | 11 m/s: throttle 0.30 · 15 m/s: 0.37 · 18 m/s: 0.46 · 22 m/s: 0.57 · 26 m/s: 0.69 |

Capabilities: `conventional` controls (two rudders on one channel), `locked_up` gear (no wheels: hand launch, belly
landing), `single_pusher`, `fixed_voltage` / `pack_ecm`, `tolerant_hull` EPO thresholds and 15 hull probes.

## Not validated

No airframe was measured or flown. Aerodynamic coefficients, CL_max, drag, motor resistance, inertias and the
component masses are estimates; the propeller table is borrowed from a tractor APC 11x7. Crash-cost lines are
allowances with no prices. There is no paint kit yet (kits are built in Blender 5.2.2); the Workshop colour slots work.

## Evidence

`app/tests/test_twin_boom_1800.gd`, 17 checks: both generators current, both data files pass the production loader
(span, area, mass), level trim 11–26 m/s, hands-off hand launch at full throttle in calm air (lowest CG 0.16 m, belly
0.10 m below it, 54 m up after 6 s) and in a 1.5 m/s breeze (1.41 m, 57 m), flight-controller angle mode (holds the
45° bank limit, levels when released) and cruise (height and course held over 20 s), and the built model (two rudder
hinges on the rudder channel, booms, both fins, propeller).
