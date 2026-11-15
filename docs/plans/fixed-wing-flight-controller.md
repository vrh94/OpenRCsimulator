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

## Next

- 14b: distant landmarks for long-range flight (the world is empty beyond about 5 km).
