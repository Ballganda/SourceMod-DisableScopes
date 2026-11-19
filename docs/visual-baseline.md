# Visual baseline (ticket #7)

Result of `tests/client/Invoke-VisualMatrix.ps1` (also `.\test.ps1 -Matrix`) on the local server: every case with an on-screen result, at simulated latency of 0, 50, 150 and 250 ms (server `net_fakelag`), one unattended run per build. Full per-case detail: `tests/client/baseline/visual-matrix-b6.md` (Beta 6, tag `v0.0.b6-beta`) and `tests/client/baseline/visual-matrix-b8.md` (b8, the working tree at the time). Re-measure Beta 6 with `.\tests\client\Invoke-VisualMatrix.ps1 -ServerDir ... -ClientDir ... -OutDir ... -Ref v0.0.b6-beta`.

## Result

Both builds give the same pass/fail grid: 38 of 60 (case, latency) results pass.

| Case | 0 ms | 50 ms | 150 ms | 250 ms |
| --- | --- | --- | --- | --- |
| AWP ground scope (allowed) | pass | pass | pass | pass |
| AWP jump then scope (blocked in air) | pass | FAIL | FAIL | FAIL |
| AWP scoped on ground then jump (forced unscope) | FAIL | FAIL | FAIL | FAIL |
| AWP ground scope blocked by on-ground rule | pass | pass | pass | FAIL |
| AWP jump then scope allowed (in-air rule off) | pass | pass | pass | pass |
| AWP unrestricted, jump then scope | pass | pass | pass | pass |
| scout ground scope (allowed) / jump then scope (blocked) | pass / pass | pass / FAIL | pass / FAIL | pass / FAIL |
| G3SG1 ground scope (allowed) / jump then scope (blocked) | pass / pass | pass / FAIL | pass / FAIL | pass / FAIL |
| SG550 ground scope (allowed) / jump then scope (blocked) | pass / pass | pass / FAIL | pass / FAIL | pass / FAIL |
| AWP shot while jumping, scope blocked | pass | FAIL | FAIL | FAIL |
| AWP shot on ground, on-ground rule blocks scope | pass | pass | FAIL | FAIL |
| AWP scoped shot on ground (allowed) | pass | pass | pass | pass |

What the failures are:

- The server never zooms in a blocked state. Every failure is a scope the client predicted and showed before the server corrected it.
- The flicker lasts about one round trip: 31-63 ms at 50 ms, 123-156 ms at 150 ms, 125-282 ms at 250 ms.
- It is the same on Beta 6 and b8, so b8's changes did not alter what the client shows.
- A scope held on the ground and then a jump (forced unscope) shows a scope 58-60 ms at 0 ms and 327-329 ms at 250 ms.
- On Beta 6 and b8 one server command in that case still has a zoomed field of view after the jump.
- Allowed scopes appear on screen at every latency in every case (about 1.9 s for a ground scope).
- Every shot case registered exactly one server shot, the client's clip counter changed, and the server's field of view at the shot was unzoomed in blocked states.

Acceptance thresholds in the ticket (zero scoped frames at 0, 50, 150 ms; at most one at 250 ms) are judged per case; neither baseline meets them at 50 ms and above, so these results are the bar b9 and b10 must clear.

## How it measures

- Screen: `ScopeProbe.cs` samples the client area (about 31 ms per sample, over Remote Desktop). A scoped frame is four edge points pure black. One frame at 250 ms is allowed as 45 ms of scoped screen time.
- Shots: a shot the client shows is a change of the clip counter on its ammo HUD (read from the screen). The server side is the `weapon_fire` event.
- Server state: `tests/client/disablescopes_matrix.sp` logs every command (ground flag, field of view) and every shot.
- Beta 6 reports an unscoped field of view as 90 and b8 as 0; both are treated as unscoped.

## Limits

- SG552 and AUG zoom without a black scope overlay, so the screen probe cannot see them. They stay in the server-state suite (ticket #5).
- Ladder, water and ledge fall count as in the air through the ground flag, so the screen cases use a jump for the air state.
- The demo playback channel from the spike is not used here; the live capture is the judge, because the matrix runs 60 case instances in one session.
- Simulated latency is server `net_fakelag` (delays packets the server receives), so the round trip is about the stated value plus the LAN.
