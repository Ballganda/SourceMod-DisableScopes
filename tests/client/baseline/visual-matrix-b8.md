# Visual matrix: working tree

Simulated latency is server net_fakelag. Run 2026-11-19 15:55; client clip-counter changes seen in total: 105.

| Case | 0 ms | 50 ms | 150 ms | 250 ms |
| --- | --- | --- | --- | --- |
| AWP ground scope (allowed) | pass | pass | pass | pass |
| AWP jump then scope (blocked in air) | pass | FAIL | FAIL | FAIL |
| AWP scoped on ground then jump (forced unscope) | FAIL | FAIL | FAIL | FAIL |
| AWP ground scope blocked by on-ground rule | pass | pass | pass | FAIL |
| AWP jump then scope allowed (in-air rule off) | pass | pass | pass | pass |
| AWP unrestricted (awp cvar off), jump then scope | pass | pass | pass | pass |
| scout ground scope (allowed) | pass | pass | pass | pass |
| scout jump then scope (blocked in air) | pass | FAIL | FAIL | FAIL |
| G3SG1 ground scope (allowed) | pass | pass | pass | pass |
| G3SG1 jump then scope (blocked in air) | pass | FAIL | FAIL | FAIL |
| SG550 ground scope (allowed) | pass | pass | pass | pass |
| SG550 jump then scope (blocked in air) | pass | FAIL | FAIL | FAIL |
| AWP shot while jumping, scope blocked | pass | FAIL | FAIL | FAIL |
| AWP shot on ground, on-ground rule blocks scope | pass | pass | FAIL | FAIL |
| AWP scoped shot on ground (allowed) | pass | pass | pass | pass |

