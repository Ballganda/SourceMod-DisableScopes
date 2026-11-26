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
	OP_CHECK,       // arg = kind, arg2 = name index
	OP_MASK,        // arg = bitmask the scope rule expects; cvars left alone (they come from the config file)
	OP_CFG          // arg = config case, arg2 = step (0 sets up and reloads the plugin, 1 checks and restores)
};

// Config file cases (issue #19): each backs up configs/sm_disablescopes.cfg, writes its own, reloads the
// plugin, checks the cvars and the file, then restores the server's file.
enum
{
	CC_CREATED = 0, // no file: one is generated with a commented entry per settings cvar
	CC_LEGACY,      // the file the plugin wrote before the include: applied, left byte-for-byte as it is
	CC_APPEND,      // some cvars missing: appended with defaults, existing text kept
	CC_PARSE,       // quotes, trailing ';' and '//', CRLF, blank and comment lines
	CC_FOREIGN,     // a server cvar and a misspelled name: neither applied, each logged once
	CC_CLAMP,       // out-of-range values clamped to 0..1
	NUM_CFG_CASES
};

static const char g_cfgCaseNames[NUM_CFG_CASES][] =
{
	"config: no file, one is created with a commented entry per settings cvar, none in the game cfg folder",
	"config: file in the old plugin's format applied and left byte-for-byte unchanged",
	"config: missing cvars appended with defaults, existing lines unchanged",
	"config: quotes, trailing ; and //, CRLF, blank and comment lines apply the intended values",
	"config: foreign and misspelled cvars not applied, each logged once",
	"config: out-of-range values clamped to 0..1"
};

// What each case's file sets (bitmask, as g_cvars); before loading, the cvars are set to the opposite.
static const int g_cfgExpect[NUM_CFG_CASES] =
{
	M_DEFAULT,
	B_ENABLE | B_WEAK | B_GROUND,
	M_DEFAULT & ~(B_AWP | B_INAIR),
	B_ENABLE | B_WEAK | B_GROUND,
	M_DEFAULT & ~B_AWP,
	B_ENABLE | B_SCOUT | B_WEAK | B_GROUND
};

// Defaults and description starts, written from the plugin source, not read from it.
static const char g_cvarDefaults[][] = { "1", "1", "1", "1", "1", "1", "0" };
static const char g_cvarDescs[][] =
{
	"sm_disablescopes_enable enables the plugin", "Disable the AWP scope", "Disable the scout scope",
	"Disable the auto snipers scope", "Disable the weak snipers scope", "Disable Scope when the player is jumping",
	"Disable Scope when the player is on ground"
};

#define CFG_FOREIGN "mp_freezetime"
#define CFG_TYPO "sm_disablescopes_awpp"

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

