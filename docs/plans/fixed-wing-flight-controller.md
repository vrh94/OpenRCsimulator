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

## Next

- FC-2: failsafe → RTH on video or radio link loss; OSD home distance and battery-reserve warnings.
- FC-3: long-range experience on the 40 km ground.
