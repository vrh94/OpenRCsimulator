# EdgeTX scripts for the radio

Lua scripts for EdgeTX 2.12 radios with a 128 × 64 screen. They were written for the RadioMaster Zorro and also suit the Boxer, Pocket, TX12, MT12, Taranis X7/X9 Lite and similar radios. Copy the `SCRIPTS` folder onto the radio's SD card. The scripts are this project's own code; they follow the arrangement of popular telemetry screens without copying any of them.

| File | What it is |
| --- | --- |
| `SCRIPTS/TELEMETRY/flight.lua` | Flight screen. HUD page: flight mode, armed timer, TX battery, artificial horizon with pitch ladder, heading and home arrow, battery V, cell, A, mAh and gauge, altitude, vertical speed, ground speed and airspeed, home distance, messages. Also Link, Stats and Settings pages, voice alerts and statistics. |

## Install

1. Connect the radio over USB and choose **USB Storage (SD)**. Copy `SCRIPTS/TELEMETRY/flight.lua` to the same folder on the SD card. On macOS use `COPYFILE_DISABLE=1 cp …` so no `._` files are left on the card.
2. Eject the card, then on the radio go to **MDL → Display → Screen 1 → Script → `flight`**.
3. From the main screen, press **PAGE** (or long-press it) to open the screen.

## Use

- **Wheel:** HUD → Link → Stats.
- **ENTER:** opens the settings:
  - cell count (auto, or 1–8 S);
  - low and critical cell voltage (3.50 / 3.30 V);
  - battery sensor;
  - arming source: auto (telemetry), a switch, or throttle;
  - voice alerts on or off;
  - LQ and RSSI warning levels.

  The wheel moves through the settings, ENTER edits one, EXIT saves. Settings are kept per model in `SCRIPTS/TELEMETRY/flight.cfg`.
- **Long ENTER on Stats:** resets the statistics and the armed timer.

## Telemetry it reads

It finds the sensors present (MDL → Telemetry → Discover new) and shows only values that exist.

| Link | Sensors |
| --- | --- |
| ELRS / Crossfire (CRSF) | `RQly`, `1RSS`, `2RSS`, `RSNR`, `RFMD`, `TPWR`, `RxBt`, `Curr`, `Capa`, `Bat%`, `FM`, `GPS`, `GSpd`, `Alt`, `VSpd`, `Hdg`, `Sats`, `Ptch`, `Roll` |
| FrSky D16 / SmartPort (also ACCESS) | `RSSI`, `RxBt`, `VFAS`, `A4`, `Curr`, `Fuel`, `Alt`, `VSpd`, `GSpd`, `ASpd`, `Hdg`, `GPS`; iNav's `470`/`480` (formerly `Tmp1`/`Tmp2`) for mode, arming, GPS fix and satellites, `0420` for home distance, `0430`/`0440` for pitch and roll |
| FrSky D8 | `RSSI`, `A1`, `A2` (plus hub sensors when the flight controller sends them) |

- **Armed state:**
  - CRSF `FM`: iNav sends `OK`, `WAIT` or `!ERR` while disarmed; Betaflight adds `*` while disarmed.
  - iNav's `470` sensor.
  - Otherwise the switch chosen in the settings, otherwise throttle above 5 %.
- **Home:** the first GPS position after arming.
- **Voice alerts** (EdgeTX's standard English files): armed and disarmed, mode changes (acro, manual, RTH, cruise, waypoint, landing, position hold, loiter, horizon, turtle, failsafe), low and critical battery (critical also vibrates), and low LQ or RSSI.
- **Units:** metric.

## Tests

`lua tools/radio/edgetx/test/test_flight.lua [path/to/SOUNDS/en]` runs the script under a desktop Lua (5.2 or newer) against a mock of the EdgeTX 2.12 Lua API (`test/harness.lua`).

Scenarios: ELRS with iNav and with Betaflight, D16 with iNav (new and legacy sensor ids), D8, no telemetry, low battery, link loss, settings and statistics.

It checks:
- no Lua errors;
- every drawn item stays on the 128 × 64 screen, and no text overlaps;
- arming and mode callouts;
- unit conversions;
- that the settings survive a reload;
- with a `SOUNDS/en` folder given, that every played voice file exists.

EdgeTX runs Lua 5.2. Avoid Lua 5.3+ syntax: `//`, bitwise operators, `utf8`.
