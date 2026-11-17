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
| FD-03 6S speed variant | `FD-03/derive_speed.py [--check]` with `FD-03/inputs.json` (overrides of FD-01's inputs) | `app/data/aircraft/fast_delta_780_6s.json` (ideal 22.2 V bus), `app/data/aircraft/battery/fast_delta_780_6s_pack.json` (6S 4000 mAh pack, default) |
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

## FD-03: the 6S speed variant

`fast-delta-780-6s` ("Dartwing 780 · Speed 6S") flies the same airframe, CG and coefficients as FD-01 on a 6S speed
drive. `FD-03/inputs.json` replaces four inventory items and the drive estimates; FD-01's `derive()` builds the rest.

| Item | Base (FD-01) | Speed 6S (FD-03) |
| --- | --- | --- |
| Motor | 35-mm 1800 Kv, 0.032 Ω, 0.105 kg | 40-mm 2000 Kv, 0.012 Ω, 0.20 kg (estimates) |
| Propeller | measured APC Sport 7x6 | measured APC Sport 7x9 (UIUC Vol. 1, J to 1.38, SHA-256 in `inputs.json`) |
| ESC | 60 A | 200 A, cutoff 3.0 V/cell |
| Battery | 4S 2200 mAh class, 0.227 kg | 6S 4000 mAh (existing Gens ace G-tech pack file), 0.606 kg |
| Flying mass / stall | 0.875 kg / 10.4 m/s | 1.42 kg / 13.2 m/s |
| Hand-launch throw | shared 6.5 m/s | 11 m/s (`start.hand_launch_speed`) |
| Start reference (`start.level_speed`) | 15.6 m/s (1.5 × stall) | 30 m/s (2.25 × stall): the 50 % airborne start searches up to 2.5 × this, and this build flies about 63 m/s at half throttle |

How the drive was chosen (in the simulator, not on paper): at 100 m/s the wing needs about 20 N, which the 7x9 gives at
about 33,000 rpm and 3.1 kW at the shaft. Under the project's pack law a 6S 2200 sags to the cutoff long before that, and
tops out near 340 km/h; the 6S 4000 holds 1900 Kv at 355 km/h and 2000 Kv at 361 km/h. A 0.009 Ω winding is stiffer than
the 240 Hz electric source qualifies, so the motor keeps 0.012 Ω. With the default 3.2 V/cell cutoff the loaded pack
trips the ESC in seconds; speed pilots lower it, so this build uses 3.0 V.

| Result (simulator) | Value |
| --- | --- |
| Level, fresh 6S 4000 pack, full throttle | 100.5 m/s (362 km/h), about 197 A, 18.7 V; cutoff after about 50 s |
| Level, ideal 22.2 V bus | trims to 110 m/s at 93 % throttle; about 112 m/s (400 km/h) at full |
| Stability at 110 m/s | hands-off pitch-and-roll kick damps within 0.5 s; neutral spiral |
| Full power from the 50 % start, hands-off | the thrust line above the CG lowers the nose: it dives to about 118 m/s in a long phugoid instead of climbing (it still gains energy) |
| Hand launch at 11 m/s (fresh pack) | flies with 40 % up elevator and the wings held level at 60 % or full throttle, and in angle mode; 25 % up at 60 % throttle sinks in; the 6.5 m/s throw crashes |

Fly it with low rates or Workshop control travel below 100 %: at 360 km/h a 15 % stick blip rolls it 40° in a fraction
of a second. Not validated: everything in the base list, plus a propeller map measured at 6,800 rpm turned at 33,000 rpm
and no structural or flutter limit (the simulator has none).

Evidence: `app/tests/test_fast_delta_780_6s.gd`, 16 checks.
