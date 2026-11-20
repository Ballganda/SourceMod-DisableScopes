# Stage (a): per-client flag, b9 (ticket #9)

## Oracle gate (issue #10, regs1, 2026-11-20)

All seven acceptance criteria of #10 hold. The one open item is the repeat-run spread of the all-restricted cost cell (see Cost).

| Criterion | Result | Evidence |
| --- | --- | --- |
| b9 is the loaded build | yes | `sm plugins list`: `24 "[CS:S]sm_disablescopes" (0.0.b9)`; `sm_disablescopes_version` 0.0.b9 |
| Beta 6 kept beside b9, rollback demonstrated | yes | see Rollback |
| Every visual case passes at real ping | 15 of 15 | ping 56 to 60 ms, see Visual matrix |
| Cost at 10v10, both scenarios | recorded | see Cost |
| No new SourceMod error log lines | none | no `errors_*.log` existed before or after (`Check-RemoteDeploy.ps1 -Since`) |
| Test helper absent afterwards | yes | `-ExpectNoHelper`: none loaded, no file on disk; plugin list below |
| Server cvars restored | yes | `CvarSnapshot.ps1 -Action Diff`: all 15 cvars match the pre-run snapshot |

### Rollback

- Beta 6 binary: `plugins/disabled/sm_disablescopes.smx.beta6-rollback` (sha1 5daeacd6...), unchanged on the server.
- b9 binary: `plugins/sm_disablescopes.smx` (sha1 fcac6d4a...).
- Rollback: b9 copied aside, Beta 6 copied over it, `sm plugins reload sm_disablescopes`; the plugin list showed `(0.0.b6) by abnerfs, Bara, BallGanda`.
- `sm_disablescopes_version` still read 0.0.b9 under Beta 6: the cvar keeps the value b9 registered. Read the plugin list, not the cvar, to tell the builds apart.
- Revert: b9 copied back (same sha1), reloaded; the plugin list showed `(0.0.b9) by BallGanda`. The aside copy was deleted.
- Plugin cvars were the same before and after both reloads.

### Visual matrix (real ping)

`Invoke-VisualMatrix.ps1 -Remote regs1`, run `gate-matrix-8`, map cs_office, 0 other humans.

- Ping, from the client's own `status` row: 56 to 60 ms (2 samples, mean 58); blocked-scope allowance 160 ms (ping plus the approved 100 ms).
- 15 of 15 cases pass under the criterion approved for #7 and #9, unchanged.
- No zoomed server command in any blocked state.
- Blocked cases showed 0 to 77 ms of scope, all within the allowance.
- Each shot case: the server registered 1 shot, and the client's clip counter changed at least once.
- 43 keys were posted to the game window: a Windows firewall prompt for another test's srcds held the foreground for the whole run. Nobody answered it.

| Case | Result | Screen scoped in window |
| --- | --- | --- |
| AWP ground scope (allowed) | pass | 1940 ms |
| AWP jump then scope (blocked in air) | pass | 31 ms |
| AWP scoped on ground then jump (forced unscope) | pass | 77 ms |
| AWP ground scope blocked by on-ground rule | pass | 0 ms |
| AWP jump then scope allowed (in-air rule off) | pass | 2145 ms |
| AWP unrestricted (awp cvar off), jump then scope | pass | 2116 ms |
| scout ground scope (allowed) | pass | 1973 ms |
| scout jump then scope (blocked in air) | pass | 31 ms |
| G3SG1 ground scope (allowed) | pass | 1957 ms |
| G3SG1 jump then scope (blocked in air) | pass | 30 ms |
| SG550 ground scope (allowed) | pass | 1975 ms |
| SG550 jump then scope (blocked in air) | pass | 31 ms |
| AWP shot while jumping, scope blocked | pass | 31 ms; shots 1 server, 1 client |
| AWP shot on ground, on-ground rule blocks scope | pass | 0 ms; shots 1 server, 1 client |
| AWP scoped shot on ground (allowed) | pass | 1158 ms; shots 1 server, 3 client |

Tooling faults found and fixed at their cause (the pass criteria are unchanged):

