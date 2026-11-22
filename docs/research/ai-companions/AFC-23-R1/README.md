# AFC-23-R1: Ugly Stik companion circuits on the Triglav field

2026-11-22, macOS arm64, official Godot `4.8.beta2.official.cafc17a19`, headless GDScript reference.
Owner request (option 6): flight companions on Triglav. This adds a second qualified field profile,
`triglav-tamar`, beside `club-default`. The aircraft, its data, the solver sources (`app/physics`, `app/sim`,
`app/failures`) and the Club field profile are unchanged. The scope stays the narrow AFC-02 scope: one to three
experienced Ugly Stik pilots flying airborne circuits in calm air or a gentle breeze.

## What changed

- **Field profiles.** `ai/companions/profile_loader.gd` lists the qualified field profiles. Each one binds its field
  file by SHA-256, its runway, the runway-derived route and its own altitude bands and evidence. The aircraft
  profile (`openrc-ai-aircraft v3`) lists the field profiles it is qualified for (`field_profile_ids`). A launch picks
  the profile of the supplied field; the launch identity records that profile and field path.
- **Altitude bands from the profile.** The circuit controller and pilot read the base height and slot step from the
  qualified profile, not from constants. The route centre and radius must still equal the runway-derived circle.
  Triglav flies 45/65/85 m above the pilot, 10 m above Club field: the surveyed meadow under the circuit lies 1.0 to
  7.4 m above the pilot. At 35 m the lowest slot would sit inside the controller's 30 m terrain-recovery band, where
  it climbs at full throttle. Club field passes its own record (35/55/75 m), so its pilots fly exactly as before.
- **Air.** On a flat field companions still need sea-level reference air. On Triglav they need the field's standard
  air at 849.7 m: the air the default weather choice becomes there (`physics/field_air.gd`). The wind and turbulence
  limits are unchanged.
- **Launch clearance.** The airspace check bounded the ground at the map's highest point; on Triglav that is the
  1.8 km summit, so every slot failed. It now uses the proven local bound over the circuit's square
  (`ground_terrain.gd max_height_near`, option 4). On Triglav that bound is 8.8 m; flat fields return the same
  table-wide value as before. The launch inventory budget rose from 10,000 to 20,000 proxies: Triglav carries 16,930
  surveyed trees and buildings, which this check now examines. The static-trajectory checker (test-only) keeps its
  own 10,000-proxy work bound.
- Home, pause, the companions dialog and its messages name Triglav in all nine languages.

## Qualification matrix

`research/ai-companions/pilot_probe.gd --field-profile=triglav-tamar` flew the AFC-02 matrix on Triglav: calm and
gentle-practice, one to three aircraft, 120 simulated seconds each, in the field's air at 849.7 m. All 156 checks
passed. The [matrix](matrix/README.md) keeps the scenario metrics, one-second samples and seed allocations.

| Observation (six scenarios) | Triglav | Club field (AFC-02-R6) |
| --- | ---: | ---: |
| Local ground clearance | 37.64–87.60 m | 34.32–75.02 m |
| True airspeed | 14.59–16.00 m/s | 14.58–15.61 m/s |
| Maximum radial error | 4.13 m | 3.90 m |
| Minimum distance to the pilot | 90.05 m | 122.32 m |
| Minimum distance between companions | 119.34 m | 118.77 m |
| Maximum bank | 26.2° | 26.2° |

- **Clearance above the top band.** Each companion spawns at its band above the ground directly below it, which is up
  to 4.6 m above the pilot. It then settles onto its band above the pilot at most 0.8 m/s. After the first 10 s the
  top slot holds 84.3–86.2 m above the pilot.
- **Pitch saturation at spawn.** On Triglav the pitch demand saturates (full down) for about 0.08 s immediately after
  spawn, then stays within ±0.3. On Club field the largest demand is 0.76. The probe's travel gate (|input| ≤ 1)
  passes, but this transient is recorded here and was not characterised further.
- **Club field unchanged.** The same probe re-run on Club field reproduced the AFC-02-R6 matrix byte for byte: the
  scenario metrics and every one-second sample.
- **Repeatability.** The three-aircraft calm repeat on Triglav is bit-identical.

## Checks

| Check | Result |
| --- | --- |
| `test_companions_triglav.gd` | 27 checks, zero failures |
| `test_companions_profiles.gd` (pinned solver identity) | 52 checks, zero failures |
| Triglav pilot matrix | 156 checks, zero failures |
| Club pilot matrix re-run | 156 checks, zero failures; byte-identical to AFC-02-R6 |

The Triglav test covers:
- profile selection, and the refusal of a wrong field, an unlisted profile, the Club bands and an observation above
  the ceiling;
- refusal of sea-level air, other air, turbulence above the gentle limit and a wrong landscape;
- the local launch-clearance bound;
- 30 s of three companions over the meadow among the surveyed obstacles, holding 38.0–87.6 m above the ground, while
  the player waits on the strip.

## Limits

- This is headless software evidence. It does not establish physical realism or rendered performance.
- No player encounters were flown on Triglav. The avoidance logic is the one qualified on Club field.
- The ridge-lift and other spatial-wind presets stay refused for companions, as on Club field.
