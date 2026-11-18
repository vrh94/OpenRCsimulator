# Fixed-wing flight controller (FPV long-range modes)

Airplanes can fly through a flight controller (FC) with the modes FPV pilots know from INAV and ArduPilot. It sits
where a real FC sits, between the receiver (the pilot's sticks after rates and trims) and the servos. It reads only
what a real FC's sensors read (attitude, gyro rates, airspeed, GPS position and velocity, all from the rigid-body
state) and writes the same normalized roll / pitch / yaw / throttle commands the pilot writes.

**The flight physics are untouched.** The FC moves the same surfaces the pilot moves. **Manual** (the default)
passes the sticks through unchanged, so a flight without a mode switch flies exactly as before; the golden flights
replay bit-exact.

## FC-1 (done)

| Mode | INAV OSD | ArduPilot OSD | What it does |
|---|---|---|---|
| Manual | MANU | MANU | Sticks straight to the surfaces |
| Acro | ACRO | ACRO | Sticks set roll (180°/s) and pitch (90°/s) rates; centred, the gyro holds the attitude |
| Angle | ANGL | FBWA | Sticks set bank (±45°) and pitch (+25° / −30°); centred, the wings level |
| Horizon | HOR | STAB | Angle near the centre, rate at full stick (rolls and loops) |
| Altitude hold | ALTH | FBWB | Angle roll; pitch stick sets the climb rate (±4 m/s), centred holds the height |
| Cruise | CRUZ | CRUS | Altitude hold plus course hold: turn with the roll stick, release to hold the new course |
| Loiter | LOTR | LOIT | Clockwise circle at the point of engagement, height and airspeed held (auto throttle) |
| Return to home | RTH | RTL | Climbs to ≥ 40 m above the launch point, flies home, circles over home (auto throttle) |

- Code: `app/sim/fixed_wing_fc.gd` (pure); `FlightSession._flight_controller_commands()` applies it once per tick.
- Loops: rate PI with feed-forward, scaled by 20 m/s ÷ airspeed (surface authority grows with speed); angle → rate
  with the coordinated-turn pitch rate; altitude → climb rate → pitch with an integrating pitch trim; course → bank;
  airspeed → throttle. Stabilised modes read the sticks relative to the transmitter trims (like an FC's stick-centre
  calibration).
- Mode selection: the radio's **Flight mode** AUX channel (shared with the FPV quad, now offered for airplanes in
  Controls › Extra channels) picks the mode of its position: Settings › Camera › Flight controller, default
  Manual / Angle / Cruise for low / middle / high. **M / Shift+M** step through every mode; a new switch position
  wins again. The FPV OSD shows the mode in the selected firmware's spelling (RTH as a warning).
- Captures: `--fc-mode=<mode>`.

### Evidence

`tests/test_fixed_wing_fc.gd`, 49 checks, closed-loop through the real session on the Stik (16 m/s) and the
Avanti jet (35 m/s): angle holds 45° and levels on release; acro rolls about 90°/s at half stick and holds the bank;
altitude hold stays within 2 m through a 27° turn; cruise holds the new course within 3° and the height within 2 m;
loiter stays within 10 % of its radius (56 m / 268 m) and 2 m of height with the pilot's throttle at idle; RTH
returns from 320 m / 699 m and circles over home. During tuning the Turbo Lumber and the P-51D flew the same
modes (bank and height held, loiter within 2 % of the radius).

## FC-2 (done): failsafe

- **Radio link** (`app/sim/rc_link.gd`): Off (perfect, default) / 2.4 GHz ExpressLRS-like (50 % quality at 6 km) /
  900 MHz long range (30 km). Same margin law as the video link (20·log10(R½/d) − blockage), on the same
  line-of-sight scan from the pilot station; terrain costs 22 dB at 2.4 GHz and 12 dB at 900 MHz. Ranges are
  presentation choices in the range pilots report for stock antennas, not measurements. Failsafe after 1 s below
  15 % quality; recovery after 1 s above 50 %. With a modelled radio link the OSD's LQ/RSSI is the radio link (as
  on a real FC); otherwise it stays the video link's.
