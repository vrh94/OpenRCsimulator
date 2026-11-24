# EdgeTX scripts for the radio

Lua scripts for EdgeTX 2.12 radios with a 128 × 64 screen. They were written for the RadioMaster Zorro and also suit the Boxer, Pocket, TX12, MT12, Taranis X7/X9 Lite and similar radios. Copy the `SCRIPTS` folder onto the radio's SD card.

These radios have 1-bit black-and-white screens. The scripts use no colour or grey. Every line, point, rectangle and gauge is drawn with an explicit `FORCE` (black) or `ERASE` (white), because EdgeTX's default on these screens is XOR, which makes overlapping graphics cancel out. Readability on a 1-bit screen:
- The ground in the artificial horizon is a light dot texture.
- The aircraft symbol, pitch ladder and home arrow have white outlines.
- Text is opaque. The scripts are this project's own code; they follow the arrangement of popular telemetry screens without copying any of them.

| File | What it is |
| --- | --- |
| `SCRIPTS/TELEMETRY/flight.lua` | Flight screen. HUD page: flight mode, armed timer, TX battery, artificial horizon with pitch ladder, heading and home arrow, battery V, cell, A, mAh and gauge, altitude, vertical speed, ground speed and airspeed, home distance, messages. Also Link, Stats and Settings pages, voice alerts and statistics. |
| `SCRIPTS/TELEMETRY/simlnk.lua` | OpenRC simulator link, loaded by `flight.lua`. Over USB serial it sends the channels to the simulator and receives the simulator's flight data, which it shows on the flight screen and publishes as telemetry sensors. |

## Install

1. Connect the radio over USB and choose **USB Storage (SD)**. Copy `SCRIPTS/TELEMETRY/flight.lua` and `simlnk.lua` to the same folder on the SD card. On macOS use `COPYFILE_DISABLE=1 cp …` so no `._` files are left on the card.
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

## Simulator link (USB serial)

Simulator side, setup and troubleshooting: [Radio telemetry over USB serial](../../../docs/RADIO-SERIAL-LINK.md).

The radio's USB port works either as a joystick or as a serial port, never both. In serial mode, `simlnk.lua` carries the sticks and switches to the simulator and brings telemetry back:

- **Radio to simulator:** every Lua cycle (50 ms, so 20 times a second), a `C` line with CH1–CH16. Once a second, an `H` line with the radio name and EdgeTX version.
- **Simulator to radio:**
  - `B`: battery V, A, mAh, %;
  - `A`: altitude, vertical speed, ground and air speed, heading, pitch, roll;
  - `N`: home distance and direction, latitude and longitude;
  - `M`: mode, armed, flight time, throttle;
  - `I`: simulator and aircraft name.
- **Line format:** ASCII lines that end in `*` plus two hex digits (the sum of the payload bytes, modulo 256). An empty field means the simulator has no such value. The protocol is described at the top of the script.
- **Sensors on the radio:** created in a private id range (`0x5A00`+), so EdgeTX voice, logging and other scripts can use them: `RxBt`, `Curr`, `Capa`, `Bat%`, `Alt`, `VSpd`, `GSpd`, `ASpd`, `Hdg`, `Ptch`, `Roll`, `Dist` and `GPS`. The simulator has no radio link, so no RSSI or link-quality sensor is ever created.
- **Delay:** sticks reach the simulator at 20 Hz, 25–75 ms later than in joystick mode. For fast flying, use joystick mode.

Radio setup, done once:
1. **SYS → Hardware → USB-VCP: LUA**.
2. Select **Screen 1 → `flight`** on the model.
3. Plug in USB and choose **USB Serial (VCP)**.

## Tests

`lua tools/radio/edgetx/test/test_flight.lua [path/to/SOUNDS/en]` and `lua tools/radio/edgetx/test/test_simlnk.lua` run the scripts under a desktop Lua (5.2 or newer) against a mock of the EdgeTX 2.12 Lua API (`test/harness.lua`).

The mock draws into a 128 × 64 1-bit framebuffer the way EdgeTX does on these radios:
- the real flag values (`INVERS` equals `FORCE`, `RIGHT` equals `ERASE`);
- XOR as the default, line patterns and opaque text;
- EdgeTX's proportional fonts.

The fonts are EdgeTX's (GPLv2), so they are not stored in this repository. `python3 tools/radio/edgetx/test/edgetx_fonts.py` downloads them from EdgeTX v2.12.5, or reads them from a checkout with `--edgetx-src`, into `$TMPDIR/openrc_edgetx_fonts.lua`. Without that file the tests use fixed-width stand-ins and the text-width checks are only approximate. `H.art()` returns the frame as text art for inspection.

Scenarios: ELRS with iNav and with Betaflight, D16 with iNav (new and legacy sensor ids), D8, no telemetry, low battery, link loss, settings and statistics; for the link, the channel frames, parsing with split lines, bad checksums and empty fields, the sensors created, the timeout, and the flight screen fed by the simulator.

It checks:
- no Lua errors;
- every drawn item stays on the 128 × 64 screen, with integer coordinates, and no text overlaps;
- no graphic relies on XOR;
- the horizon frame is intact, the horizon line is continuous, and the aircraft symbol has its white outline;
- arming and mode callouts;
- unit conversions;
- that the settings survive a reload;
- with a `SOUNDS/en` folder given, that every played voice file exists.

EdgeTX runs Lua 5.2. Avoid Lua 5.3+ syntax: `//`, bitwise operators, `utf8`.
