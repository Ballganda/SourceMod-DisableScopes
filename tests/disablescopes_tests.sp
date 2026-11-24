/**
	DisableScopes regression suite.

	Treats the compiled plugin as a black box: it drives a fake client (bot) through weapon,
	movement and cvar cases and reads server state: whether secondary attack got through the
	plugin's input handler, the bot's field of view, and weapon_fire events. Any build runs
	unchanged. Results go to addons/sourcemod/logs/disablescopes_tests.log.
	Unattended: test.ps1 in the repo root.

	Water and ladder are simulated (move type set, ground flag clear): the rule under test
	counts anything off the ground as in the air, and the test map has no water.
*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

#define PLUGIN_FILE "sm_disablescopes.smx"
#define START_DELAY 10.0
#define STEP 0.25
#define INIT_MAX_TRIES 80

// cvar bitmask used by the matrix; bit order matches g_cvars
#define B_ENABLE  (1 << 0)
#define B_AWP     (1 << 1)
#define B_SCOUT   (1 << 2)
#define B_AUTO    (1 << 3)
#define B_WEAK    (1 << 4)
#define B_INAIR   (1 << 5)
#define B_GROUND  (1 << 6)
#define M_DEFAULT (B_ENABLE | B_AWP | B_SCOUT | B_AUTO | B_WEAK | B_INAIR)
#define M_ALL     (M_DEFAULT | B_GROUND)

enum
{
	OP_SETUP = 0,   // unload the plugin under test (reloaded by OP_LOAD so it runs after this suite)
	OP_LOAD,        // load the plugin under test, add a bot, restart the round
	OP_INIT,        // find the bot, save its spawn, make it harmless
	OP_CVARS,       // arg = bitmask
	OP_WEAPON,      // arg = weapon index
	OP_STATE,       // arg = state index; arg2 bit 1 keeps the scope, bit 2 keeps the weapon's attack timers
	OP_SCOPE,       // arg = hold secondary attack 1/0
	OP_FIRE,        // arg = hold primary attack 1/0
	OP_RELOAD,
	OP_DROP,
	OP_PICKUP,
	OP_RESPAWN,
	OP_WAIT,        // arg = steps
	OP_CHECK        // arg = kind, arg2 = name index
};

enum
{
	K_SCOPE = 0,    // scope rule: allowed or blocked as the cvars say
	K_UNSCOPED,     // player must not be scoped
	K_FIRE,         // primary fire must have registered
	K_NOZOOMBLOCKED,// no command since the last state change ended zoomed in a blocked state
	K_NSAQUIET      // the weapon's next-secondary-attack time was not rewritten on most blocked ticks
};

enum
{
	S_GROUND = 0,
	S_JUMP,
	S_CROUCHJUMP,
	S_LEDGE,
	S_LADDER,
	S_WATER,
	NUM_STATES
};

static const char g_stateNames[NUM_STATES][] = { "ground", "jump", "crouch-jump", "ledge fall", "ladder", "water" };

#define NUM_WEAPONS 7
#define W_UNRESTRICTED 6
static const char g_weapons[NUM_WEAPONS][] =
{
	"weapon_awp", "weapon_scout", "weapon_g3sg1", "weapon_sg550", "weapon_sg552", "weapon_aug", "weapon_m4a1"
};
// restriction bit per weapon (0 = no cvar covers it)
static const int g_weaponBit[NUM_WEAPONS] = { B_AWP, B_SCOUT, B_AUTO, B_AUTO, B_WEAK, B_WEAK, 0 };

static const char g_cvars[][] =
{
	"sm_disablescopes_enable",
	"sm_disablescopes_awp",
	"sm_disablescopes_scout",
	"sm_disablescopes_autosnipers",
	"sm_disablescopes_weaksnipers",
	"sm_disablescopes_inair",
	"sm_disablescopes_onground"
};

ConVar g_cvAutorun = null;
ConVar g_cvInjectError = null;
char g_logPath[PLATFORM_MAX_PATH];
int g_pass = 0;
int g_fail = 0;

ArrayList g_ops = null;    // blocks of 3: op, arg, arg2
ArrayList g_names = null;  // case names, by index
int g_total = 0;           // number of queued checks
int g_waitSteps = 0;
int g_initTries = 0;

// what the bot is currently set up as
int g_bot = 0;
float g_spawn[3];
int g_mask = 0;
int g_weapon = 0;
int g_state = 0;
char g_dropClass[32];

// per-tick drive and observation
bool g_press2 = false;
bool g_press1 = false;
bool g_reload = false;
bool g_duck = false;
int g_postButtons = 0;
int g_shots = 0;
int g_shotsAtFire = 0;
int g_zoomBlockedCmds = 0;   // commands that ended zoomed in a blocked state (seen at the next command)
int g_blockedCmds = 0;       // commands seen in a blocked state since the last state change
int g_nsaChanges = 0;        // of those, how many saw a different next-secondary-attack time
float g_lastNsa = -1.0;

public Plugin myinfo =
{
	name = "disablescopes_tests",
	author = "BallGanda",
	description = "Regression suite for sm_disablescopes",
	version = "0.2.0",
	url = ""
};

public void OnPluginStart()
{
	g_cvAutorun = CreateConVar("disablescopes_test_autorun", "0", "Run the suite after map start, then quit the server.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvInjectError = CreateConVar("disablescopes_test_inject_error", "0", "Log a deliberate error (checks that error detection works).", FCVAR_NONE, true, 0.0, true, 1.0);
	RegServerCmd("disablescopes_test", Cmd_Run, "Run the DisableScopes suite");
	BuildPath(Path_SM, g_logPath, sizeof(g_logPath), "logs/disablescopes_tests.log");
	HookEvent("weapon_fire", Event_WeaponFire);
}

public void OnMapStart()
{
	if (g_cvAutorun.BoolValue)
	{
		CreateTimer(START_DELAY, Timer_Autorun, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_Autorun(Handle timer)
{
	RunSuite();
	return Plugin_Stop;
}

public Action Cmd_Run(int args)
{
	RunSuite();
	return Plugin_Handled;
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	if (g_bot > 0 && GetClientOfUserId(event.GetInt("userid")) == g_bot)
	{
		g_shots++;
	}
}

// Runs before the plugin under test (OP_SETUP reloads it after this suite loaded), so the
// buttons injected here pass through the plugin's own handler. Post sees what it left.
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (client != g_bot)
	{
		return Plugin_Continue;
	}
	ObserveCommandStart(client);
	buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_RELOAD | IN_DUCK);
	if (g_press2)
	{
		buttons |= IN_ATTACK2;
	}
	if (g_press1)
	{
		buttons |= IN_ATTACK;
	}
	if (g_reload)
	{
		buttons |= IN_RELOAD;
	}
	if (g_duck)
	{
		buttons |= IN_DUCK;
	}
	return Plugin_Changed;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	if (client == g_bot)
	{
		g_postButtons = buttons;
	}
}

// Runs before the plugin under test, so it sees what the previous command left after every plugin ran.
void ObserveCommandStart(int client)
{
	if (!IsPlayerAlive(client))
	{
		return;
	}
	int state = (GetEntityFlags(client) & FL_ONGROUND) ? S_GROUND : S_JUMP;
	if (!ExpectBlocked(g_mask, g_weapon, state))
	{
		g_lastNsa = -1.0;
		return;
	}
	int fov = GetEntProp(client, Prop_Send, "m_iFOV");
	if (fov > 0 && fov < 90)
	{
		g_zoomBlockedCmds++;
	}
	int w = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (w > 0)
	{
		float nsa = GetEntPropFloat(w, Prop_Send, "m_flNextSecondaryAttack");
		if (g_lastNsa >= 0.0)
		{
			g_blockedCmds++;
			if (nsa != g_lastNsa)
			{
				g_nsaChanges++;
			}
		}
		g_lastNsa = nsa;
	}
}

void Report(bool ok, const char[] name, const char[] detail)
{
	if (ok)
	{
		g_pass++;
	}
	else
	{
		g_fail++;
	}
	LogToFileEx(g_logPath, "[%s] %s%s%s", ok ? "PASS" : "FAIL", name, detail[0] ? " - " : "", detail);
}

// ---- case queue -------------------------------------------------------------------------

void Op(int op, int arg = 0, int arg2 = 0)
{
	int idx = g_ops.Push(op);
	g_ops.Set(idx, arg, 1);
	g_ops.Set(idx, arg2, 2);
}

void Check(int kind, const char[] fmt, any ...)
{
	char name[160];
	VFormat(name, sizeof(name), fmt, 3);
	Op(OP_CHECK, kind, g_names.PushString(name));
	g_total++;
}

bool IsAirState(int state)
{
	return state != S_GROUND;
}

// The rule, written from the spec (issue #1), not read from the plugin.
bool ExpectBlocked(int mask, int weapon, int state)
{
	if (!(mask & B_ENABLE))
	{
		return false;
	}
	int bit = g_weaponBit[weapon];
	if (bit == 0 || !(mask & bit))
	{
		return false;
	}
	return IsAirState(state) ? (mask & B_INAIR) != 0 : (mask & B_GROUND) != 0;
}

void MaskText(int mask, char[] out, int len)
{
	Format(out, len, "en%d awp%d sc%d au%d wk%d air%d gnd%d", mask & 1, (mask >> 1) & 1, (mask >> 2) & 1, (mask >> 3) & 1, (mask >> 4) & 1, (mask >> 5) & 1, (mask >> 6) & 1);
}

// One scope probe: state set, scope button pressed, result read.
void ProbeScope(int mask, int weapon, int state, const char[] label)
{
	char m[64];
	MaskText(mask, m, sizeof(m));
	Op(OP_CVARS, mask);
	Op(OP_SCOPE, 0);
	Op(OP_STATE, state);
	Op(OP_SCOPE, 1);
	Check(K_SCOPE, "%s: %s, %s, %s", label, g_weapons[weapon], g_stateNames[state], m);
	Op(OP_SCOPE, 0);
}

void BuildQueue()
{
	g_ops = new ArrayList(3);
	g_names = new ArrayList(ByteCountToCells(160));
	g_total = 0;

	Op(OP_SETUP);
	Op(OP_LOAD);
	Op(OP_WAIT, 20);
	Op(OP_INIT);
	Op(OP_WAIT, 8);   // let the fresh spawn settle before giving weapons

	// 1. weapon x state: in-air rule alone, then on-ground rule alone. Covers each weapon group,
	//    the unrestricted weapon, and ladder/water/ledge fall counting as in the air.
	int masks[2];
	masks[0] = M_DEFAULT;
	masks[1] = M_ALL & ~B_INAIR;
	for (int w = 0; w < NUM_WEAPONS; w++)
	{
		Op(OP_CVARS, M_DEFAULT);
		Op(OP_WEAPON, w);
		for (int k = 0; k < 2; k++)
		{
			for (int s = 0; s < NUM_STATES; s++)
			{
				ProbeScope(masks[k], w, s, "rule");
			}
		}
	}

	// 2. the unrestricted weapon with every restriction on, in every state
	Op(OP_WEAPON, W_UNRESTRICTED);
	for (int s = 0; s < NUM_STATES; s++)
	{
		ProbeScope(M_ALL, W_UNRESTRICTED, s, "unrestricted");
	}

	// 3. scoped, then enter a blocked state: unscoped; return: scope works again
	for (int w = 0; w < W_UNRESTRICTED; w++)
	{
		Op(OP_CVARS, M_DEFAULT);
		Op(OP_WEAPON, w);
		Op(OP_STATE, S_GROUND);
		Op(OP_SCOPE, 1);
		Check(K_SCOPE, "hold scope on ground: %s scopes", g_weapons[w]);
		Op(OP_SCOPE, 0);
		Op(OP_STATE, S_JUMP, 1);
		Check(K_UNSCOPED, "scoped then jump: %s is unscoped", g_weapons[w]);
		Check(K_NOZOOMBLOCKED, "scoped then jump: %s unscoped in the command that left the ground", g_weapons[w]);
		Op(OP_STATE, S_GROUND);
		Op(OP_SCOPE, 1);
		Check(K_SCOPE, "back on ground: %s scopes again", g_weapons[w]);
		Op(OP_SCOPE, 0);
	}

	// 3b. blocked in the air for a while, then land with the weapon's timers left as the plugin set
	//     them: the scope works again at once, and the blocked ticks did not each rewrite the timer
	for (int w = 0; w < W_UNRESTRICTED; w++)
	{
		Op(OP_CVARS, M_DEFAULT);
		Op(OP_WEAPON, w);
		Op(OP_STATE, S_WATER);
		Op(OP_SCOPE, 1);
		Op(OP_WAIT, 2);
		Check(K_NSAQUIET, "blocked in the air: %s next-secondary-attack not resent every tick", g_weapons[w]);
		Op(OP_SCOPE, 0);
		Op(OP_STATE, S_GROUND, 2);
		Op(OP_SCOPE, 1);
		Check(K_SCOPE, "landed, timers untouched: %s scopes again", g_weapons[w]);
		Op(OP_SCOPE, 0);
	}

	// 4. switch, reload, drop and pickup, respawn leave no stale block or allowance
	for (int st = 0; st < 2; st++)
	{
		int state = (st == 0) ? S_GROUND : S_JUMP;
		for (int a = 0; a < 4; a++)
		{
			char act[24];
			Op(OP_CVARS, M_DEFAULT);
			Op(OP_WEAPON, 0);
			Op(OP_STATE, state);
			switch (a)
			{
				case 0:
				{
					act = "switch";
					Op(OP_WEAPON, W_UNRESTRICTED);
					Op(OP_WEAPON, 0);
				}
				case 1:
				{
					act = "reload";
					Op(OP_RELOAD);
				}
				case 2:
				{
					act = "drop and pickup";
					Op(OP_DROP);
					Op(OP_PICKUP);
				}
				case 3:
				{
					act = "respawn";
					Op(OP_RESPAWN);
					Op(OP_WEAPON, 0);
				}
			}
			Op(OP_STATE, state);
			Op(OP_SCOPE, 1);
			Check(K_SCOPE, "after %s: awp, %s", act, g_stateNames[state]);
			Op(OP_SCOPE, 0);
		}
	}

	// 5. each cvar changed mid-round with no weapon switch or respawn
	int bits[7];
	bits[0] = B_ENABLE;
	bits[1] = B_AWP;
	bits[2] = B_SCOUT;
	bits[3] = B_AUTO;
	bits[4] = B_WEAK;
	bits[5] = B_INAIR;
	bits[6] = B_GROUND;
	int cvW[7];
	cvW[0] = 0;
	cvW[1] = 0;
	cvW[2] = 1;
	cvW[3] = 2;
	cvW[4] = 5;
	cvW[5] = 0;
	cvW[6] = 0;
	for (int c = 0; c < 7; c++)
	{
		int on = (c == 6) ? M_ALL : M_DEFAULT;
		int off = on & ~bits[c];
		int cstate = (c == 6) ? S_GROUND : S_WATER;   // water floats, so the bot stays in the air for the whole sequence
		Op(OP_CVARS, on);
		Op(OP_WEAPON, cvW[c]);
		Op(OP_STATE, cstate);
		Op(OP_SCOPE, 1);
		Check(K_SCOPE, "mid-round %s on: %s, %s", g_cvars[c], g_weapons[cvW[c]], g_stateNames[cstate]);
		Op(OP_CVARS, off);
		Op(OP_SCOPE, 0);
		Op(OP_SCOPE, 1);
		Check(K_SCOPE, "mid-round %s off, no switch or respawn: %s, %s", g_cvars[c], g_weapons[cvW[c]], g_stateNames[cstate]);
		Op(OP_CVARS, on);
		Op(OP_SCOPE, 0);
		Op(OP_SCOPE, 1);
		Check(K_SCOPE, "mid-round %s on again: %s, %s", g_cvars[c], g_weapons[cvW[c]], g_stateNames[cstate]);
		Op(OP_SCOPE, 0);
	}

	// 6. primary fire registers in every blocked state, with scope pressed too
	for (int w = 0; w < W_UNRESTRICTED; w++)
	{
		Op(OP_CVARS, M_ALL);
		Op(OP_WEAPON, w);
		for (int s = 0; s < NUM_STATES; s++)
		{
			Op(OP_SCOPE, 0);
			Op(OP_STATE, s);
			Op(OP_SCOPE, 1);
			Op(OP_FIRE, 1);
			Check(K_FIRE, "fire while blocked: %s, %s", g_weapons[w], g_stateNames[s]);
			Op(OP_FIRE, 0);
		}
	}
	Op(OP_SCOPE, 0);
}

// ---- executor ----------------------------------------------------------------------------

void RunSuite()
{
	g_pass = 0;
	g_fail = 0;
	g_bot = 0;
	g_waitSteps = 0;
	g_initTries = 0;
	g_press1 = false;
	g_press2 = false;
	g_reload = false;
	g_duck = false;

	Handle plugin = FindPluginByFile(PLUGIN_FILE);
	bool running = plugin != null && GetPluginStatus(plugin) == Plugin_Running;

	BuildQueue();
	LogToFileEx(g_logPath, "=== DisableScopes tests started (%d cases) ===", g_total + 2);

	if (g_cvInjectError.BoolValue)
	{
		LogError("deliberate error injected by disablescopes_test_inject_error");
	}

	Report(running, "plugin under test is running", running ? "" : "plugin is not running");
	char missing[256];
	for (int i = 0; i < sizeof(g_cvars); i++)
	{
		if (FindConVar(g_cvars[i]) == null)
		{
			Format(missing, sizeof(missing), "%s%s%s", missing, missing[0] ? ", " : "missing: ", g_cvars[i]);
		}
	}
	Report(!missing[0], "all seven cvars exist", missing);

	CreateTimer(STEP, Timer_Step, _, TIMER_REPEAT);
}

public Action Timer_Step(Handle timer)
{
	if (g_waitSteps > 0)
	{
		g_waitSteps--;
		return Plugin_Continue;
	}
	while (g_ops.Length > 0)
	{
		int op = g_ops.Get(0, 0);
		int arg = g_ops.Get(0, 1);
		int arg2 = g_ops.Get(0, 2);
		g_ops.Erase(0);
		if (Execute(op, arg, arg2))
		{
			return Plugin_Continue;   // that op needs a step to take effect
		}
	}
	LogToFileEx(g_logPath, "tests finished: %d passed, %d failed, 0 skipped", g_pass, g_fail);
	ServerCommand("quit");
	return Plugin_Stop;
}

bool BotOk()
{
	return g_bot > 0 && IsClientInGame(g_bot) && IsPlayerAlive(g_bot);
}

// Returns true when the op must be followed by a wait step.
bool Execute(int op, int arg, int arg2)
{
	switch (op)
	{
		case OP_SETUP:
		{
			ServerCommand("sm plugins unload sm_disablescopes");
			return true;
		}
		case OP_LOAD:
		{
			ServerCommand("sm plugins load sm_disablescopes");
			ServerCommand("mp_freezetime 0; mp_ignore_round_win_conditions 1; mp_autoteambalance 0; mp_limitteams 0; bot_quota 0; mp_restartgame 1");
			return true;
		}
		case OP_INIT:
		{
			g_bot = 0;
			for (int c = 1; c <= MaxClients; c++)
			{
				if (IsClientInGame(c) && IsFakeClient(c) && IsPlayerAlive(c))
				{
					g_bot = c;
					break;
				}
			}
			if (g_bot > 0)
			{
				g_initTries = 0;
				GetClientAbsOrigin(g_bot, g_spawn);
				SetEntProp(g_bot, Prop_Data, "m_takedamage", 0);
				return false;
			}
			if (++g_initTries > INIT_MAX_TRIES)
			{
				// give up: one clear failure instead of a failure per case
				g_ops.Clear();
				Report(false, "test bot exists and is alive", "no live fake client after 20 s; aborting the run");
				return false;
			}
			// a plain fake client: no bot AI to fight the test, and no navmesh needed
			int fake = 0;
			for (int c = 1; c <= MaxClients; c++)
			{
				if (IsClientInGame(c) && IsFakeClient(c))
				{
					fake = c;
					break;
				}
			}
			if (fake == 0)
			{
				fake = CreateFakeClient("DSTestBot");
				if (fake > 0)
				{
					ChangeClientTeam(fake, 2);
				}
			}
			else if (!IsPlayerAlive(fake) && GetClientTeam(fake) > 1)
			{
				CS_RespawnPlayer(fake);
			}
			else if (GetClientTeam(fake) <= 1)
			{
				ChangeClientTeam(fake, 2);
			}
			// poll again next step
			g_ops.ShiftUp(0);
			g_ops.Set(0, OP_INIT, 0);
			g_ops.Set(0, 0, 1);
			g_ops.Set(0, 0, 2);
			return true;
		}
		case OP_CVARS:
		{
			g_mask = arg;
			for (int i = 0; i < sizeof(g_cvars); i++)
			{
				FindConVar(g_cvars[i]).SetBool((arg & (1 << i)) != 0);
			}
		}
		case OP_WEAPON:
		{
			if (!BotOk())
			{
				return false;
			}
			g_weapon = arg;
			int old = GetPlayerWeaponSlot(g_bot, 0);
			if (old > 0)
			{
				RemovePlayerItem(g_bot, old);
				RemoveEntity(old);
			}
			GivePlayerItem(g_bot, g_weapons[arg]);
			FakeClientCommand(g_bot, "use %s", g_weapons[arg]);
			return true;
		}
		case OP_STATE:
		{
			if (!BotOk())
			{
				return false;
			}
			g_state = arg;
			EnsureWeapon();
			ApplyState(arg, (arg2 & 1) == 0, (arg2 & 2) == 0);
			return true;
		}
		case OP_SCOPE:
		{
			g_press2 = (arg != 0);
			return true;
		}
		case OP_FIRE:
		{
			g_press1 = (arg != 0);
			if (g_press1)
			{
				g_shotsAtFire = g_shots;
			}
			return true;
		}
		case OP_RELOAD:
		{
			if (!BotOk())
			{
				return false;
			}
			int w = GetEntPropEnt(g_bot, Prop_Send, "m_hActiveWeapon");
			if (w > 0)
			{
				SetEntProp(w, Prop_Send, "m_iClip1", 1);
			}
			g_reload = true;
			CreateTimer(STEP, Timer_ReloadOff);
			return true;
		}
		case OP_DROP:
		{
			if (!BotOk())
			{
				return false;
			}
			int w = GetEntPropEnt(g_bot, Prop_Send, "m_hActiveWeapon");
			if (w > 0)
			{
				GetEdictClassname(w, g_dropClass, sizeof(g_dropClass));
				CS_DropWeapon(g_bot, w, true);
			}
			return true;
		}
		case OP_PICKUP:
		{
			if (!BotOk())
			{
				return false;
			}
			int ent = -1;
			while ((ent = FindEntityByClassname(ent, g_dropClass)) != -1)
			{
				if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") == -1)
				{
					EquipPlayerWeapon(g_bot, ent);
					FakeClientCommand(g_bot, "use %s", g_dropClass);
					break;
				}
			}
			return true;
		}
		case OP_RESPAWN:
		{
			if (g_bot > 0 && IsClientInGame(g_bot))
			{
				CS_RespawnPlayer(g_bot);
				SetEntProp(g_bot, Prop_Data, "m_takedamage", 0);
			}
			return true;
		}
		case OP_WAIT:
		{
			g_waitSteps = arg;
			return true;
		}
		case OP_CHECK:
		{
			DoCheck(arg, arg2);
		}
	}
	return false;
}

public Action Timer_ReloadOff(Handle timer)
{
	g_reload = false;
	return Plugin_Stop;
}

// The first 'use' after a spawn can be ignored; re-issue it until the weapon is in hand.
void EnsureWeapon()
{
	char cls[32];
	int active = GetEntPropEnt(g_bot, Prop_Send, "m_hActiveWeapon");
	if (active > 0)
	{
		GetEdictClassname(active, cls, sizeof(cls));
	}
	if (!StrEqual(cls, g_weapons[g_weapon]))
	{
		int slot0 = GetPlayerWeaponSlot(g_bot, 0);
		if (slot0 > 0)
		{
			EquipPlayerWeapon(g_bot, slot0);
		}
		FakeClientCommand(g_bot, "use %s", g_weapons[g_weapon]);
	}
}

void ApplyState(int state, bool resetScope, bool resetTimers)
{
	g_zoomBlockedCmds = 0;
	g_blockedCmds = 0;
	g_nsaChanges = 0;
	g_lastNsa = -1.0;
	float v[3];
	float pos[3];
	pos[0] = g_spawn[0];
	pos[1] = g_spawn[1];
	pos[2] = g_spawn[2];
	g_duck = false;
	SetEntityMoveType(g_bot, MOVETYPE_WALK);
	if (resetScope)
	{
		SetEntProp(g_bot, Prop_Send, "m_iFOV", 90);
	}
	int w = GetEntPropEnt(g_bot, Prop_Send, "m_hActiveWeapon");
	if (w > 0 && resetTimers)
	{
		SetEntPropFloat(w, Prop_Send, "m_flNextPrimaryAttack", 0.0);
		SetEntPropFloat(w, Prop_Send, "m_flNextSecondaryAttack", 0.0);
		SetEntProp(w, Prop_Data, "m_bInReload", 0);
		SetEntProp(w, Prop_Send, "m_iClip1", 10);
	}
	SetEntPropFloat(g_bot, Prop_Send, "m_flNextAttack", 0.0);
	switch (state)
	{
		case S_JUMP:
		{
			v[2] = 400.0;
		}
		case S_CROUCHJUMP:
		{
			v[2] = 400.0;
			g_duck = true;
		}
		case S_LEDGE:
		{
			pos[2] += 500.0;
		}
		case S_LADDER:
		{
			pos[2] += 100.0;
			SetEntityMoveType(g_bot, MOVETYPE_LADDER);
		}
		case S_WATER:
		{
			pos[2] += 100.0;
			SetEntityMoveType(g_bot, MOVETYPE_FLY);
		}
	}
	TeleportEntity(g_bot, pos, NULL_VECTOR, v);
}

void DoCheck(int kind, int nameIdx)
{
	char name[160];
	char detail[160];
	g_names.GetString(nameIdx, name, sizeof(name));
	if (!BotOk())
	{
		Report(false, name, "bot is gone or dead");
		return;
	}
	char cls[32];
	int active = GetEntPropEnt(g_bot, Prop_Send, "m_hActiveWeapon");
	if (active > 0)
	{
		GetEdictClassname(active, cls, sizeof(cls));
	}
	if (!StrEqual(cls, g_weapons[g_weapon]))
	{
		Format(detail, sizeof(detail), "setup failed: active weapon is %s", cls);
		Report(false, name, detail);
		return;
	}
	int fov = GetEntProp(g_bot, Prop_Send, "m_iFOV");
	bool attack2 = (g_postButtons & IN_ATTACK2) != 0;
	bool scoped = (fov > 0 && fov < 90);   // 0 or 90 both mean the default view
	bool zoomer = (g_weapon != W_UNRESTRICTED);
	bool ok = false;
	switch (kind)
	{
		case K_SCOPE:
		{
			bool blocked = ExpectBlocked(g_mask, g_weapon, g_state);
			// allowed: the plugin let secondary attack through, and a scope weapon zoomed
			bool allowed = attack2 && (!zoomer || scoped);
			bool denied = !attack2 && (!zoomer || !scoped);
			ok = blocked ? denied : allowed;
			Format(detail, sizeof(detail), "expected %s, observed attack2=%d fov=%d", blocked ? "blocked" : "allowed", attack2, fov);
		}
		case K_UNSCOPED:
		{
			ok = !scoped;
			Format(detail, sizeof(detail), "expected unscoped, observed fov=%d", fov);
		}
		case K_FIRE:
		{
			ok = (g_shots > g_shotsAtFire);
			Format(detail, sizeof(detail), "expected a registered shot, observed %d", g_shots - g_shotsAtFire);
		}
		case K_NOZOOMBLOCKED:
		{
			ok = (g_zoomBlockedCmds == 0);
			Format(detail, sizeof(detail), "expected no zoomed command in a blocked state, observed %d", g_zoomBlockedCmds);
		}
		case K_NSAQUIET:
		{
			// a refresh now and then is fine; every tick is the Beta 6 resend
			ok = (g_blockedCmds >= 10 && g_nsaChanges * 4 <= g_blockedCmds);
			Format(detail, sizeof(detail), "expected at most a quarter of %d blocked commands to see a new time, observed %d", g_blockedCmds, g_nsaChanges);
		}
	}
	Report(ok, name, ok ? "" : detail);
}
