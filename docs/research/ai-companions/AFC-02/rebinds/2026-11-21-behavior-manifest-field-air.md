# Behavior manifest renewal, 2026-11-21 (Triglav field air)

The project owner approved companion renewal for physics and simulator changes (2026-11-18). On 2026-11-21 the owner
decided that the Triglav field flies in the air at its real height.

## What changed

Two of the sixteen behavior sources differ from the manifest accepted in `f20be8c95`, both from `b9a403650`:

- `res://main.gd`: the airplane activity hands its session the weather as flown on the field
  (`physics/field_air.gd`). Flat fields, the Club field among them, get the selection unchanged.
- `res://app_root.gd`: Home learns the selected field's elevation so its conditions line shows the air flown.

## Review

Neither change touches companion admission, launch or status integration, observation, seed allocation or the static
checks. On the Club field the weather a companion copies from the player is byte-identical to before. Companions
still admit on the Club field only.

The solver identity was renewed separately because `sim/multirotor/session.gd`, `sim/airship/session.gd` and the new
`physics/field_air.gd` changed. All nine retained tapes replay byte-identically
([receipt](2026-11-21-ac1dadff-to-0b86e2be.json)).

## Result

| Item | Before | After |
| --- | --- | --- |
| `res://main.gd` source hash | `358ed86f49b0…` | `772315349f53…` (see the manifest) |
| `res://app_root.gd` source hash | `613229404819…` | `c903fb926e13…` (see the manifest) |
| `behavior-manifest.json` SHA-256 (utf8-lf) | `55b8767a34eac12d499a731d66b4bcf2c2991ec07fd49c2c8b4e222bdf912d93` | `9b96098da6ab39adfd869645afca3753ef9f80b7fa880c02622a972c5548a5a4` |
