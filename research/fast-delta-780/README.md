# Fast delta 780 ("Dartwing 780")

An original fast flying wing in the class of the Multiplex FunJet Ultra 2: 0.78 m span, a swept, tapered wing with
elevons, a slim centre body with a canopy and nose camera, two fixed fins, and a 4S electric pusher in the tail. It is
**not** a replica. The class figures come from retail listings of the FunJet Ultra 2 (span, wing area, flying weight,
battery, drive, top speed; see `class_reference` in the design). The planform, body, fins, stations and name are this
project's own design (conservative route in [AIRCRAFT-LICENSING](../../docs/AIRCRAFT-LICENSING.md)).

One authored design drives physics and model:
[`assets/aircraft/fast-delta-780/design.json`](../../assets/aircraft/fast-delta-780/design.json) (design d1).

| Step | Script | Writes |
| --- | --- | --- |
| FD-01 physics | `FD-01/derive_physics.py [--check]` with `FD-01/inputs.json` | `app/data/aircraft/fast_delta_780.json` (ideal 14.8 V bus), `app/data/aircraft/battery/fast_delta_780_4s_pack.json` (finite 4S 2200 mAh pack, default) |
| FD-02 model | `FD-02/build_model.py [--check]` (stdlib only) | `app/assets/aircraft/fast-delta-780/fast_delta_780.glb` (2,086 triangles, with a grey belly skid), `assets/aircraft/fast-delta-780/model-geometry.json`, `app/aircraft/fast_delta_780_geometry.gd` |

Like the Longreach 1800, the model is a separately proved **overlay family**, so the base model and paint registries
and every other aircraft's manifest stay byte-identical:
`assets/aircraft/fast-delta-780/{model,customization}-bindings.json` → `build_overlay_proof.py`,
`build_models.py --overlay-only`, `build_customization.py`, `build_descriptors.py`.

## Method (FD-01)

A textbook build-up on the **tailless strip law** the MoonRunner X99 introduced (X8-04), with nothing flight
identified (the X8's own coefficients come from NTNU flight tests and are not reused):

- DATCOM/Helmbold lift slope of the swept wing (35° leading-edge sweep, aspect ratio 4.2);
- strip integrals over the tapered swept planform, on the simulator's own three equal-area strips per side, for the
  pitch, roll and elevon derivatives, the strip stations and the elevon coverage;
- pitch damping Cmq (−0.45) and CLq from the simulator's own strip law (Weissinger induced map, stations at the
  neutral point, as the loader places them), so the coefficient and local regimes agree. A continuous strip
  integral gives −0.89 and DATCOM's swept-wing formula about 2.5 times the strip law: tailless pitch damping is
  uncertain;
- a Gilruth/Munk body term that moves the neutral point forward of the wing's own aerodynamic centre;
- thin-airfoil elevon effectiveness and camber couple, a reflexed section moment and 2° linear washout for the
  neutral-elevon cruise trim;
- two fins whose effective slope carries the directional stability (body destabilisation folded in, as X8-06 does
  for the winglets);
- a skin/form plus excrescence drag build-up;
- the **measured UIUC APC Sport 7x6** propeller tables (static and two tunnel runs, SHA-256 in `inputs.json`) for
  the 1800 Kv pusher. UIUC has no measured 6-inch speed propeller, so the design turns a 7x6 instead of the class's 6x5.5.

The loader checks the strip model against these coefficients when it loads the file (elevon effectiveness, station
shift, section moment and camber couple) and the test compares the two models' CLα, Cmα, CLδe and Cmδe.

The component inventory (10 items, not weighed) is balanced to the design CG (0.142 m aft of the root leading edge)
with a virtual ballast item (0.037 kg), as the fleet does.

| Result | Value |
| --- | --- |
| Flying mass / wing area / loading | 0.875 kg, 0.1443 m², 61 g/dm² |
| Aspect ratio / MAC | 4.22, 0.201 m |
| Static margin | 8.1 % MAC |
| Neutral-elevon trim | CL 0.18, 23 m/s |
| Clean 1-g stall (CL_max 0.9, estimate) | 10.4 m/s |
| Start trim (1.5 × stall) | 15.6 m/s |
| CD0 / power-off glide | 0.022 / L/D 12.9 at 15 m/s |
| Level trim, ideal bus | 15.6 m/s: throttle 0.28 · 20: 0.35 · 30: 0.53 · 40: 0.72 · 50: 0.91 |
| Top level speed | about 55 m/s (198 km/h); the class quotes about 220 km/h on its 6x5.5 |

Capabilities: `elevon` controls on the `tailless` law, `locked_up` gear (no wheels: hand launch, belly landing),
`single_pusher`, `fixed_voltage` / `pack_ecm`, `tolerant_hull` EPO thresholds and 14 hull probes.

## Flying it

The hand launch throws every gearless airplane at the same 6.5 m/s, below this wing's 10.4 m/s stall, at full power.
Hands off, it drops into the grass and the propeller torque rolls it within a second, as real speed wings do. Hold
**some up elevator (20–50 %) and keep the wings level** until it is past 20 m/s, about one second, or launch in the
flight controller's **angle mode** with a little up stick. It then accelerates to 50 m/s in about five seconds.

## Not validated

No airframe was measured or flown. Aerodynamic coefficients, CL_max, drag, motor resistance, inertias and the
component masses are estimates. The propeller table is borrowed from a tractor APC Sport 7x6 measured at 7,000 rpm,
far below the 20,000+ rpm it turns here. Crash-cost lines are allowances with no prices. There is no paint kit yet
(kits are built in Blender 5.2.2); the Workshop colour slots work.

## Evidence

`app/tests/test_fast_delta_780.gd`, 28 checks: both generators current; both data files pass the production loader
(span, area, mass, tailless law, pusher, no gear); the loader's derived elevon effectiveness, station shift (inside
8 % of the chord) and camber couple; the strip model reproduces the coefficients' CLα, Cmα, CLδe and Cmδe within
2 %; rudderless level trim from launch speed to 50 m/s and none at 60 m/s; the radio elevon mix reproduces the trim;
power-off glide L/D between 6 and 15; the hand launch in angle mode (calm air and a 1.5 m/s breeze) and in manual with
20 % and 50 % up elevator and wing levelling; flight-controller angle and cruise modes; and the built model (two
elevon hinges, centre body, both fins, propeller).
