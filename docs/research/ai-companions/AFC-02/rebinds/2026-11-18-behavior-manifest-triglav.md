# Behavior manifest renewal, 2026-11-18 (Triglav solid terrain, step 21b)

Companion renewal for physics and simulator changes is approved by the project owner (2026-11-18).

## What changed

Three of the sixteen behavior sources differ from the manifest accepted in `0d46200f3`, all from step 21b
(`dc6722662`, solid terrain for the Triglav landscape):

- `res://app_root.gd`: Home offers the runway start on solid-terrain fields that author their own strip
  (`_runway_available`); Natural Random gets its own availability flag and stays on the Club field only.
- `res://data/field_loader.gd`: an optional root `terrain` block (baked grid paths and the D96/TM origin). Fields
  without it, the Club field among them, normalize exactly as before.
- `res://scenery/collision_world.gd`: the finishing half of the inventory build (damage profiles, sort, validation,
  broadphase, identity) moved unchanged into `_finalize`, with `from_proxies`, `box_proxy` and `capsule_proxy` added
  so a landscape can supply survey obstacles. `build()` produces the same inventory.

## Review

No hunk touches companion admission, launch or status integration, observation, seed allocation or the static checks.
The Club field, its obstacle inventory and the companions' airspace are unchanged; companions still admit on the Club
field only.

The solver identity was renewed separately with byte-identical replays of all nine retained tapes
([receipt](2026-11-18-99de8a38-to-ac1dadff.json)).

## Result

| Item | Before | After |
| --- | --- | --- |
| `res://app_root.gd` source hash | `d501f1b06bb9…` | `613229404819…` (see the manifest) |
| `res://data/field_loader.gd` source hash | `3b6f797fa1a8…` | `e9e1c1a10b21…` (see the manifest) |
| `res://scenery/collision_world.gd` source hash | `9eeae928cec7…` | `0ed67337f262…` (see the manifest) |
| `behavior-manifest.json` SHA-256 (utf8-lf) | `e88320dbc4fd1d2dcef909ff0ada1158499b67d8ec956a7d7fb8a806eb70d8a9` | `55b8767a34eac12d499a731d66b4bcf2c2991ec07fd49c2c8b4e222bdf912d93` |
