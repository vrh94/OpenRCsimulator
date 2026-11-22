# Behavior manifest renewal, 2026-11-22 (weather dialog on surveyed fields)

The project owner approved companion renewal for simulator changes (2026-11-18) and asked on 2026-11-22 that the
weather dialog's elevation box be locked on fields with surveyed terrain.

## What changed

One of the sixteen behavior sources differs from the manifest accepted in `33ef32885`:

- `res://app_root.gd`: Home's weather dialog is opened with the selected field's surveyed elevation, so the dialog
  shows that height read-only and previews the air flown there (`ui/weather_dialog.gd`).

## Review

The change only adds an argument to the dialog's constructor. It does not touch companion admission, launch or status
integration, observation, seed allocation or the static checks. The weather saved by the dialog is unchanged on flat
fields, and on surveyed fields the saved elevation is kept. The solver identity is unchanged (no file under
`app/physics`, `app/sim` or `app/failures` changed).

## Result

| Item | Before | After |
| --- | --- | --- |
| `res://app_root.gd` source hash | `c903fb926e13…` | `eac3ed9959c3…` (see the manifest) |
| `behavior-manifest.json` SHA-256 (utf8-lf) | `9b96098da6ab39adfd869645afca3753ef9f80b7fa880c02622a972c5548a5a4` | `c1d87fff2c4b95afd090f170b1d7a345b1f643b0c6c40a0f32cc3c33ff4aa289` |
