# OpenRC Simulator — FPV fixed-wing fork

**An open-source RC flight simulator with an optional FPV mode for fixed-wing airplanes.** Connect a USB radio
(RadioMaster, DJI FPV Remote Controller 3 and others), a gamepad or the keyboard, and fly either from the pilot's
position on the field or through an onboard FPV camera with an OSD, a flight controller and a radio/video link model.

This repository ([vrh94/OpenRCsimulator](https://github.com/vrh94/OpenRCsimulator)) is a fork of
[bultodepapas/OpenRCsimulator](https://github.com/bultodepapas/OpenRCsimulator). It contains everything in the
upstream source plus the **FPV fixed-wing work** described below. There is **no packaged download of this fork yet**:
run it from source (see [Run from source](#run-from-source)). The upstream v0.2.7 release ZIPs
([below](#upstream-release-downloads)) do **not** include the FPV additions.

> **Beta / experimental.** Flight models use estimated data and still need independent measurements and pilot
> evaluation. Automated tests check consistency and regressions; they do not prove real-aircraft accuracy. The FPV
> additions never change the flight physics: the golden flight recordings stay bit-identical.

**[What this fork adds](#what-this-fork-adds)** · **[Aircraft](#aircraft)** · **[Other vehicles](#other-vehicles)** ·
**[Controllers](#controllers)** · **[Run from source](#run-from-source)** · **[Player guide](docs/FIRST-LAUNCH.md)** ·
**[Develop](#develop-and-contribute)** · **[License](#license)**

![Home screen with MoonRunner X99 at Club field](docs/media/ui-home-moonrunner-x99.png)

*Home screen (upstream capture, 28–29 October 2026, 1920×1080; [capture details](docs/media/README.md#readme-gallery)).*

## What this fork adds

All of it is optional: with the default settings the simulator flies as upstream does, and the chase/pilot views,
radio support and physics are unchanged. Everything is set under **Settings → Camera** and explained in the
[player guide](docs/FIRST-LAUNCH.md).

| Area | In this version |
| --- | --- |
| **Onboard FPV camera** (key **3**) | Camera on the airplane with field of view 70–150° (default 110°), uptilt −10…+30°, rigid or soft mount, flat / wide-angle / fisheye lens, video quality, camera shake, analog noise and motion blur. **FPV clean screen** hides the flight panels while flying FPV. |
| **Cockpit view** (**Shift+3**) | Seat a quarter of the length behind the nose with a generic canopy frame (no aircraft has a modelled cockpit yet). |
| **Look around** | Right-mouse head-look, **opentrack** head tracking (UDP 127.0.0.1:4242) and a **servo gimbal** driven by a radio knob/slider channel (pan and/or tilt). DJI's gimbal dial can tilt the camera. |
| **OSD** | Betaflight, INAV or ArduPilot style: battery V / % / A / mAh (electric models), timer, 3D GPS speed, altitude, distance, home arrow, link quality, heading, artificial horizon, flight mode, warnings, trip distance, mAh/km and remaining time/distance to a 20 % reserve. Every element can be switched off. |
| **Video link** | Analog video that breaks up with distance and behind hills, buildings and trees; 25–2500 mW transmitter and stock / patch / helical receiver antennas (about 6, 15 and 27 km at 2.5 W). |
| **Flight controller** (FC-1) | INAV / ArduPilot-style modes on the radio's flight-mode switch or **M / Shift+M**: Manual, Acro, Angle (FBWA), Horizon, Altitude hold (FBWB), Cruise, Loiter, Return to home. It moves the same control surfaces as the pilot; Manual is identical to flying without it. |
| **Radio link and failsafe** (FC-2) | Optional 2.4 GHz (ExpressLRS-like, about 6 km) or 900 MHz (about 30 km) link. Signal loss → return to home ("RX LOSS - RTH"), stick takeover when the link is back; optional RTH on video loss or low battery and a "BATT LOW FOR HOME" estimate. |
| **Long-range scenery** (FC-4) | Visual-only ring road, three towns, two farms and two wind farms 6.5–16 km from the club field to navigate by; the field patchwork follows the airplane in the FPV views. |
| **Units** | Metric by default in every language. |
| **Controllers** | DJI FPV Remote Controller 3 recognised as a radio (USB `2ca3:1021`, "DJI Virtual Joystick"); calibrated radios also drive the RC trucks; helicopter HUD names the keyboard key for every unassigned helicopter action. |
| **RC truck views** | Onboard FPV camera (3) and bumper camera (Shift+3) on the Bisonte MT8 and MONSTER CAR 2. |
| **Aircraft** | **Longreach 1800**, an original long-range twin-boom FPV airplane in the Skyhunter 1800 class, and **Dartwing 780**, an original fast flying wing in the FunJet class (see below). |

The step-by-step history is in the commit log (`FPV-1` … `FPV-10`, `UNITS-1`, `RADIO-DJI-1`, `FC-1` … `FC-4`,
`Step 15`, `Step 16`, `HELI-RADIO-1`, `RADIO-CAR-1`, `CAR-VIEW-1`) and in [the flight-controller plan](docs/plans/fixed-wing-flight-controller.md).

**Not in this version yet:** ArduPilot SITL, multiplayer, and a packaged
release of the fork. Shadows that look square in some interactive flights are an open issue.

## Aircraft

Home offers **ten fixed-wing airplanes and one helicopter**. The Ugly Stick (glow) is the reference model; all
others are **experimental**. Click a name for its guide, controls and modelling limits.

| Aircraft | Type | Notes |
| --- | --- | --- |
| [Ugly Stick](docs/UGLY-STIK-PLAN.md) | High-wing sport trainer · 1.52 m · .61 glow | Reference model, tricycle gear. |
| Ugly Stick · Electric 6S | Same airframe · 6S electric | Finite battery or ideal supply. |
| [Great Planes Extra 300S .60](docs/EXTRA-300-PLAN.md) | Low-wing aerobat · 1.63 m · .61 glow | Taildragger, finite fuel. |
| [P-51D Mustang 1/4](docs/P51-PLAN.md) | Giant-scale warbird · 2.82 m · 120 cc gasoline | Flaps, retracts. |
| [F4U-1D Corsair 1/4.5](docs/F4U-PLAN.md) | Giant-scale warbird · 2.78 m · Moki 250 radial | Flaps, retracts, folding wings, 13 paint schemes. |
| [Vantage Jet](docs/AVANTI-S-PLAN.md) | Sport jet · 2.00 m · JetCat P100-RX | Spooling turbine, flaps, retracts. |
| [Turbo Lumber Evolution](docs/TIMBER-INTEGRATION-PLAN.md) | High-wing STOL · 1.55 m · 4S electric | Fixed wheels. |
| [MoonRunner X99](tools/aircraft/moonrunner/README.md) | EPO flying wing · 2.12 m · 6S electric pusher | Elevons, no gear: hand launch or airborne start. |
| [Longreach 1800](research/twin-boom-1800/README.md) | Twin-boom FPV · 1.80 m · 4S electric pusher | **New in this fork.** Original design (not a replica) in the Skyhunter 1800 class: pod with nose camera, carbon booms, H-tail, hand launch, 4S 5000 mAh pack. Physics and 3D model come from one design file; numbers are estimates, not flight-validated; no paint kit yet. |
| [Dartwing 780](research/fast-delta-780/README.md) | Speed wing · 0.78 m · 4S electric pusher | **New in this fork.** Original design (not a replica) in the FunJet class: swept wing with elevons, two fins, about 200 km/h level top speed, 4S 2200 mAh pack, hand launch (hold some up elevator and level the wings, or use angle mode). Physics and 3D model come from one design file; numbers are estimates, not flight-validated; no paint kit yet. |
| [RC Helicopter Research Trainer](docs/HELICOPTER.md) | X-Cell .60 physics · HX-700 visual | Ground-pad or hover start; see the [radio start sequence](docs/HELICOPTER.md). |

Three O.S. glow installations of the Stik remain technical specimens ([glow engines](docs/GLOW-ENGINES.md)).
Aircraft terms: [AIRCRAFT-LICENSING](docs/AIRCRAFT-LICENSING.md).

<table>
  <tr>
    <td width="33%" align="center"><img src="docs/media/studio-jensen-das-ugly-stik-60.png" alt="Ugly Stik 60 studio view" width="288"><br>Ugly Stick</td>
    <td width="33%" align="center"><img src="docs/media/studio-moonrunner-x99.png" alt="MoonRunner X99 studio view" width="288"><br>MoonRunner X99</td>
    <td width="33%" align="center"><img src="docs/media/studio-p51d-mustang-120.png" alt="P-51D Mustang studio view" width="288"><br>P-51D Mustang</td>
  </tr>
</table>

**Helicopter with a radio:** pull the collective fully down and press Continue, set the stick to about 17 % (the
HUD shows the target and the current pitch), press **B** to arm and **H** to release the hold, wait for GOVERNED.
A spring-centred throttle (DJI) sits at about +5.7° pitch, so set it to stay put for helicopters.

## Other vehicles

Home's vehicle list also has the experimental **Bisonte MT8** and **MONSTER CAR 2** RC trucks on their own driving
course ([RC trucks](research/rc-monster-truck/README.md)). In this fork they can be driven with a **calibrated RC radio**
(aileron steers, elevator forward/back drives and reverses; DJI remotes work too) as well as a gamepad or the keyboard,
and they have an **onboard FPV camera** (key **3**, using the FPV camera settings) and a **bumper camera**
(**Shift+3**) besides chase, driver's stand, orbit and circuit overview. There is also a [5 m RC blimp](docs/research/rc-airship/BL-12/README.md)
and an [FPV quad with a three-lap gate race](docs/research/drone-racing/M1-M3-2026-11-11/README.md). They use
estimated data.

## Controllers

| Controller | Getting ready |
| --- | --- |
| **USB RC radio** (RadioMaster, Jeti, …) | USB joystick mode, RF module off. Controls → **Set up this device…** → radio calibration. Move the throttle away from low and back to low to arm. Rates and curves stay on your radio. |
| **DJI FPV Remote Controller 3** | USB-C data cable; it appears as "DJI Virtual Joystick" and is treated as a radio. Hold the throttle fully **down** through every calibration step, because the stick springs back to the middle. Live qualification with the hardware is still open. DJI motion controllers are not supported. |
| **Gamepad** | Mode 2 starting layout; remap in Controls. |
| **Keyboard** | Arrows: pitch/roll · A/D: rudder · W/S: throttle · C / Shift+C: views · 3 / Shift+3: FPV / cockpit · M: flight mode · Esc: pause · R: restart. |

Assign the **Flight mode** switch, gimbal channels and helicopter arm/hold in Controls → Extra channels / Buttons.
[Full control reference](docs/FIRST-LAUNCH.md#3-fly).

## Run from source

Requires Git, Bash, curl, unzip and Python 3. The pinned engine is the official **Godot 4.8-beta2** prerelease,
downloaded and verified by `app/get-godot.sh` (Linux x86_64, Windows x86_64 under Git Bash, macOS ARM64).

```sh
git clone -c core.autocrlf=false https://github.com/vrh94/OpenRCsimulator.git
cd OpenRCsimulator
"$(app/get-godot.sh)" --headless --path app --audio-driver Dummy --import   # first time only
"$(app/get-godot.sh)" --path app                                           # start the simulator
```

More in [developer setup](docs/TOOLS.md#developer-setup).

### Upstream release downloads

The packaged **upstream v0.2.7** release does not contain this fork's FPV work:

| Platform | Download |
| --- | --- |
| **Windows · x86_64** | [Download ZIP](https://bultodepapas.github.io/OpenRCsimulator/en.html?download=windows&release=v0.2.7&utm_source=github&utm_medium=referral&utm_campaign=readme&utm_content=download_windows#download) |
| **Linux · x86_64** | [Download ZIP](https://bultodepapas.github.io/OpenRCsimulator/en.html?download=linux&release=v0.2.7&utm_source=github&utm_medium=referral&utm_campaign=readme&utm_content=download_linux#download) |
| **macOS · Apple Silicon / Intel** | [Download ZIP](https://bultodepapas.github.io/OpenRCsimulator/en.html?download=macos&release=v0.2.7&utm_source=github&utm_medium=referral&utm_campaign=readme&utm_content=download_macos#download) |

## Develop and contribute

The application is in **`app/`** (Godot 4.8-beta2, GDScript; custom float64 6-DoF kernel at a fixed 240 Hz with RK4;
optional C++/GDExtension native backends). Aircraft data use the validated `openrc-aircraft v2` format and are
generated by Python pipelines; see the [aircraft contract](docs/AIRCRAFT_CONTRACT.md) and
[architecture](docs/STACK.md).

Run one test:

```sh
cd app
python3 ../tools/godot/run_checked.py --timeout 600 -- "$(../app/get-godot.sh)" --headless --path . \
  --audio-driver Dummy --script res://tests/test_twin_boom_1800.gd
```

Unplug joysticks before running the test suite: some tests otherwise read the physical controller. Tool index:
[docs/tools](docs/tools/README.md) · [documentation map](docs/README.md) · [contributing](CONTRIBUTING.md).

## Upstream project and acknowledgments

OpenRC Simulator is created and maintained upstream by
[bultodepapas](https://github.com/bultodepapas/OpenRCsimulator); its README lists the project's sponsors, manufacturer
permissions and donation link. Manufacturer permission scopes for product representations are recorded in
[site/BRANDS.md](site/BRANDS.md). The FPV fork work was developed with Claude Code.

## License

Project code is [MIT](LICENSE). Models, recordings, brand marks and other assets keep their own terms:
[aircraft permissions](docs/AIRCRAFT-LICENSING.md), [landscape provenance](assets/landscape/PROVENANCE.json),
[scenery provenance](assets/scenery/PROVENANCE.json), [field credits](app/assets/landscape/UPGRADE_CREDITS.md),
[tree license](app/assets/landscape/trees/LICENSE.txt) and [media provenance](docs/media/README.md).
