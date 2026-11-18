# Traxxas X-Maxx 8S replica (`x-maxx-8s`)

A drivable replica of the Traxxas X-Maxx 8S (77086-4) monster truck. It copies the published dimensions, weight, tire
size, motor and top speed, and the look of the truck: a cab-forward pickup shell with flared arches, black skids,
8-inch chevron tires on black multi-spoke wheels, long-travel A-arms and four coil-over shocks. It carries **no Traxxas
logos, decals or graphics**. The project owner stated on 2026-11-17 that they have Traxxas's permission for the
replica ([DECISIONS](../../docs/DECISIONS.md#replicate-the-traxxas-x-maxx-with-the-owners-stated-permission)).

One design file drives physics and model, and both are generated:
[`assets/vehicles/x-maxx/design.json`](../../assets/vehicles/x-maxx/design.json).

| Step | Script | Writes |
| --- | --- | --- |
| XM-02 model (run first) | `XM-02/build_model.py [--check]` (Python standard library) | `app/assets/vehicles/x-maxx/x_maxx.glb` (10,336 triangles, named pivots) |
| XM-01 physics | `XM-01/derive_vehicle.py [--check] [--summary]` | `app/data/vehicles/ground/x_maxx_8s.json` (`openrc-ground-vehicle` v1, records both hashes) |

`app/vehicles/ground/x_maxx_model.gd` poses the GLB's pivots from the physics state (arms, shocks, driveshafts,
steering, wheel spin); the GLB holds no animation or simulation.

## Sources

Published (`design.published`): length 779 mm (one review gives 758), width 540 mm, height about 350 mm, wheelbase
480 mm, ground clearance 102 mm (some list 107), 8.66 kg without battery, 8.0 x 4.0 in tires, 187 mm shocks, Velineon
1200XL (1275 Kv), VXL-8s ESC on 2 x 4S, and Traxxas's 50+ mph claim (Big Squid RC measured 42 mph). The figures come
from retailer copies of the Traxxas specification (traxxas.com's own 77086-4 page returned 404 on 2026-11-17).

Estimated (`design.estimates`, each with its reason): pack mass (2 x 0.6 kg), unsprung mass, CG height, inertia,
suspension geometry, travel, spring rate (23 mm sag, 3.3 Hz), damping, tire stiffness, steering lock, brake torque,
and the two numbers the drive needs that are not published:

- **Overall gear ratio, 17.05:1.** Derived: the claimed 22.35 m/s is taken as 95 % of the no-load ground speed at
  8 x 3.7 V and 1275 Kv on the 203 mm tire.
- **ESC current limit, 250 A.** Not published; it sets the low-speed torque, 7.2 N m per wheel, about three times
  what the tires can put down at a standstill.

The simulator's electric drive is a straight torque-speed line per wheel, T = T0 (1 - w/w0), which is a DC motor at
constant voltage; it has no battery sag or ESC heat (the aircraft have those, the trucks do not yet).

## How it drives (simulator, `app/tests/test_x_maxx.gd`, 20 checks)

| Result | Value |
| --- | --- |
| Total mass / sprung | 9.86 kg / 7.46 kg |
| At rest | 23 mm sag, about 100 mm under the tub |
| Full throttle, airfield grass | 77 km/h in 10 s |
| Full throttle, practice course | 84 km/h; it wheelies about 55 degrees at launch on the grippy course, as the real truck does on 8S |
| Steady corners (6 m/s at 40 % steering, 4 m/s at full lock, 9 m/s at 20 %) | upright, about 6 degrees of body roll |
| Full throttle with the wheel turned | the tires spin, it spins out and can roll over: feather the throttle in turns. The real 8S truck relies on Traxxas Stability Management (TSM) here; the garage's stability assist (Step 19, below) plays that part |

## Tuning it in the garage (Step 19)

Garage › **Tune truck** sets gearing (x0.7–1.3 of the stock no-load speed; the wheel torque falls by the same factor),
steering lock, brakes, springs, damping, tire grip, a throttle limit and the stability assist, saved per truck in
`user://ground_tuning.json`. The stability assist works on the commands, not the physics: it steers against a yaw
beyond what the steering asks for, caps the steering at about 0.7 g of turn at speed, steers out of a body roll past
10 degrees, and eases the throttle for wheel spin and wheelies past 20 degrees. With it at 100 %, full throttle and full
steering from a standstill on the practice course stays upright (6 degrees of roll) instead of rolling over
(`app/tests/test_truck_tuning.gd`).

## Modding it

Change `design.json` (any published figure or estimate, or the `visual` block: arch radius, roof height, cab position,
body width, tread lug count, rim size, colours) and rerun XM-02, then XM-01. The Godot import refreshes the model on
the next editor or `--import` run. `app/tests/test_x_maxx.gd` checks that the generated files are current and that the
render rig still matches the data and the GLB. The stock paints (Red, Blue, Green, Orange) live in
`app/data/vehicle_paints.json` under `x-maxx-8s` and bind to the GLB's `XM_*` material names.

## Rights record

- Geometry, mesh and paint: authored for this project by XM-02 from the design file; no Traxxas CAD, mesh, photo
  texture, decal, logo or manual artwork was used.
- Name: "Traxxas X-Maxx 8S" is shown under the owner's stated permission (2026-11-17). The written grant is not in this
  repository; keep it with the project's rights records, and check that it covers the public source repository,
  forks, binaries and crash simulation (see [AIRCRAFT-LICENSING](../../docs/AIRCRAFT-LICENSING.md#permission-request-and-release-record)).
- If that permission does not cover a distribution mode, rename the catalog entry and keep the generic shape.

## Not validated

No truck was measured or driven against the simulator. Every estimate above is a reasoned guess, and the published
figures come from retailer listings rather than a Traxxas document this project could read.
