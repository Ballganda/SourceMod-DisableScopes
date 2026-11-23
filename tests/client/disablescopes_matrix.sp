/**
	DisableScopes visual-matrix helper: the server side of Invoke-VisualMatrix.ps1.

	Not part of the always-deployed suite: the matrix runner compiles and deploys it for the
	length of one run and removes it afterwards. It treats the plugin under test as a black box
	and only sets its public cvars.

	The first real client is put on CT. The client drives it with console commands bound to keys:
	  dsc_lag <ms>   set the simulated latency (server net_fakelag) and log a "lag" row
	  dsc_case <idx> <weapon> <awp> <scout> <auto> <weak> <inair> <onground>
	                 set the plugin cvars for one case, give the player that weapon alone at the
	                 fixed spot, unscoped, and log a "case" row (text "<idx> <weapon> <rule bits>")
	  dsc_mark <label>   log a marker row
	Every command of the client is logged to logs/disablescopes_matrix.csv (server tick, engine
	time in ms, command number, final buttons after every plugin ran, on ground, m_iFOV, active
	weapon, whether it can scope yet). Every shot the server registers (weapon_fire) is logged as a
	"shot" row with the field of view and ground flag at that moment.

	When the client disconnects after the run the server quits.

	Remote build (spcomp DSC_REMOTE=1, used by Invoke-VisualMatrix.ps1 -Remote against a live server):
	the server never quits (no timeout timer, no quit on disconnect), sv_cheats and net_fakelag are
	never touched (dsc_lag only logs its row; the latency is the real one), and the mp_* run cvars are
	applied when the client arrives, not at plugin load. The version string ends in "-remote" so the
	runner can tell this build from the local one.
*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

#define QUIT_AFTER_SEC 1500.0

#if defined DSC_REMOTE
#define DSC_VERSION "0.1.0-remote"
#else
#define DSC_VERSION "0.1.0"
#endif

char g_csvPath[PLATFORM_MAX_PATH];
File g_csv = null;
int g_client = 0;
bool g_ready = false;
int g_armTries = 0;
float g_view[3] = {-40.0, 90.0, 0.0};      // looking up at the sky on de_dust2: a plain, bright background
ConVar g_cvSelfCheck = null;
ConVar g_cvFakelag = null;

public Plugin myinfo =
{
	name = "disablescopes_matrix",
	author = "BallGanda",
	description = "Server side of the DisableScopes visual matrix",
	version = DSC_VERSION,
	url = ""
};

public void OnPluginStart()
{
	BuildPath(Path_SM, g_csvPath, sizeof(g_csvPath), "logs/disablescopes_matrix.csv");
	g_cvSelfCheck = CreateConVar("disablescopes_matrix_selfcheck", "0", "1: keep sm_disablescopes_enable 0 for the whole run (the matrix MUST fail).", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvFakelag = FindConVar("net_fakelag");
	RegConsoleCmd("dsc_mark", Cmd_Mark, "dsc_mark <label>: write a marker row");
	RegConsoleCmd("dsc_lag", Cmd_Lag, "dsc_lag <ms>: set the simulated latency");
	RegConsoleCmd("dsc_view", Cmd_View, "dsc_view <pitch> <yaw>: the view every case starts from (the runner picks one whose screen edges are bright)");
	RegConsoleCmd("dsc_case", Cmd_Case, "dsc_case <idx> <weapon> <awp> <scout> <auto> <weak> <inair> <onground>");
	HookEvent("weapon_fire", Event_WeaponFire);
}

public void OnMapStart()
{
#if !defined DSC_REMOTE
	ApplyRunCvars();
#endif
	delete g_csv;
#if defined DSC_REMOTE
	// Append: the live server changes map on its own, and truncating here cut the rows the runner had
	// already counted (it reads only the lines after its starting line count).
	bool fresh = !FileExists(g_csvPath) || FileSize(g_csvPath) == 0;
	g_csv = OpenFile(g_csvPath, "a");
	if (fresh)
	{
		g_csv.WriteLine("kind,tick,engine_ms,cmdnum,buttons,onground,fov,weapon,ready2,text");
	}
#else
	g_csv = OpenFile(g_csvPath, "w");
	g_csv.WriteLine("kind,tick,engine_ms,cmdnum,buttons,onground,fov,weapon,ready2,text");
#endif
	g_csv.Flush();
#if !defined DSC_REMOTE
	CreateTimer(QUIT_AFTER_SEC, Timer_Quit, _, TIMER_FLAG_NO_MAPCHANGE);
#endif
}

void ApplyRunCvars()
{
	ServerCommand("mp_ignore_round_win_conditions 1; mp_autokick 0; mp_freezetime 0; mp_roundtime 9; mp_timelimit 0; mp_limitteams 0; mp_autoteambalance 0");
#if defined DSC_REMOTE
	// The live server keeps bots in play; they killed the probe client before it was armed (no ready row)
	// or during a case (no scope, no shot). The runner restores bot_quota from its snapshot afterwards.
	ServerCommand("bot_quota 0");
#else
	ServerCommand("sv_cheats 1");
#endif
}

public Action Timer_Quit(Handle timer)
{
	WriteRow("timeout", 0, 0, "");
	ServerCommand("quit");
	return Plugin_Stop;
}

public void OnClientPutInServer(int client)
{
	if (!IsFakeClient(client) && !IsClientSourceTV(client) && g_client == 0)
	{
		g_client = client;
		CreateTimer(6.0, Timer_Place, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnClientDisconnect(int client)
{
	if (client == g_client)
	{
		WriteRow("disconnect", 0, 0, "");
		g_client = 0;
#if defined DSC_REMOTE
		g_ready = false;        // the next run's client must log its own ready row
#else
		if (g_ready)
		{
			ServerCommand("quit");
		}
#endif
	}
}

public Action Timer_Place(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0)
	{
		return Plugin_Stop;
	}
#if defined DSC_REMOTE
	ApplyRunCvars();
#endif
	ChangeClientTeam(client, CS_TEAM_CT);
	FakeClientCommand(client, "joinclass 1");
	CS_RespawnPlayer(client);
	HidePanels(client);
	g_armTries = 0;
	CreateTimer(1.0, Timer_Arm, userid, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

public Action Timer_Arm(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0)
	{
		return Plugin_Stop;
	}
	if (GetClientTeam(client) != CS_TEAM_CT || !IsPlayerAlive(client))
	{
		// Not placed yet (still loading, or killed before arming): place again instead of never logging ready.
		if (++g_armTries <= 20)
		{
			ChangeClientTeam(client, CS_TEAM_CT);
			CS_RespawnPlayer(client);
			CreateTimer(1.0, Timer_Arm, userid, TIMER_FLAG_NO_MAPCHANGE);
		}
		else
		{
			WriteRow("arm_failed", 0, 0, "");
		}
		return Plugin_Stop;
	}
	HidePanels(client);
	SetPluginCvar("sm_disablescopes_enable", g_cvSelfCheck.BoolValue ? 0 : 1);
	Arm(client, "weapon_awp");
	g_ready = true;
	WriteRow("ready", 0, 0, g_cvSelfCheck.BoolValue ? "selfcheck" : "");
	return Plugin_Stop;
}

void SetPluginCvar(const char[] name, int value)
{
	ConVar cv = FindConVar(name);
	if (cv == null)
	{
		LogError("plugin cvar %s not found", name);
		return;
	}
	cv.SetInt(value);
}

void HidePanels(int client)
{
	ShowVGUIPanel(client, "info", null, false);
	ShowVGUIPanel(client, "team", null, false);
	ShowVGUIPanel(client, "class_ct", null, false);
	ShowVGUIPanel(client, "class_ter", null, false);
}

void Arm(int client, const char[] weaponName)
{
	if (!IsPlayerAlive(client))
	{
		CS_RespawnPlayer(client);
	}
	for (int slot = 0; slot < 5; slot++)
	{
		int w;
		while ((w = GetPlayerWeaponSlot(client, slot)) != -1)
		{
			RemovePlayerItem(client, w);
			AcceptEntityInput(w, "Kill");
		}
	}
	int gun = GivePlayerItem(client, weaponName);
	if (gun != -1)
	{
		EquipPlayerWeapon(client, gun);
	}
	float zero[3] = {0.0, 0.0, 0.0};
	TeleportEntity(client, NULL_VECTOR, g_view, zero);
	SetEntProp(client, Prop_Send, "m_iFOV", 0);
}

public Action Cmd_Mark(int client, int args)
{
	char text[64];
	GetCmdArgString(text, sizeof(text));
	ReplaceString(text, sizeof(text), ",", ";");
	WriteRow("mark", 0, 0, text);
	return Plugin_Handled;
}

public Action Cmd_View(int client, int args)
{
	if (client != g_client || args < 2 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return Plugin_Handled;
	}
	g_view[0] = GetCmdArgFloat(1);
	g_view[1] = GetCmdArgFloat(2);
	float zero[3] = {0.0, 0.0, 0.0};
	TeleportEntity(client, NULL_VECTOR, g_view, zero);
	char text[32];
	Format(text, sizeof(text), "%.0f %.0f", g_view[0], g_view[1]);
	WriteRow("view", 0, 0, text);
	return Plugin_Handled;
}

public Action Cmd_Lag(int client, int args)
{
	if (client != g_client || args < 1)
	{
		return Plugin_Handled;
	}
	int ms = GetCmdArgInt(1);
#if !defined DSC_REMOTE
	if (g_cvFakelag != null)
	{
		g_cvFakelag.SetInt(ms);
	}
#endif
	char text[16];
	Format(text, sizeof(text), "%d", ms);
	WriteRow("lag", 0, 0, text);
	return Plugin_Handled;
}

public Action Cmd_Case(int client, int args)
{
	if (client != g_client || !IsClientInGame(client) || args < 8)
	{
		return Plugin_Handled;
	}
	char weaponName[32];
	GetCmdArg(2, weaponName, sizeof(weaponName));
	SetPluginCvar("sm_disablescopes_enable", g_cvSelfCheck.BoolValue ? 0 : 1);
	SetPluginCvar("sm_disablescopes_awp", GetCmdArgInt(3));
	SetPluginCvar("sm_disablescopes_scout", GetCmdArgInt(4));
	SetPluginCvar("sm_disablescopes_autosnipers", GetCmdArgInt(5));
	SetPluginCvar("sm_disablescopes_weaksnipers", GetCmdArgInt(6));
	SetPluginCvar("sm_disablescopes_inair", GetCmdArgInt(7));
	SetPluginCvar("sm_disablescopes_onground", GetCmdArgInt(8));
	Arm(client, weaponName);
	char text[64];
	Format(text, sizeof(text), "%d %s %d%d%d%d inair=%d onground=%d", GetCmdArgInt(1), weaponName,
		GetCmdArgInt(3), GetCmdArgInt(4), GetCmdArgInt(5), GetCmdArgInt(6), GetCmdArgInt(7), GetCmdArgInt(8));
	WriteRow("case", 0, 0, text);
	return Plugin_Handled;
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client == g_client)
	{
		char weaponName[32];
		event.GetString("weapon", weaponName, sizeof(weaponName));
		WriteRow("shot", 0, 0, weaponName);
	}
}

void WriteRow(const char[] kind, int cmdnum, int buttons, const char[] text)
{
	if (g_csv == null)
	{
		return;
	}
	int client = g_client;
	int onground = -1, fov = -1, ready2 = -1;
	char weapon[32] = "";
	if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
	{
		onground = (GetEntityFlags(client) & FL_ONGROUND) ? 1 : 0;
		fov = GetEntProp(client, Prop_Send, "m_iFOV");
		int w = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (w != -1 && IsValidEntity(w))
		{
			GetEdictClassname(w, weapon, sizeof(weapon));
			ready2 = GetEntPropFloat(w, Prop_Send, "m_flNextSecondaryAttack") <= GetGameTime() ? 1 : 0;
		}
	}
	g_csv.WriteLine("%s,%d,%.1f,%d,%d,%d,%d,%s,%d,%s", kind, GetGameTickCount(), GetEngineTime() * 1000.0,
		cmdnum, buttons, onground, fov, weapon, ready2, text);
	g_csv.Flush();
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3],
	int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	if (g_ready && client == g_client && IsPlayerAlive(client))
	{
		WriteRow("cmd", cmdnum, buttons, "");
	}
}

public void OnPluginEnd()
{
	delete g_csv;
}
