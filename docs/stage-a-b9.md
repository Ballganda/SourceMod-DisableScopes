# Stage (a): per-client flag, b9 (ticket #9)

Plugin 0.0.b9. OnPlayerRunCmd exits on one per-client flag (`g_bHoldsRestricted`) unless the client is alive, in game and holds a restricted weapon with the plugin enabled. The flag is refreshed from weapon switch, equip and drop hooks, player_spawn and player_death, and every cvar change hook; classification runs once per refresh. Cvars are mirrored into bools by change hooks. m_iFOV is written only when the player is actually scoped.

## Cost (private server copy, 66 tick, 32v32, 3 runs of 30 s)

| Build | Scenario | us/client/tick |
| --- | --- | --- |
| b9 | no restricted weapon held | 0.111 (spread 28.6% of a 0.1 us mean, over the 25% margin) |
| b9 | all restricted weapons held | 2.227 (spread 11.6%) |
| Beta 6 | no restricted weapon held | 1.566 |
| Beta 6 | all restricted weapons held | 3.211 |

Target 0.76 us met. All-restricted cost is lower than Beta 6.

## Tests

- Server-state suite: 175 passed, 0 failed.
- Visual matrix: same pass/fail grid as Beta 6 and b8 (see `tests/client/baseline`). Every blocked case passes at 0 ms; the in-air blocked cases still fail at 50, 150 and 250 ms because the client predicts the scope for about one round trip before the server correction arrives.
- m_flNextSecondaryAttack is still written on every blocked tick: writing only on a press made the blocked cases fail at 0 ms too.
- Fixed `Invoke-VisualMatrix.ps1`, which threw "Argument types do not match" when any case failed.
