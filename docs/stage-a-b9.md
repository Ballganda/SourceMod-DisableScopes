# Stage (a): per-client flag, b9 (ticket #9)

Plugin 0.0.b9. OnPlayerRunCmd exits on one per-client flag (`g_bHoldsRestricted`) unless the client is alive, in game and holds a restricted weapon with the plugin enabled. The flag is refreshed from weapon switch, equip and drop hooks, player_spawn and player_death, and every cvar change hook; classification runs once per refresh. Cvars are mirrored into bools by change hooks.

Enforcement is split over the two command hooks:

- OnPlayerRunCmd strips secondary attack when the state before the command's movement is blocked.
- OnPlayerRunCmdPost judges the state the command ends in. In a blocked state it unscopes (m_iFOV written only when actually scoped) and holds m_flNextSecondaryAttack at least 0.6 s ahead, topping it up to 1.0 s only when it falls short (about one write per 0.4 s, not every tick). The weapon's own value is put back when the blocked state, the restricted weapon or the plugin rule ends.
- A jump while scoped is therefore unscoped in the command that left the ground (Beta 6 and b8 left one command zoomed in the air).

## Cost (first attempt, private server copy, 66 tick, 32v32, 3 runs of 30 s)

| Build | Scenario | us/client/tick |
| --- | --- | --- |
| b9 (first attempt) | no restricted weapon held | 0.111 (spread 28.6% of a 0.1 us mean, over bench.ps1's 25% margin) |
| b9 (first attempt) | all restricted weapons held | 2.227 (spread 11.6%) |
| Beta 6 | no restricted weapon held | 1.566 |
| Beta 6 | all restricted weapons held | 3.211 |

Not re-measured after the post-command hook was added. That hook exits on the same flag, and the blocked path now writes m_flNextSecondaryAttack about once per 0.4 s instead of every tick.

## Tests

- Server-state suite: 193 passed, 0 failed. New checks: unscoped in the command that left the ground; next-secondary-attack not resent on most blocked ticks; scope works again on landing with the weapon timers left as the plugin set them.
- Visual matrix: 41 of 60 (case, latency) results pass; Beta 6 and b8 pass 38.
- Now passing at every latency: on-ground rule blocks a ground scope, and a shot on the ground with the on-ground rule.
- Still failing: in-air blocked cases (AWP, scout, G3SG1, SG550, shot while jumping) at 50, 150 and 250 ms.
- Still failing: forced unscope (scoped on ground, then jump) at every latency, 55-305 ms of scope on screen; the server is unzoomed from the jump command on.
- Cause of both: the client predicts the scope (or keeps its own scope through a predicted jump) until the server's first write after the jump reaches it, about one round trip. Before the jump the server cannot network a value that blocks the scope only in the air without also blocking the allowed ground scope.
- `Invoke-VisualMatrix.ps1` threw "Argument types do not match" on its return line (`@()` of a generic List passed as an argument, PowerShell 5.1); fixed.
