# Radio telemetry over USB serial (EdgeTX)

An EdgeTX radio can fly the simulator over its USB cable in **serial mode**, so the simulator can send flight telemetry back to the radio. The radio's flight screen then shows the simulated flight the way it shows a real one:
- battery, altitude, speeds, heading and attitude;
- home distance and direction;
- flight mode and arming;
- GPS position on the Kamnik and Triglav landscapes.

The values also appear as ordinary telemetry sensors, so EdgeTX voice alerts, logs and other scripts can use them.

It was built and tested for the RadioMaster Zorro (EdgeTX 2.12, 128 × 64 screen) and works with other EdgeTX 2.12 radios that have a 128 × 64 screen.

## Joystick mode or serial mode

EdgeTX's USB port is either a joystick or a serial port, never both.

| | USB Joystick | USB Serial (VCP) |
| --- | --- | --- |
| Sticks and switches | 8 axes and 24 buttons, sent as fast as the radio's mixer runs | CH1–8 as axes and CH9–16 as buttons, sent 20 times a second, because EdgeTX runs Lua every 50 ms |
| Telemetry on the radio | none | yes |
| Best for | fast FPV, 3D and racing | trainers, gliders, scale, long-range FPV practice, and learning the flight screen |

In serial mode the sticks arrive about 25–75 ms later than in joystick mode, and the delay varies. Use joystick mode when that matters.

In serial mode the simulator presents the radio exactly as it appears in joystick mode: same name, same USB ids, same SDL GUID, and the same channel scaling. Your calibration, switch assignments and controller profile carry over unchanged, and you can switch between the two modes without setting anything up again.

## Setup

**On the radio (once):**
1. Copy `SCRIPTS/TELEMETRY/flight.lua` and `simlnk.lua` from [`tools/radio/edgetx`](../tools/radio/edgetx/README.md) to the SD card.
2. **SYS → Hardware → USB-VCP: LUA.** The default, CLI, gives the port to EdgeTX's command line and the script receives nothing.
3. On the model you fly the simulator with, set **MDL → Display → Screen 1 → Script → `flight`**.

**Each time:**
1. Plug in the USB cable and choose **USB Serial (VCP)**.
2. Start the simulator. It finds the radio by itself: it opens only USB serial ports whose maker is "OpenTX" with ST's serial ids 0483:5740, which is EdgeTX's serial mode, and never a flight controller's port. The radio appears as a controller within a second or two, and its flight screen switches to **SIM**.

To disable the link, start the simulator with `--no-radio-serial`. It runs on macOS and Linux. Windows is not supported yet.

## What is sent

About 10 times a second, as ASCII lines that end in `*` plus a two-digit hex checksum (the sum of the payload bytes, modulo 256):

| Line | Fields |
| --- | --- |
| `A` | altitude above the pilot's ground (m), vertical speed (m/s), ground speed and airspeed (km/h), heading (°), pitch and roll (°) |
| `M` | flight mode as iNav's short text (`MANU`, `ANGL`, `HOR`, `RTH`, …), armed 0/1, flight time (s), throttle (%) |
| `B` | battery volts, amps, mAh used, % left (electric aircraft only), sent every second time |
| `N` | home distance (m), bearing to home (°), latitude and longitude (Kamnik and Triglav only), sent every second time |
| `I` | simulator and aircraft name, every fifth time, and also without a flight so the radio knows the link is up |

From the radio comes a `C` line with CH1–16 (each as three hex digits: the EdgeTX output + 1024, 0–2047) every Lua cycle, and an `H` line with the radio name and EdgeTX version once a second.

A value the flight doesn't have is sent as an empty field, never as zero. The simulator has no radio link, so it never sends RSSI or link quality.

Positions come from the landscape's D96/TM reference (EPSG:3794) and are converted to WGS84. Heading is relative to grid north, which differs from true north by less than 1° on both landscapes. Fictional fields send no position.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Nothing moves in the simulator; the radio's Link page shows *Sticks sent* but *Telemetry in* stays at 0 | The simulator isn't running, or was started with `--no-radio-serial`. |
| Nothing moves; the radio's flight screen isn't open, or the radio shows no **SIM** | USB-VCP is not LUA (a serial terminal shows EdgeTX's `>` prompt), or the model has no `flight` screen. |
| The radio connects, but sticks are reversed or off-centre | The joystick-mode calibration doesn't match this model's mixes. Recalibrate in the setup assistant; the result is saved for both modes. |
| Telemetry shows `--` for the battery | The aircraft is not electric. |

Code:
- `app/input/serial_radio_link.gd`: port helper, frames to joystick events, identity.
- `app/input/joypad_directory.gd`: the shared controller list.
- `app/sim/radio_telemetry.gd`: the telemetry lines and GPS conversion.
- `tools/radio/edgetx/SCRIPTS/TELEMETRY/simlnk.lua`: the radio side.

Tests:
- `app/tests/test_serial_radio_link.gd`
- `app/tests/test_radio_telemetry.gd`
- `tools/radio/edgetx/test/test_simlnk.lua`