## Detail
- AWP ground scope (allowed) @ 0 ms: pass - server cmds 520, zoomed 210, zoomed while blocked 0; screen scoped 1952 ms in 1 interval(s)
- AWP ground scope (allowed) @ 50 ms: pass - server cmds 518, zoomed 209, zoomed while blocked 0; screen scoped 1944 ms in 1 interval(s)
- AWP ground scope (allowed) @ 150 ms: pass - server cmds 519, zoomed 209, zoomed while blocked 0; screen scoped 1977 ms in 1 interval(s)
- AWP ground scope (allowed) @ 250 ms: pass - server cmds 518, zoomed 208, zoomed while blocked 0; screen scoped 1973 ms in 1 interval(s)
- AWP jump then scope (blocked in air) @ 0 ms: pass - server cmds 568, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s)
- AWP jump then scope (blocked in air) @ 50 ms: FAIL - server cmds 569, zoomed 0, zoomed while blocked 0; screen scoped 63 ms in 1 interval(s); blocked, but the screen showed a scope for 63 ms (allowed: none at 50 ms)
- AWP jump then scope (blocked in air) @ 150 ms: FAIL - server cmds 570, zoomed 0, zoomed while blocked 0; screen scoped 156 ms in 1 interval(s); blocked, but the screen showed a scope for 156 ms (allowed: none at 150 ms)
- AWP jump then scope (blocked in air) @ 250 ms: FAIL - server cmds 570, zoomed 0, zoomed while blocked 0; screen scoped 281 ms in 1 interval(s); blocked, but the screen showed a scope for 281 ms in 1 interval(s) (allowed: one frame at 250 ms)
- AWP scoped on ground then jump (forced unscope) @ 0 ms: FAIL - server cmds 729, zoomed 160, zoomed while blocked 1; screen scoped 58 ms in 1 interval(s); blocked, but the screen showed a scope for 58 ms (allowed: none at 0 ms); server fov zoomed in 1 cmds while the scope was blocked
- AWP scoped on ground then jump (forced unscope) @ 50 ms: FAIL - server cmds 727, zoomed 160, zoomed while blocked 1; screen scoped 99 ms in 1 interval(s); blocked, but the screen showed a scope for 99 ms (allowed: none at 50 ms); server fov zoomed in 1 cmds while the scope was blocked
- AWP scoped on ground then jump (forced unscope) @ 150 ms: FAIL - server cmds 725, zoomed 162, zoomed while blocked 1; screen scoped 197 ms in 1 interval(s); blocked, but the screen showed a scope for 197 ms (allowed: none at 150 ms); server fov zoomed in 1 cmds while the scope was blocked
- AWP scoped on ground then jump (forced unscope) @ 250 ms: FAIL - server cmds 729, zoomed 159, zoomed while blocked 1; screen scoped 319 ms in 1 interval(s); blocked, but the screen showed a scope for 319 ms in 1 interval(s) (allowed: one frame at 250 ms); server fov zoomed in 1 cmds while the scope was blocked
- AWP ground scope blocked by on-ground rule @ 0 ms: pass - server cmds 521, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s)
- AWP ground scope blocked by on-ground rule @ 50 ms: pass - server cmds 518, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s)
- AWP ground scope blocked by on-ground rule @ 150 ms: pass - server cmds 520, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s)
- AWP ground scope blocked by on-ground rule @ 250 ms: FAIL - server cmds 518, zoomed 0, zoomed while blocked 0; screen scoped 95 ms in 1 interval(s); blocked, but the screen showed a scope for 95 ms in 1 interval(s) (allowed: one frame at 250 ms)
- AWP jump then scope allowed (in-air rule off) @ 0 ms: pass - server cmds 569, zoomed 258, zoomed while blocked 0; screen scoped 2141 ms in 1 interval(s)
- AWP jump then scope allowed (in-air rule off) @ 50 ms: pass - server cmds 569, zoomed 256, zoomed while blocked 0; screen scoped 2134 ms in 1 interval(s)
- AWP jump then scope allowed (in-air rule off) @ 150 ms: pass - server cmds 567, zoomed 255, zoomed while blocked 0; screen scoped 2116 ms in 1 interval(s)
- AWP jump then scope allowed (in-air rule off) @ 250 ms: pass - server cmds 567, zoomed 256, zoomed while blocked 0; screen scoped 2119 ms in 1 interval(s)
- AWP unrestricted (awp cvar off), jump then scope @ 0 ms: pass - server cmds 567, zoomed 255, zoomed while blocked 0; screen scoped 2115 ms in 1 interval(s)
- AWP unrestricted (awp cvar off), jump then scope @ 50 ms: pass - server cmds 566, zoomed 254, zoomed while blocked 0; screen scoped 2120 ms in 1 interval(s)
- AWP unrestricted (awp cvar off), jump then scope @ 150 ms: pass - server cmds 570, zoomed 258, zoomed while blocked 0; screen scoped 2134 ms in 1 interval(s)
- AWP unrestricted (awp cvar off), jump then scope @ 250 ms: pass - server cmds 568, zoomed 256, zoomed while blocked 0; screen scoped 2141 ms in 1 interval(s)
- scout ground scope (allowed) @ 0 ms: pass - server cmds 518, zoomed 209, zoomed while blocked 0; screen scoped 1964 ms in 1 interval(s)
- scout ground scope (allowed) @ 50 ms: pass - server cmds 520, zoomed 209, zoomed while blocked 0; screen scoped 1974 ms in 1 interval(s)
- scout ground scope (allowed) @ 150 ms: pass - server cmds 520, zoomed 210, zoomed while blocked 0; screen scoped 1956 ms in 1 interval(s)
- scout ground scope (allowed) @ 250 ms: pass - server cmds 518, zoomed 209, zoomed while blocked 0; screen scoped 1962 ms in 1 interval(s)
- scout jump then scope (blocked in air) @ 0 ms: pass - server cmds 570, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s)
- scout jump then scope (blocked in air) @ 50 ms: FAIL - server cmds 569, zoomed 0, zoomed while blocked 0; screen scoped 62 ms in 1 interval(s); blocked, but the screen showed a scope for 62 ms (allowed: none at 50 ms)
- scout jump then scope (blocked in air) @ 150 ms: FAIL - server cmds 567, zoomed 0, zoomed while blocked 0; screen scoped 156 ms in 1 interval(s); blocked, but the screen showed a scope for 156 ms (allowed: none at 150 ms)
- scout jump then scope (blocked in air) @ 250 ms: FAIL - server cmds 568, zoomed 0, zoomed while blocked 0; screen scoped 250 ms in 1 interval(s); blocked, but the screen showed a scope for 250 ms in 1 interval(s) (allowed: one frame at 250 ms)
- G3SG1 ground scope (allowed) @ 0 ms: pass - server cmds 518, zoomed 210, zoomed while blocked 0; screen scoped 1959 ms in 1 interval(s)
- G3SG1 ground scope (allowed) @ 50 ms: pass - server cmds 518, zoomed 209, zoomed while blocked 0; screen scoped 1973 ms in 1 interval(s)
- G3SG1 ground scope (allowed) @ 150 ms: pass - server cmds 519, zoomed 208, zoomed while blocked 0; screen scoped 1956 ms in 1 interval(s)
- G3SG1 ground scope (allowed) @ 250 ms: pass - server cmds 519, zoomed 211, zoomed while blocked 0; screen scoped 1976 ms in 1 interval(s)
- G3SG1 jump then scope (blocked in air) @ 0 ms: pass - server cmds 567, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s)
- G3SG1 jump then scope (blocked in air) @ 50 ms: FAIL - server cmds 567, zoomed 0, zoomed while blocked 0; screen scoped 63 ms in 1 interval(s); blocked, but the screen showed a scope for 63 ms (allowed: none at 50 ms)
- G3SG1 jump then scope (blocked in air) @ 150 ms: FAIL - server cmds 569, zoomed 0, zoomed while blocked 0; screen scoped 156 ms in 1 interval(s); blocked, but the screen showed a scope for 156 ms (allowed: none at 150 ms)
- G3SG1 jump then scope (blocked in air) @ 250 ms: FAIL - server cmds 571, zoomed 0, zoomed while blocked 0; screen scoped 250 ms in 1 interval(s); blocked, but the screen showed a scope for 250 ms in 1 interval(s) (allowed: one frame at 250 ms)
- SG550 ground scope (allowed) @ 0 ms: pass - server cmds 520, zoomed 210, zoomed while blocked 0; screen scoped 1952 ms in 1 interval(s)
- SG550 ground scope (allowed) @ 50 ms: pass - server cmds 520, zoomed 210, zoomed while blocked 0; screen scoped 1956 ms in 1 interval(s)
- SG550 ground scope (allowed) @ 150 ms: pass - server cmds 516, zoomed 209, zoomed while blocked 0; screen scoped 1962 ms in 1 interval(s)
- SG550 ground scope (allowed) @ 250 ms: pass - server cmds 519, zoomed 210, zoomed while blocked 0; screen scoped 1975 ms in 1 interval(s)
- SG550 jump then scope (blocked in air) @ 0 ms: pass - server cmds 568, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s)
- SG550 jump then scope (blocked in air) @ 50 ms: FAIL - server cmds 568, zoomed 0, zoomed while blocked 0; screen scoped 62 ms in 1 interval(s); blocked, but the screen showed a scope for 62 ms (allowed: none at 50 ms)
- SG550 jump then scope (blocked in air) @ 150 ms: FAIL - server cmds 573, zoomed 0, zoomed while blocked 0; screen scoped 187 ms in 1 interval(s); blocked, but the screen showed a scope for 187 ms (allowed: none at 150 ms)
- SG550 jump then scope (blocked in air) @ 250 ms: FAIL - server cmds 569, zoomed 0, zoomed while blocked 0; screen scoped 281 ms in 1 interval(s); blocked, but the screen showed a scope for 281 ms in 1 interval(s) (allowed: one frame at 250 ms)
- AWP shot while jumping, scope blocked @ 0 ms: pass - server cmds 591, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s); shots: server 1, client clip counter changes 3
- AWP shot while jumping, scope blocked @ 50 ms: FAIL - server cmds 588, zoomed 0, zoomed while blocked 0; screen scoped 31 ms in 1 interval(s); shots: server 1, client clip counter changes 3; blocked, but the screen showed a scope for 31 ms (allowed: none at 50 ms)
- AWP shot while jumping, scope blocked @ 150 ms: FAIL - server cmds 589, zoomed 0, zoomed while blocked 0; screen scoped 125 ms in 1 interval(s); shots: server 1, client clip counter changes 3; blocked, but the screen showed a scope for 125 ms (allowed: none at 150 ms)
- AWP shot while jumping, scope blocked @ 250 ms: FAIL - server cmds 590, zoomed 0, zoomed while blocked 0; screen scoped 125 ms in 1 interval(s); shots: server 1, client clip counter changes 5; blocked, but the screen showed a scope for 125 ms in 1 interval(s) (allowed: one frame at 250 ms)
- AWP shot on ground, on-ground rule blocks scope @ 0 ms: pass - server cmds 647, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s); shots: server 1, client clip counter changes 3
- AWP shot on ground, on-ground rule blocks scope @ 50 ms: pass - server cmds 646, zoomed 0, zoomed while blocked 0; screen scoped 0 ms in 0 interval(s); shots: server 1, client clip counter changes 3
- AWP shot on ground, on-ground rule blocks scope @ 150 ms: FAIL - server cmds 645, zoomed 0, zoomed while blocked 0; screen scoped 32 ms in 1 interval(s); shots: server 1, client clip counter changes 3; blocked, but the screen showed a scope for 32 ms (allowed: none at 150 ms)
- AWP shot on ground, on-ground rule blocks scope @ 250 ms: FAIL - server cmds 647, zoomed 0, zoomed while blocked 0; screen scoped 94 ms in 1 interval(s); shots: server 1, client clip counter changes 3; blocked, but the screen showed a scope for 94 ms in 1 interval(s) (allowed: one frame at 250 ms)
- AWP scoped shot on ground (allowed) @ 0 ms: pass - server cmds 647, zoomed 190, zoomed while blocked 0; screen scoped 1170 ms in 1 interval(s); shots: server 1, client clip counter changes 3
- AWP scoped shot on ground (allowed) @ 50 ms: pass - server cmds 648, zoomed 188, zoomed while blocked 0; screen scoped 1158 ms in 1 interval(s); shots: server 1, client clip counter changes 3
- AWP scoped shot on ground (allowed) @ 150 ms: pass - server cmds 648, zoomed 187, zoomed while blocked 0; screen scoped 1146 ms in 1 interval(s); shots: server 1, client clip counter changes 3
- AWP scoped shot on ground (allowed) @ 250 ms: pass - server cmds 2232, zoomed 1774, zoomed while blocked 0; screen scoped 1169 ms in 1 interval(s); shots: server 1, client clip counter changes 1
