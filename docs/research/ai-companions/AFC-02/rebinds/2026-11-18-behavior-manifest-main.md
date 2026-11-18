# Behavior manifest renewal, 2026-11-18 (main.gd)

Approved by the project owner on 2026-11-18 ("Yes" to renewing the AI-companion manifest).

## What changed

Of the sixteen behavior sources, only `res://main.gd` differed from the manifest accepted in `e488ef765`
(normalized SHA-256 `34fb8d66…` to `358ed86f49b0…`). The difference is the fork's FPV and flight-controller work,
`FPV-1` … `FPV-10`, `FC-1` … `FC-4` (commits `5cc73b437` … `151271f44`):

- command-line options for FPV captures (lens, video, OSD, link, head-look, flight-controller mode);
- the player's onboard FPV view, lens, OSD, cockpit frame and clean screen;
- the FPV video link and the RC link model (off by default), and the failsafe that hands the player's aircraft to its
  flight controller (opt-in in Settings › Camera › Flight controller);
- the player's flight-mode switch (manual by default) and head-look.

## Review

No hunk touches companion admission, launch or status integration, observation, seed allocation or the static checks:
the diff names no companion, manager, airspace, traffic, fleet or seed symbol, and every new path acts on the player's
session, camera or presentation only. With the flight controller in its default manual mode and the RC link off, the
player's commands reach the solver unchanged.

The solver identity was renewed separately with byte-identical replays of all nine retained tapes
([receipt](2026-11-18-a81c2b2d-to-99de8a38.json)).

## Result

| Item | Before | After |
| --- | --- | --- |
| `res://main.gd` source hash | `34fb8d664902…` | `358ed86f49b0d…` (see the manifest) |
| `behavior-manifest.json` SHA-256 (utf8-lf) | `7c4909c8db82ec5ab5d622e716fa129719d988a8840421d28b721af7f9ca4b50` | `e88320dbc4fd1d2dcef909ff0ada1158499b67d8ec956a7d7fb8a806eb70d8a9` |

Evidence: the `test_companions_*` suites pass after the renewal (run 2026-11-18).