- **Failsafe RTH** (`FixedWingFC.trigger_rth`): a lost radio link always returns home, flies with centred sticks
  (idle on the ground) and refuses mode changes. When the link is back the airplane keeps returning until the pilot
  moves a roll/pitch stick past half or picks a mode (INAV-style takeover); the mode before the failsafe returns.
  Optional: **return on video loss** (picture below 15 % for 1.5 s; re-arms when the picture is back) and **return
  on low battery** (first battery warning of the flight, like ArduPilot's battery failsafe). Both off by default.
- **OSD**: "RX LOSS - RTH" (critical) outranks everything; critical battery alarms outrank "VIDEO LOSS - RTH" /
  "LOW BATT - RTH"; then "RTH - MOVE STICKS"; then **"BATT LOW FOR HOME"**: charge left < 1.3 × charge needed to
  fly home at this flight's average current (used mAh ÷ flight time) and current ground speed, after 30 s and
  beyond 200 m. All from existing sensor figures; nothing invented.
- Fixed with it: home was taken from the previous flight's state on a restart (tick 0). Home is now the first flown
  tick and the session resets the controller on every committed restart. RTH climbs to ≥ 40 m above home.

Evidence: `tests/test_fc_failsafe.gd` 33/33 (link ranges, delays, terrain, takeover rules, OSD ranking, home
reserve arithmetic, preferences, and a closed-loop Stik flight: radio lost 342 m out with full roll held, it comes
home and circles 40 m above home; a roll stick then gives Angle back). `tests/test_fixed_wing_fc.gd` 49/49.

## FC-3 (done): long-range gear and OSD (14a)

- **Video transmitter**: 1.6 W and 2.5 W join 25–1000 mW (same margin law: 2.5 W reaches 50 % picture quality
  at 6 km with the stock antenna).
- **Receiving antenna** (Settings › Camera › Video link): Stock omni (default, 0 dB) / Patch (+8 dB, about 15 km at
  2.5 W) / Helical (+13 dB, about 27 km). The gain adds to the margin; it is a presentation choice in the range of
  common FPV ground antennas, not a measurement. Captures: `--fpv-antenna=omni|patch|helical`.
- **OSD elements** (Settings › Camera › OSD):
  - **Trip** (on by default): the GPS ground speed integrated over the flight. Pauses longer than 1 s are not bridged.
  - **Remaining** (on by default): time and distance until the pack reaches a 20 % reserve, from this flight's average
    current and efficiency. Shown after 30 s; a warning under a minute.
  - **Efficiency** (off by default): used mAh per km (or mi) of trip, after 200 m.
  - All three come from the existing battery sensor figures; glow and gas engines show only the trip.
- Settings › Camera now has six parts (OSD and Video link are separate), laid out in two rows, each fitting 1080p.

Evidence: `tests/test_fpv_long_range.gd` 27/27 (ranges per antenna, 20 km helical vs stock, efficiency / remaining
arithmetic, text formats metric and imperial, unique OSD cells per firmware, trip integration and gap handling,
preferences). test_camera_settings 51/51, test_ui_modal_responsive 4290/0, test_golden bit-exact.

## FC-4 (done): long-range landmarks (14b)

A 9 km FPV flight showed plain green ground and nothing to navigate by. Two causes, two fixes:

- **Nothing out there**: the club scenery stops at the 5 km horizon ring (SC-01). A new visual-only layer,
  `app/render/landscape_upgrade/long_range.gd`, builds `app/data/scenery/long_range.json` (written by
  `tools/scenery/long_range.py`, `--check` in the test): a closed **ring road** (79 km of 6 m gravel, 6.5–16.5 km
  out) linking three towns with churches (30 / 18 / 14 houses), two farmsteads and two wind farms. It uses the
  existing scenery prefabs, merged into one static mesh per cluster (turbine rotors baked in) placed at the cluster
  centre for float precision: 8 meshes, about 18k triangles, about 14 ms to build, no per-frame work. Everything
  stands on the flat ground past the 6 km horizon relief and clear of the visual mountains. No collision, like the
  ridges. An earlier try that routed the landmarks through the club scenery broke its cell, triangle and rotor
  budgets (5 tests) and was replaced by this layer.
- **Plain ground**: the ground shader's field patchwork is pinned to the pilot (fades 1.8–3 km from the station).
  `fields_from_camera` (onboard and cockpit views only, `Atmosphere.set_fields_from_camera`) measures that fade from
  the camera instead (3.5–6.5 km), so the parcels stay under the airplane. The pilot view is unchanged: a westward
  pilot capture differs from the previous commit in 24 of 921,600 pixels (the 8 km town in the horizon haze).

Evidence: `tests/test_long_range_landmarks.gd` 18/18 (generator check, flat ground and mountain clearance, the road
encloses the field so every bearing out crosses it, every town and farm on the road, mesh and triangle budgets,
static meshes, field attachment, the patchwork switch on every ground material and back). The 51 scenery,
landscape, ground and atmosphere tests and the 15 FPV/camera/golden tests pass.

## Step 15 (done): Longreach 1800, a Skyhunter 1800-class twin-boom

An original long-range FPV airplane (`twin-boom-1800`, experimental): 1.80 m, 2.6 kg, H-tail with twin fins, 4S
920 Kv pusher, no landing gear (hand launch). It is an original design, not a replica: only the class figures (span,
area, weight, power system) come from Skyhunter 1800 retail listings. One authored design file generates the physics
(TB-01, TT-07 textbook build-up) and the model (TB-02, a stdlib GLB builder). Details, numbers and limits:
[research/twin-boom-1800](../../research/twin-boom-1800/README.md).

- **No flight-physics change.** The airplane uses existing laws and capabilities (`conventional`, `locked_up`,
  `single_pusher`, `pack_ecm`, `tolerant_hull`). The golden tapes are bit-exact.
- **No change to the other aircraft.** The model is a separately proved overlay family, so the base model and paint
  registries and every other base manifest are byte-identical. Adding a family changes the shared overlay scripts
  that the MoonRunner and electric Stik proofs hash. The electric Stik's paint kit (built in Blender) keeps its
  template through an explicit reviewed identity pair in `custom_skin.gd`, the same mechanism the Stik and Extra use.
- **Fleet integration.** Catalog entry, hand launch (with the MoonRunner), Workshop descriptor, paint slots, crash
  economics (partial dossier with unpriced estimated lines and a cost profile), and the fleet tests' explicit lists.
- **Not yet.** No paint kit (it needs Blender 5.2.2). Not flight-validated.

Evidence: `tests/test_twin_boom_1800.gd` 17/17 (generators current, both data files load, trims 11–26 m/s, hands-off
hand launch in calm air and a breeze, FC angle and cruise modes, model hinges and parts). The fleet sweep, the golden
tapes and the aircraft, economy, Workshop and skin Python suites pass.

## Step 16 (done): Dartwing 780, a FunJet-class fast delta

An original speed wing (`fast-delta-780`, experimental): 0.78 m, 0.875 kg, swept tapered wing with elevons, slim
centre body with a nose camera, two fixed fins, 4S 1800 Kv pusher, no landing gear (hand launch), top level speed
about 55 m/s (198 km/h). It is an original design, not a replica: only the class figures (span, area, weight, battery,
drive, top speed) come from FunJet Ultra 2 retail listings. One authored design file generates the physics (FD-01, a
textbook build-up on the X8's tailless strip law) and the model (FD-02, the TB-02 stdlib GLB builder adapted to a swept
wing with elevons). Details, numbers and limits: [research/fast-delta-780](../../research/fast-delta-780/README.md).

- **No flight-physics change.** The airplane uses existing laws and capabilities (`elevon`, `tailless`, `locked_up`,
  `single_pusher`, `pack_ecm`, `tolerant_hull`). The loader's own tailless consistency solve accepts the coefficients.
- **No change to the other aircraft.** A separately proved overlay family again; the electric Stik's reviewed paint
  identity pair in `custom_skin.gd` now names its new current identity (geometry and paint mapping unchanged).
- **Fleet integration.** Catalog entry (between the Longreach 1800 and the helicopter), hand launch, Workshop
  descriptor, paint slots, crash economics (partial dossier with unpriced estimated lines and a cost profile),
  translations and the fleet tests' explicit lists.
- **Hand launch.** The shared 6.5 m/s throw is below this wing's 10.4 m/s stall: hands off it drops in. With some up
  elevator and the wings levelled, or in angle mode, it climbs away. This is how real speed wings are launched; the
  launch logic is unchanged.
- **Not yet.** No paint kit (it needs Blender 5.2.2). Not flight-validated. The propeller table is a borrowed 7x6.

Evidence: `tests/test_fast_delta_780.gd` 28/28 (generators current, both data files load, the strip model matches
the coefficients, trims from launch speed to 50 m/s and none at 60 m/s, glide, hand launch in angle mode and in
manual with up elevator, FC angle and cruise modes, model hinges and parts).

## Step 17 (done): Dartwing 780 Speed 6S, 360 km/h

The user asked for a FunJet that can fly 360 km/h. `fast-delta-780-6s` (experimental) is the Dartwing's airframe and
aerodynamics on a 6S speed drive, generated by FD-03 from FD-01 with a short override file: 2000 Kv motor, the measured
UIUC APC Sport 7x9 (pitch speed for 100 m/s at about 33,000 rpm), 200 A ESC, the existing 6S 4000 mAh pack, 1.42 kg.

- **360 km/h level on a fresh pack** (100.5 m/s), about 50 s of full power before the ESC cutoff; 400 km/h on the
  ideal 22.2 V bus. The pack law sags a 6S 2200 too far for this, hence the heavier 4000 mAh pack, and the ESC cutoff is
  lowered to 3.0 V/cell as speed pilots do (the 3.2 V default trips under the 180-200 A load).
- **Stable at speed.** Trimmed hands-off at 110 m/s, a pitch-and-roll kick damps out within half a second.
- **Hand launch.** One optional data field, `start.hand_launch_speed` (3–15 m/s, loader, schema and contract), lets an
  aircraft declare its own throw; every other aircraft keeps the shared 6.5 m/s. This build declares 11 m/s (a hard
  running throw). It still needs about 40 % up elevator and the wings held level against the torque, or angle mode.
- **No flight-physics change.** Same laws and capabilities; the session only reads the throw speed.

Evidence: `tests/test_fast_delta_780_6s.gd` 16/16. Details: [FD-03](../../research/fast-delta-780/README.md#fd-03-the-6s-speed-variant).

## Step 18 (done): Traxxas X-Maxx 8S replica

- `x-maxx-8s` in the ground catalog and Home roster, generated from
  [`assets/vehicles/x-maxx/design.json`](../../assets/vehicles/x-maxx/design.json) by XM-02 (GLB with named pivots) and
  XM-01 (`openrc-ground-vehicle` data); [research/x-maxx](../../research/x-maxx/README.md) has the sources, the
  estimates and the rights record. No logos or graphics (owner's choice); owner-stated Traxxas permission in DECISIONS.
- `vehicles/ground/x_maxx_model.gd` poses arms, shocks, driveshafts, steering and wheels from the physics state; the
  damage view gets separate bumpers, the lights optional `lamp_anchors`, the dashboard a per-vehicle scale label.
- The truck physics is unchanged: the X-Maxx is data on the existing electric 4WD law (T = T0 (1 - w/w0)).
- Evidence: `app/tests/test_x_maxx.gd`, 20 checks (generators, published figures, rig against data and GLB, paints,
  roster, sag and clearance, top speed, steady corners).

## Step 19 (done): truck tuning

- Garage › **Tune truck** on every RC truck, saved per truck in `user://ground_tuning.json`
  (`vehicles/ground/truck_tuning.gd`) and applied when the truck loads: gearing, steering lock, brakes, springs,
  damping, tire grip, throttle limit and stability assist. Apply restarts the run like a Physics lab experiment; Stock
  returns to the stock data.
- The physical settings are the session's experiment knobs: `VehicleData.with_experiment` takes optional
  `gear_scale` (electric no-load speed x g and wheel torque / g; nitro gear ratio / g), `steer_scale` and `brake_scale`,
  present only when changed, so stock setups and old checkpoints keep their identity. Checkpoints and recordings carry
  the tune. The lab keeps gravity and ballast; springs, damping and grip moved to the tuning panel.
- Driver aids (`vehicles/ground/driver_aids.gd`) act on the commands at 240 Hz before the tick, from the read-only
  state: a throttle limit and a stability assist (yaw-rate excess, a 0.7 g steering ceiling at speed, roll past
  10 degrees, wheel spin, wheelies past 20 degrees). The truck physics is unchanged; recordings keep the commands the
  truck received.
- Evidence: `app/tests/test_truck_tuning.gd`, 20 checks (store, data keys and identity, nitro gearing, X-Maxx top speed
  76 to 88 km/h at x1.2, throttle limit, full-throttle full-lock launch on the course: 162 degrees of roll without the
  assist, 6 with it, steady corner unchanged, garage load/apply/save/stock).

## Next

The plan's steps 12–19 are done; step 11 (shadows) is deferred. Planned next (user decisions 2026-11-17): a user mod
folder, and a Triglav National Park landscape with solid terrain (Planica/Tamar).
