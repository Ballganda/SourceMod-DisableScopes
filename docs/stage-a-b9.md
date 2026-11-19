# Stage (a): per-client flag, b9 (ticket #9)

Plugin 0.0.b9. OnPlayerRunCmd exits on one per-client flag (`g_bHoldsRestricted`) unless the client is alive, in game and holds a restricted weapon with the plugin enabled. The flag is refreshed from weapon switch, equip and drop hooks, player_spawn and player_death, and every cvar change hook; classification runs once per refresh. Cvars are mirrored into bools by change hooks.

Enforcement is split over the two command hooks:

- OnPlayerRunCmd strips secondary attack when the state before the command's movement is blocked.
- OnPlayerRunCmdPost judges the state the command ends in. In a blocked state it unscopes (m_iFOV written only when actually scoped) and holds m_flNextSecondaryAttack at least 0.6 s ahead, topping it up to 1.0 s only when it falls short (about one write per 0.4 s, not every tick). The weapon's own value is put back when the blocked state, the restricted weapon or the plugin rule ends.
- A jump while scoped is therefore unscoped in the command that left the ground (Beta 6 and b8 left one command zoomed in the air).

## Cost (cssds_t9 copy, port 27165, 66 tick, 32v32, 3 runs of 30 s, absolute spread margin 0.3 us)

| Build | Scenario | us/client/tick | Spread (max - min) | Tickrate held |
| --- | --- | --- | --- | --- |
| b9 | no restricted weapon held | 0.299 | 0.009 us | yes |
| b9 | all restricted weapons held | 2.505 | 0.029 us | yes |
| Beta 6 | no restricted weapon held | 1.566 | | |
| Beta 6 | all restricted weapons held | 3.211 | | |

- Target 0.76 us met; all-restricted cost is lower than Beta 6.
- The first attempt measured 0.111 us with no restricted weapon; the post-command hook adds a second exit-on-flag call per command.
- `bench.ps1` now judges repeat runs by an absolute spread (`-MarginUs`, default 0.3 us) instead of 25% of the mean, which failed on a ~0.1 us mean.

## Tests

- Server-state suite: 193 passed, 0 failed. New checks: unscoped in the command that left the ground; next-secondary-attack not resent on most blocked ticks; scope works again on landing with the weapon timers left as the plugin set them.
- Visual matrix: 60 of 60 (case, latency) results pass under the relaxed criterion the user approved for issues #7 and #9.
- Relaxed criterion: a blocked scope may show within one round trip (latency plus 100 ms) of the key that starts the block, and none after it; the server never zooms in a blocked state; a shot in a blocked state is unzoomed.
- Under the old criterion (no scoped screen time at all) the same build passed 41 of 60, against 38 for Beta 6 and b8.
- What remains on screen: the client predicts the scope (or keeps its own scope through a predicted jump) until the server's first write after the jump reaches it, about one round trip.
- `Invoke-VisualMatrix.ps1` threw "Argument types do not match" on its return line (`@()` of a generic List passed as an argument, PowerShell 5.1); fixed.