// config cases
char g_cfgPath[PLATFORM_MAX_PATH];   // configs/sm_disablescopes.cfg
char g_cfgBak[PLATFORM_MAX_PATH];    // the server's own file while a case runs
char g_cfgA[16384];                  // file contents under inspection
char g_cfgOld[2048];                 // what the case wrote
int g_logForeign = 0;                // log lines naming each skipped name, before the reload
int g_logTypo = 0;

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
	BuildPath(Path_SM, g_cfgPath, sizeof(g_cfgPath), "configs/sm_disablescopes.cfg");
	BuildPath(Path_SM, g_cfgBak, sizeof(g_cfgBak), "configs/sm_disablescopes.cfg.testbak");
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

	// 3c. a scoped shot unzooms and sets the game's resume-zoom flag; enter a blocked state before the bolt
	//     cycles, with the weapon's timers left as the shot set them: the game must not zoom back in
	int rzMask[2];
	int rzFrom[2];
	int rzTo[2];
	rzMask[0] = M_DEFAULT;
	rzFrom[0] = S_GROUND;
	rzTo[0] = S_WATER;
	rzMask[1] = M_ALL & ~B_INAIR;
	rzFrom[1] = S_WATER;
	rzTo[1] = S_GROUND;
	for (int w = 0; w < 2; w++)   // the AWP and the scout resume their zoom after a shot
	{
		for (int k = 0; k < 2; k++)
		{
			Op(OP_CVARS, rzMask[k]);
			Op(OP_WEAPON, w);
			Op(OP_STATE, rzFrom[k]);
			Op(OP_SCOPE, 1);
			Check(K_SCOPE, "resume zoom: %s scopes, %s", g_weapons[w], g_stateNames[rzFrom[k]]);
			Op(OP_SCOPE, 0);
			Op(OP_FIRE, 1);
			Check(K_FIRE, "resume zoom: %s fires scoped, %s", g_weapons[w], g_stateNames[rzFrom[k]]);
			Op(OP_FIRE, 0);
			Op(OP_STATE, rzTo[k], 3);
			Op(OP_WAIT, 8);
			Check(K_UNSCOPED, "resume zoom: %s shot, then %s: unscoped after the bolt cycles", g_weapons[w], g_stateNames[rzTo[k]]);
			Check(K_NOZOOMBLOCKED, "resume zoom: %s shot, then %s: no command zoomed", g_weapons[w], g_stateNames[rzTo[k]]);
		}
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

	// 7. the config file, read through instance_config.inc. Runs last: each case reloads the plugin.
	for (int c = 0; c < NUM_CFG_CASES; c++)
	{
		if (c == CC_PARSE)
		{
			// the file turns the on-ground rule on: a client already holding the weapon is reclassified
			Op(OP_CVARS, M_DEFAULT);
			Op(OP_WEAPON, 4);
			Op(OP_STATE, S_GROUND);
			Op(OP_SCOPE, 1);
			Check(K_SCOPE, "config: before reload: %s, %s", g_weapons[4], g_stateNames[S_GROUND]);
			Op(OP_SCOPE, 0);
		}
		Op(OP_CFG, c, 0);
		Op(OP_WAIT, 4);
		Op(OP_CFG, c, 1);
		g_total++;
		if (c == CC_PARSE)
		{
			Op(OP_MASK, g_cfgExpect[c]);
			Op(OP_STATE, S_GROUND);
			Op(OP_SCOPE, 1);
			Check(K_SCOPE, "config: after reload, held weapon classified by the file: %s, %s", g_weapons[4], g_stateNames[S_GROUND]);
			Op(OP_SCOPE, 0);
		}
	}
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
			SetCvars(arg);
		}
		case OP_MASK:
		{
			g_mask = arg;
		}
		case OP_CFG:
		{
			if (arg2 == 0)
			{
				CfgSetup(arg);
				return true;
			}
			CfgCheck(arg);
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

void SetCvars(int mask)
{
	g_mask = mask;
	for (int i = 0; i < sizeof(g_cvars); i++)
	{
		FindConVar(g_cvars[i]).SetBool((mask & (1 << i)) != 0);
	}
}

// ---- config cases ----------------------------------------------------------------------------

void CfgSetup(int c)
{
	CfgBackup();
	SetCvars(M_ALL ^ g_cfgExpect[c]);   // every cvar starts opposite to what the file should leave
	g_cfgOld[0] = '\0';
	switch (c)
	{
		case CC_CREATED:
		{
			DeleteFile(g_cfgPath);
		}
		case CC_LEGACY:
		{
			// as the plugin's own config code wrote it, with non-default values
			strcopy(g_cfgOld, sizeof(g_cfgOld), "// sm_disablescopes per-instance config\nsm_disablescopes_enable 1\nsm_disablescopes_awp 0\nsm_disablescopes_scout 0\nsm_disablescopes_autosnipers 0\nsm_disablescopes_weaksnipers 1\nsm_disablescopes_inair 0\nsm_disablescopes_onground 1\n");
		}
		case CC_APPEND:
		{
			strcopy(g_cfgOld, sizeof(g_cfgOld), "// my notes\nsm_disablescopes_awp 0\nsm_disablescopes_inair \"0\"   \n// last line, no newline after it");
		}
		case CC_PARSE:
		{
			// the commented-out lines come after the real ones, so applying them would show
			strcopy(g_cfgOld, sizeof(g_cfgOld), "// custom settings\r\n; a semicolon comment\r\n\r\n   \r\nsm_disablescopes_enable \"1\"\r\n\tsm_disablescopes_awp   0;\r\nsm_disablescopes_scout 0 // trailing note\r\nsm_disablescopes_autosnipers \"0\";\r\n//sm_disablescopes_autosnipers 1\r\n;sm_disablescopes_autosnipers 1\r\nsm_disablescopes_weaksnipers 1\r\nsm_disablescopes_inair \"0\" // quoted, then a comment\r\nsm_disablescopes_onground 1;\r\n");
		}
		case CC_FOREIGN:
		{
			strcopy(g_cfgOld, sizeof(g_cfgOld), CFG_FOREIGN ... " 7\n" ... CFG_TYPO ... " 0\nsm_disablescopes_awp 0\n");
			g_logForeign = CountInSmLog("\"" ... CFG_FOREIGN ... "\" is not a setting");
			g_logTypo = CountInSmLog("\"" ... CFG_TYPO ... "\" is not a setting");
		}
		case CC_CLAMP:
		{
			strcopy(g_cfgOld, sizeof(g_cfgOld), "sm_disablescopes_enable 5\nsm_disablescopes_awp -3\nsm_disablescopes_scout 2\nsm_disablescopes_autosnipers -1\nsm_disablescopes_weaksnipers 9\nsm_disablescopes_inair -7\nsm_disablescopes_onground 3\n");
		}
	}
	if (g_cfgOld[0] != '\0')
	{
		CfgWrite(g_cfgPath, g_cfgOld);
	}
	// unload then load, as OP_SETUP and OP_LOAD do, so the plugin stays after this suite
	ServerCommand("sm plugins unload sm_disablescopes");
	ServerCommand("sm plugins load sm_disablescopes");
}

void CfgCheck(int c)
{
	char why[256];
	bool ok = CfgVerify(c, why, sizeof(why));
	CfgRestore();
	Report(ok, g_cfgCaseNames[c], ok ? "" : why);
}

bool CfgVerify(int c, char[] why, int len)
{
	if (!CvarsMatch(g_cfgExpect[c], why, len))
	{
		return false;
	}
	if (!CfgRead(g_cfgPath, g_cfgA, sizeof(g_cfgA)))
	{
		strcopy(why, len, "config file missing after load");
		return false;
	}
	switch (c)
	{
		case CC_CREATED:
		{
			static const char stray[][] = { "cfg/sourcemod/plugin.sm_disablescopes.cfg", "cfg/sourcemod/sm_disablescopes.cfg", "cfg/sm_disablescopes.cfg", "cfg/plugin.sm_disablescopes.cfg" };
			for (int i = 0; i < sizeof(stray); i++)
			{
				if (FileExists(stray[i]))
				{
					Format(why, len, "a config was written to the game folder: %s", stray[i]);
					return false;
				}
			}
			if (StrContains(g_cfgA, "sm_disablescopes_version") != -1)
			{
				strcopy(why, len, "the version cvar is in the config");
				return false;
			}
			int entries = CountIn(g_cfgA, "\nsm_disablescopes_");
			if (entries != sizeof(g_cvars))
			{
				Format(why, len, "%d entry lines, expected %d", entries, sizeof(g_cvars));
				return false;
			}
			char needle[96];
			char block[1024];
			for (int i = 0; i < sizeof(g_cvars); i++)
			{
				Format(needle, sizeof(needle), "\n%s \"%s\"\n", g_cvars[i], g_cvarDefaults[i]);
				int at = StrContains(g_cfgA, needle);
				if (at == -1)
				{
					Format(why, len, "no entry %s \"%s\"", g_cvars[i], g_cvarDefaults[i]);
					return false;
				}
				CfgBlockBefore(at, block, sizeof(block));
				Format(needle, sizeof(needle), "// %s", g_cvarDescs[i]);
				bool hasDesc = StrContains(block, needle) == 0;
				Format(needle, sizeof(needle), "// Default: %s\n", g_cvarDefaults[i]);
				if (!hasDesc || StrContains(block, needle) == -1 || StrContains(block, "// Min: 0\n") == -1 || StrContains(block, "// Max: 1\n") == -1)
				{
					Format(why, len, "%s: comments lack description, default or 0..1 bounds: %s", g_cvars[i], block);
					return false;
				}
			}
		}
		case CC_LEGACY, CC_PARSE:
		{
			if (!StrEqual(g_cfgA, g_cfgOld))
			{
				strcopy(why, len, "a complete file was changed on load");
				return false;
			}
		}
		case CC_APPEND:
		{
			if (StrContains(g_cfgA, g_cfgOld) != 0)
			{
				strcopy(why, len, "existing content was changed or reordered");
				return false;
			}
			char needle[96];
			int tail = strlen(g_cfgOld);
			for (int i = 0; i < sizeof(g_cvars); i++)
			{
				bool present = (i == 1 || i == 5);   // awp and inair are in the old text
				Format(needle, sizeof(needle), "\n%s \"", g_cvars[i]);
				int n = CountIn(g_cfgA[tail], needle);
				if (n != (present ? 0 : 1))
				{
					Format(why, len, "%s appended %d times, expected %d", g_cvars[i], n, present ? 0 : 1);
					return false;
				}
				Format(needle, sizeof(needle), "\n%s \"%s\"\n", g_cvars[i], g_cvarDefaults[i]);
				if (!present && StrContains(g_cfgA[tail], needle) == -1)
				{
					Format(why, len, "%s not appended with its default %s", g_cvars[i], g_cvarDefaults[i]);
					return false;
				}
			}
		}
		case CC_FOREIGN:
		{
			if (FindConVar(CFG_FOREIGN).IntValue == 7)
			{
				strcopy(why, len, CFG_FOREIGN ... " was set from the plugin's config");
				return false;
			}
			if (FindConVar(CFG_TYPO) != null)
			{
				strcopy(why, len, CFG_TYPO ... " exists");
				return false;
			}
			int nf = CountInSmLog("\"" ... CFG_FOREIGN ... "\" is not a setting") - g_logForeign;
			int nt = CountInSmLog("\"" ... CFG_TYPO ... "\" is not a setting") - g_logTypo;
			if (nf != 1 || nt != 1)
			{
				Format(why, len, "skipped names logged %s x%d, %s x%d, expected once each", CFG_FOREIGN, nf, CFG_TYPO, nt);
				return false;
			}
		}
	}
	return true;
}

// Each cvar's value is exactly 0 or 1 as the mask says (so a value left at 5 or -3 fails).
bool CvarsMatch(int mask, char[] why, int len)
{
	bool ok = true;
	why[0] = '\0';
	for (int i = 0; i < sizeof(g_cvars); i++)
	{
		float want = (mask & (1 << i)) ? 1.0 : 0.0;
		float got = FindConVar(g_cvars[i]).FloatValue;
		if (got != want)
		{
			ok = false;
			Format(why, len, "%s%s%s=%.2f (expected %.0f)", why, why[0] ? ", " : "", g_cvars[i], got, want);
		}
	}
	return ok;
}

// The server's own file is set aside for the case; a backup left by an aborted run is the original.
void CfgBackup()
{
	if (!FileExists(g_cfgBak) && FileExists(g_cfgPath) && CfgRead(g_cfgPath, g_cfgA, sizeof(g_cfgA)))
	{
		CfgWrite(g_cfgBak, g_cfgA);
	}
}

void CfgRestore()
{
	if (!FileExists(g_cfgBak))
	{
		DeleteFile(g_cfgPath);   // the server had none
		return;
	}
	if (CfgRead(g_cfgBak, g_cfgA, sizeof(g_cfgA)))
	{
		CfgWrite(g_cfgPath, g_cfgA);
		DeleteFile(g_cfgBak);
	}
}

void CfgWrite(const char[] path, const char[] text)
{
	File f = OpenFile(path, "wb");
	if (f == null)
	{
		LogError("cannot write %s", path);
		return;
	}
	f.WriteString(text, false);
	delete f;
}

bool CfgRead(const char[] path, char[] out, int max)
{
	out[0] = '\0';
	File f = OpenFile(path, "rb");
	if (f == null)
	{
		return false;
	}
	int size = FileSize(path);
	if (size >= max)
	{
		size = max - 1;
	}
	int n = (size > 0) ? f.ReadString(out, max, size) : 0;
	delete f;
	out[(n > 0) ? n : 0] = '\0';
	return true;
}

// The comment lines directly above the entry whose leading newline is g_cfgA[at] (back to the previous blank line).
void CfgBlockBefore(int at, char[] out, int max)
{
	int start = at;
	while (start > 0 && !(g_cfgA[start - 1] == '\n' && start >= 2 && g_cfgA[start - 2] == '\n'))
	{
		start--;
	}
	int len = at - start + 2;   // includes the newline that ends the last comment line
	if (len > max)
	{
		len = max;
	}
	strcopy(out, len, g_cfgA[start]);
}

int CountIn(const char[] text, const char[] needle)
{
	int n = 0;
	int from = 0;
	int at;
	while ((at = StrContains(text[from], needle)) != -1)
	{
		n++;
		from += at + 1;
	}
	return n;
}

// Lines of today's SourceMod log that contain text.
int CountInSmLog(const char[] text)
{
	char date[16];
	char path[PLATFORM_MAX_PATH];
	char line[512];
	FormatTime(date, sizeof(date), "%Y%m%d");
	BuildPath(Path_SM, path, sizeof(path), "logs/L%s.log", date);
	File f = OpenFile(path, "r");
	if (f == null)
	{
		return 0;
	}
	int n = 0;
	while (f.ReadLine(line, sizeof(line)))
	{
		if (StrContains(line, text) != -1)
		{
			n++;
		}
	}
	delete f;
	return n;
}
