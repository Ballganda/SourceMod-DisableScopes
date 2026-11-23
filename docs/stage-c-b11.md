# Stage (c): hot-path cuts, b11

Plugin 0.0.b11. Same design and enforcement as b9 (see `stage-a-b9.md`); only the per-command path changed.

## Changes

- Send-prop offsets are looked up once in `OnPluginStart` (`FindSendPropInfo`), and the per-command path uses `GetEntData*` / `SetEntData*` instead of the by-name natives. Covered: `m_fFlags`, `m_hActiveWeapon`, `m_iFOV`, `m_iDefaultFOV`, `m_flNextSecondaryAttack`. Writes pass `changeState = true`, so the value is still networked. The plugin fails to load if an offset is missing.
- The unscope check is skipped while the hold on secondary attack is steady. Steady means the hold was in place before this command and the timer still holds the value the plugin wrote. In that window the weapon cannot zoom. A shot or reload resets the timer, which makes the hold unsteady, so the check runs in that command.
- The active weapon is read by offset (`GetEntDataEnt2`), not cached. Every command still sees the weapon the game holds, even one removed without a drop hook.
- The unscope writes (`m_iFOV`, `m_zoomLevel`, `m_bResumeZoom`) still use the by-name natives; they run only in the command that unscopes.

## Cost (cssds_bench, port 27175, 66 tick, 32v32, 3 runs of 30 s, absolute spread margin 0.3 us, 2026-11-23)

b9 and b11 were measured on the same day on the same server copy. Another project's srcds (`cssds_botreg_t36`, then `_t38`) ran on the PC throughout.

| Build | Scenario | us/client/tick (mean of 3) | Runs | Spread | Tickrate held |
| --- | --- | --- | --- | --- | --- |
| b9 | no restricted weapon held | 0.384 | 0.419, 0.366, 0.367 | 0.053 us | no (63.78; one run 60.64) |
| b11 | no restricted weapon held | 0.377 | 0.363, 0.407, 0.362 | 0.046 us | yes (65.82) |
| b9 | all restricted weapons held (first try) | 3.516 | 3.629, 3.770, 3.150 | 0.620 us, over the margin | no (60.55; one run 52.81) |
| b9 | all restricted weapons held (rerun) | 3.566 | 3.319, 3.573, 3.804 | 0.485 us, over the margin | yes (65.93) |
| b11 | all restricted weapons held | **1.201** | 1.158, 1.191, 1.254 | 0.095 us | yes (65.94) |

- With all restricted weapons held, b11 costs 66% less than b9 measured the same day (1.201 against 3.566 µs).
- With no restricted weapon held, the cost is unchanged (0.377 against 0.384). That path was already just the flag check.
- Both b9 restricted cells print RESULT: FAIL: their runs differ by more than 0.3 µs. b11's runs agree within 0.1 µs.
- Today's b9 numbers run about 1.0 µs (restricted) and 0.1 µs (none) above the 2026-11-20 figures on `cssds_t9` (2.505, 0.299). Comparisons across days and server copies are not like for like. Against Beta 6's 3.211 µs from `baseline-cost.md`, b11 is about 63% lower, but Beta 6 was not rerun today.

## Bench tooling

- `bench.ps1 -Build b9` added (commit 162c83a).
- `-Build beta6` read `main`, which now holds b9. It now reads f2fcaeb, the last commit with the 0.0.b6 source at `scripting/disablescopes.sp`. The tag `v0.0.b6-beta` keeps the file at `sm_disablescopes.sp`, so it cannot be used directly.

## Tests

- Server-state suite (cssds_t9, port 27179): 193 passed, 0 failed.
- The visual matrix was not run. Enforcement timing is unchanged from b9, so the server-state suite covers the change.
