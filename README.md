# SourceMod-DisableScopes

A SourceMod plugin for **Counter-Strike: Source** that stops players from using the scope on selected weapons, either while they are in the air, while they are on the ground, or both.

Typical uses: no in-air AWP or scout no-scope jumps, or a fully no-scope server.

## What it does

The plugin watches players who have a restricted weapon in hand. When a rule blocks the scope for that player:

- the scope key (secondary attack) is removed from their input, so the weapon never zooms on the server;
- a player who is already scoped is unscoped at once (for example, in the same command a jump leaves the ground);
- the weapon's next-secondary-attack time is held ahead, so the client's own prediction does not zoom either.

When the block ends (the player lands, switches weapon, or the rule is turned off), the weapon's own timer is put back, and the scope works normally again.

A player who holds no restricted weapon costs almost nothing: the plugin checks one per-player flag and returns.

### Weapon groups

| Cvar | Weapons |
| --- | --- |
| `sm_disablescopes_awp` | AWP (`weapon_awp`) |
| `sm_disablescopes_scout` | Scout (`weapon_scout`) |
| `sm_disablescopes_autosnipers` | G3SG1, SG550 (`weapon_g3sg1`, `weapon_sg550`) |
| `sm_disablescopes_weaksnipers` | SG552, AUG (`weapon_sg552`, `weapon_aug`) |

### Rules

| Cvar | Blocks the scope when the player is |
| --- | --- |
| `sm_disablescopes_inair` | not on the ground: jumping, falling, on a ladder, or in water |
| `sm_disablescopes_onground` | on the ground |

Turn both on to block the scope everywhere for the restricted weapons.

### Known limit

On a client with latency, a blocked scope can still show on that player's own screen for about one round trip (their ping plus a little) after the moment the block starts, such as the jump key. This is the client predicting the zoom before the server's correction reaches it. The server never zooms in a blocked state, and a shot fired in a blocked state is unzoomed.

## Requirements

- Counter-Strike: Source dedicated server (the plugin refuses to load on any other game).
- MetaMod:Source and SourceMod 1.11 or newer (built and tested with 1.12). SDKHooks ships with SourceMod.

## Install

1. Download `sm_disablescopes.smx` from the [latest release](https://github.com/Ballganda/SourceMod-DisableScopes/releases).
2. Copy it to `cstrike/addons/sourcemod/plugins/`.
3. Change the map or run `sm plugins load sm_disablescopes` (`sm plugins reload sm_disablescopes` when upgrading).
4. Check: `sm plugins list` shows `"[CS:S]sm_disablescopes" (0.0.b11) by BallGanda`.

When upgrading, read the version from `sm plugins list`, not from the `sm_disablescopes_version` cvar: after a reload the cvar keeps the value the first loaded build registered.

## Configuration

### Cvars

| Cvar | Default | Values | Meaning |
| --- | --- | --- | --- |
| `sm_disablescopes_enable` | `1` | `1` / `0` | Turns the whole plugin on or off. |
| `sm_disablescopes_awp` | `1` | `1` / `0` | Restrict the AWP. |
| `sm_disablescopes_scout` | `1` | `1` / `0` | Restrict the Scout. |
| `sm_disablescopes_autosnipers` | `1` | `1` / `0` | Restrict the G3SG1 and SG550. |
| `sm_disablescopes_weaksnipers` | `1` | `1` / `0` | Restrict the SG552 and AUG. |
| `sm_disablescopes_inair` | `1` | `1` / `0` | Block the scope while not on the ground. |
| `sm_disablescopes_onground` | `0` | `1` / `0` | Block the scope while on the ground. |
| `sm_disablescopes_version` | build | read only | The plugin version. |

The defaults restrict all four groups in the air only.

Every change takes effect immediately, mid-round, without a weapon switch or respawn.

### Config file

The plugin keeps its settings in its own file, one per SourceMod install:

```
cstrike/addons/sourcemod/configs/sm_disablescopes.cfg
```

- It is created the first time the plugin loads, with every setting at its default and a comment above each one: its description, default, and allowed range.
- When a later version adds a setting, the plugin appends it with its default to the end of your existing file. Your own lines are never changed or reordered.
- It is read every map, after the server's own configs (`server.cfg` and the rest) have run. A value set here therefore wins over the same cvar set in `server.cfg`. Edit this file, not `server.cfg`.
- Format: one `cvar value` per line. A value may be quoted (`sm_disablescopes_awp "0"`) and may be followed by `;` or a `// comment`. Lines starting with `//` or `;` are comments, and blank lines are ignored.
- Every value is `0` or `1`. A value outside that range is clamped to it.
- Only the plugin's own cvars (the table above, except `sm_disablescopes_version`) are applied. A line naming any other cvar is skipped.
- Messages go to the SourceMod logs (`addons/sourcemod/logs/L<date>.log`): when the file is created or entries are appended, when it cannot be read or written, and, once per name per plugin load, each skipped line, for example:

  ```
  Config .../configs/sm_disablescopes.cfg line 12: "mp_freezetime" is not a setting of this plugin, line skipped
  ```

- Several servers that share one set of game files but use different SourceMod folders (`+sm_basepath`) each get their own file, so their settings do not collide.

Start of a newly created file:

```
// Settings of sm_disablescopes.smx, in this server's own SourceMod folder.
// Applied on every map change. Lines are: name value  ("//" and ";" start a comment).
// Entries missing here are appended automatically when the plugin loads; existing lines are never changed.

// sm_disablescopes_enable enables the plugin <1|0>
// Default: 1
// Min: 0
// Max: 1
sm_disablescopes_enable "1"

// Disable the AWP scope <1|0>
// Default: 1
// Min: 0
// Max: 1
sm_disablescopes_awp "1"
```

The other five settings follow in the same form.

#### Changes from earlier versions

A file written by an earlier version keeps working with its values unchanged, and none of its lines is rewritten. Two things behave differently:

- A line starting with a single `/` is no longer a comment. Start comments with `//` or `;`.
- A line naming another plugin's or the server's cvar (for example `sv_cheats 1`) is no longer applied. It is skipped and logged. Set those cvars in `server.cfg`.

Example, a no-scope AWP and scout server (both rules on, rifles left alone):

```
sm_disablescopes_enable 1
sm_disablescopes_awp 1
sm_disablescopes_scout 1
sm_disablescopes_autosnipers 0
sm_disablescopes_weaksnipers 0
sm_disablescopes_inair 1
sm_disablescopes_onground 1
```

To change a setting for one session only, set the cvar in the server console or over rcon (`sm_disablescopes_onground 1`). The file is read again on the next map, and its value comes back.

### Admin command

| Command | Access | Does |
| --- | --- | --- |
| `sm_disablescopes` | ban flag (`d`) | Prints the plugin name, version and the list of cvars to the console. |

## Building and testing (developers)

- `.\build.ps1` compiles `scripting\*.sp` and the test plugins with the server's `spcomp`; `-Deploy` copies them to the local test server.
- `.\test.ps1` runs the server-state suite on a local srcds unattended (`-Client` and `-Matrix` add real-client cases).
- `.\bench.ps1` measures the plugin's cost in microseconds per player per tick. Results are in `docs/`.

## License

GPL version 3. See `LICENSE`.