- Bots on the live server killed the probe client before it was armed or during a case. The remote helper sets `bot_quota 0` for the run (restored from the snapshot), and it re-places the client until it is alive on CT.
- The helper's csv was reopened with "w" on every map change, which cut the rows the runner had counted. The remote build now appends.
- `g_ready` survived a reconnect, so a second run never logged its own ready row. It is reset on disconnect.
- No ping sample: `+name dsc_probe` has no effect because Steam sets the name. The ping alias now runs `name` before `status`, and the runner matches the row by that name.
- The process was not DPI aware: at 175% scaling it read the 1024x768 window as 585x438, so every screen read missed. `ScopeProbe` calls `SetProcessDPIAware`, and the runner refuses a client area that is not 1024x768.
- The clip-counter test needed red above 110, but the digits sometimes drew dim (103,74,27), and then 0 pixels read as lit. The test is now by hue (300 to 420 pixels lit on every baseline), and the runner refuses a baseline under 150.
- The right-handed view model covered the clip counter: `cl_righthand 0` (`r_drawviewmodel` is a cheat cvar).
- The client could not connect: another local srcds held `<LAN IP>:27005`, the client's default port, so the server's replies went to it. The client now gets a free `+clientport`, and a failed connect is relaunched up to 3 times.
- Keys were lost while another window held the foreground. `Key` checks the foreground and otherwise posts WM_KEYDOWN/UP to the game window.
- `engine_no_focus_sleep 0`: without the foreground the client slept 50 ms a frame, and blocked scopes showed up to 125 ms past the allowance (run `gate-matrix-6`).
- The view looked up at a dark ceiling on cs_office, so the unscoped baseline read as scoped. The helper takes `dsc_view`, and the runner steps through candidate views until all four edge points are at least 24 bright.
- Deploy timing: each case waits until the server's csv shows the case's weapon ready to scope. Where the on-ground rule blocks the scope, it waits for 2 s of commands with the weapon instead.
- The helper must run after the plugin under test (forwards run in load order), so the runner refuses a helper loaded before it.

### Cost (10v10, 66 tick, 3 runs of 30 s, AI-less fakes)

| Build | Scenario | us/client/tick (mean of 3) | Runs (CPU steal in the window) | Spread | Tickrate held |
| --- | --- | --- | --- | --- | --- |
| b9 | no restricted weapon held | 0.670 | 0.717 (20%), 0.693 (14%), 0.598 (16%) | 0.119 us, within the 0.3 us margin | yes (66.00) |
| b9 | all restricted weapons held | 7.642 | 7.143 (16%), 9.078 (28%), 6.705 (18%) | 2.373 us, over the margin | yes (65.11) |

- Both scenarios are recorded. `Invoke-RemoteBench.ps1` still prints RESULT: FAIL, because the all-restricted runs differ by more than 0.3 us.
- The highest run is the one with the most CPU steal (28%, tickrate 63.7). vprof times wall-clock time, so hypervisor steal on the shared VM is counted as plugin time. The lowest run, 6.705 us, is the closest estimate.
- The no-restricted cost is about 2.2 times the local test copy's (0.299 us); the all-restricted cost is about 2.7 times (2.505 us).
- The peak single call reads 0.00: the vprof peak is a running maximum, and no window beat the 90 ms set by an earlier run. Earlier windows peaked at 64 and 90 ms, which matches the 43 ms steal peak noted in the spec.
- Beta 6 was not profiled on regs1.
- Bench faults fixed:
  - vprof totals survive `sm prof stop`, and `vprof_reset` did not clear them. The helper now dumps before and after each window, and the runner subtracts the two, checking that the calls equal 2 x clients x ticks.
  - Kicked fakes dropped their guns, and the next run's fakes picked them up (holding 20, then 18, then 14 of 20). The helper now strips the primary before it gives a weapon and before it kicks.
  - The runner records CPU steal per window.
  - ssh got keepalives after one stalled call hung a run.

### Plugin list after the run

```
24 "[CS:S]sm_disablescopes" (0.0.b9) by BallGanda
```

Plugins 01 to 30 are the server's own set. No `disablescopes_matrix` or `disablescopes_bench` is loaded, and neither file is on disk. The helpers' logs (`disablescopes_matrix.csv`, `disablescopes_bench.log`) were copied to `tests/remote/out/gate/server-logs` (not committed) and deleted from the server. `addons/` and `cfg/` match the manifest taken before the run.

## Design

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
