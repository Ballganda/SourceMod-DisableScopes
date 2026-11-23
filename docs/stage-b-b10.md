# Stage (b): event-driven prototype, b10 (ticket #11)

Decision: **rejected**. b9 stays the release; `scripting/disablescopes.sp` still builds 0.0.b9. The prototype is kept as `tests/spike/disablescopes_b10_prototype.sp` (reports 0.0.b10; not built by `build.ps1`).

Prototype: no per-tick code. No `OnPlayerRunCmd` or `OnPlayerRunCmdPost`. Enforcement runs only on state transitions:

- `SDKHook_GroundEntChangedPost` (ground change), weapon switch, equip and drop, player_spawn, player_death, every cvar change.
- `weapon_fire` and `weapon_reload`, because the game sets the next-secondary-attack time itself on those.
- In a blocked state the weapon's next-secondary-attack time is pushed 100000 s ahead once and put back when the block ends; a scoped player is unscoped.

## What the game does (spike `tests/spike/nsa_spike.sp`, cssds_t7, port 27177, no DisableScopes loaded)

| Action | Resets next-secondary-attack? | When, relative to its event |
| --- | --- | --- |
| Deploy (switch to the weapon) | yes, to the deploy time (scope allowed at once) | no event; the switch post hook runs after it |
| Reload | yes, to the end of the reload (2.6 to 4.7 s) | before `weapon_reload`: re-applied in the handler |
| Fire | yes, to shot time plus cycle (0.06 s AUG/SG552, 0.2 s autos, 0.95 s scout, 1.2 s AWP) | after `weapon_fire`: re-applied next frame |

- The AWP deploy row kept the sentinel; it was the first weapon, and the switch back likely did not happen. The other five weapons reset on deploy.
- `SDKHook_GroundEntChangedPost` runs before the new ground entity is stored: inside the hook, `m_hGroundEntity` and `FL_ONGROUND` still hold the old state; one frame later they hold the new one.
- So the hook knows a landing at once (old state in the air). Leaving the ground is known at once only for a jump (jump pressed this command). A ledge fall or a velocity launch is settled next frame.

## Measurements of the prototype

| Channel | Result | b9 |
| --- | --- | --- |
| Cost, 32v32, no restricted weapon held (cssds_bench, port 27175, 3 runs of 30 s) | 0.000 us/client/tick (no plugin call in the window) | 0.299 |
| Cost, 32v32, all restricted weapons held | 0.000 us/client/tick (no plugin call in the window) | 2.505 |
| Visual matrix, 0/50/150/250 ms (cssds_t9, port 27179) | 60 of 60 pass (relaxed round-trip criterion) | 60 of 60 |
| Server-state suite (cssds_t9, port 27179) | **138 passed, 55 failed** | 193 passed |

The visual and cost criteria are met; the server-state criterion is not, so the prototype is rejected.

## Failing server-state cases

- 33 cases fail only on `attack2=1`, with the field of view unzoomed (90, or 0, which the suite also reads as unzoomed). The suite's blocked verdict needs secondary attack stripped from the command, and only a per-command input hook can do that. The weapon timer did stop the zoom.
  - `rule`: each of the six restricted weapons in jump, ladder and water (in-air rule), and on the ground (on-ground rule): 24 cases.
  - `after respawn: awp, jump`.
  - `mid-round <cvar> on again` in water for enable, awp, scout, autosnipers, weaksnipers, inair (6 cases); `mid-round sm_disablescopes_onground on` and `on again` (AWP, ground).
- 21 cases are real zooms in a blocked state (fov 40 or 55).
  - Every one follows the suite's state step, which zeroes the weapon's timers while the bot is already in a blocked state (air to air, water to water), so there is no ground transition for the prototype to react to.
  - `rule`, crouch-jump and ledge fall, each of the six weapons (12 cases): the previous jump or crouch-jump had not landed yet.
  - `after switch`, `after reload`, `after drop and pickup`: awp, jump (the bot was still in the air from the setup jump).
  - `mid-round <cvar> on` in water for enable, awp, scout, autosnipers, weaksnipers, inair (6 cases).
- 1 case is a knock-on: `mid-round sm_disablescopes_weaksnipers off` (AUG, water) expected allowed and saw fov 90, because the AUG was still zoomed from the failure before it, and the scope press toggled the zoom off.
- No fix exists within "no per-tick code": stripping secondary attack needs a per-command hook, and seeing a timer some other code changes needs either polling or a per-tick hold. So the failures were not fixed and the suite was not rerun.

## Other limits seen

- A ledge fall or a push off the ground (no jump pressed) is settled one frame late; a client running several commands in one server frame could zoom on the server in that window.
- After a shot in a blocked state the hold returns next frame; the AUG and SG552 cycle (0.06 s) is short enough that a client at high latency could predict a scope before the hold reaches it. The visual matrix covers AWP, scout, G3SG1 and SG550 only.

## Harness change

- `bench.ps1` failed an event-driven build with "the plugin does not appear in the vprof report". The bench helper now logs `plugin=1` when the plugin under test is running, and a running plugin with no call in the window counts as 0 us instead of an error.
