/**
	DisableScopes client-view helper: the server side of the client cases.

	Not part of the always-deployed suite: test.ps1 -Client compiles and deploys it for the
	length of one run and removes it afterwards. It treats the plugin under test as a black box
	and only sets its public cvars.

	Puts the first real client on CT with an AWP at a fixed spot and view, sets the rule for the
	case (inair 1, onground 0, awp 1), then logs server state for that client every command to
	logs/disablescopes_client.csv: server tick, engine time in ms (the clock the runner matches
	screen samples against), command number, final buttons (after every plugin ran), on ground,
	m_iFOV, the active weapon's classname and whether it can scope yet (ready2: its next secondary
	attack time has passed; a freshly given AWP is still deploying). The client writes marker rows with
	"dsc_mark <label>" and respawns with a fresh AWP with "dsc_reset".

	When the client disconnects after the case (to play its demo back) the server quits.
*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

#define QUIT_AFTER_SEC 300.0

char g_csvPath[PLATFORM_MAX_PATH];
File g_csv = null;
int g_client = 0;
bool g_ready = false;
ConVar g_cvSelfCheck = null;

public Plugin myinfo =
{
	name = "disablescopes_client",
	author = "BallGanda",
	description = "Server side of the DisableScopes client-view cases",
	version = "0.1.0",
	url = ""
};

public void OnPluginStart()
{
	BuildPath(Path_SM, g_csvPath, sizeof(g_csvPath), "logs/disablescopes_client.csv");
	g_cvSelfCheck = CreateConVar("disablescopes_client_selfcheck", "0", "1: set sm_disablescopes_enable 0 for the case (the case MUST fail).", FCVAR_NONE, true, 0.0, true, 1.0);
	RegConsoleCmd("dsc_mark", Cmd_Mark, "dsc_mark <label>: write a marker row");
	RegConsoleCmd("dsc_reset", Cmd_Reset, "respawn on the case spot with a fresh AWP, unscoped");
}

public void OnMapStart()
{
	ServerCommand("mp_ignore_round_win_conditions 1; mp_autokick 0; mp_freezetime 0; mp_roundtime 9; mp_timelimit 0; mp_limitteams 0; mp_autoteambalance 0");
	delete g_csv;
	g_csv = OpenFile(g_csvPath, "w");
	g_csv.WriteLine("kind,tick,engine_ms,cmdnum,buttons,onground,fov,weapon,ready2,text");
	g_csv.Flush();
	CreateTimer(QUIT_AFTER_SEC, Timer_Quit, _, TIMER_FLAG_NO_MAPCHANGE);
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
		if (g_ready)
		{
			ServerCommand("quit");
		}
	}
}

public Action Timer_Place(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0)
	{
		return Plugin_Stop;
	}
	ChangeClientTeam(client, CS_TEAM_CT);
	FakeClientCommand(client, "joinclass 1");
	CS_RespawnPlayer(client);
	HidePanels(client);
	CreateTimer(1.0, Timer_Arm, userid, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

public Action Timer_Arm(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || !IsPlayerAlive(client))
	{
		return Plugin_Stop;
	}
	HidePanels(client);
	SetRule();
	Arm(client);
	g_ready = true;
	WriteRow("ready", 0, 0, g_cvSelfCheck.BoolValue ? "selfcheck" : "");
	return Plugin_Stop;
}

// The rule under test: AWP restricted, scope blocked in the air, allowed on the ground.
void SetRule()
{
	SetPluginCvar("sm_disablescopes_enable", g_cvSelfCheck.BoolValue ? 0 : 1);
	SetPluginCvar("sm_disablescopes_awp", 1);
	SetPluginCvar("sm_disablescopes_inair", 1);
	SetPluginCvar("sm_disablescopes_onground", 0);
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

void Arm(int client)
{
	for (int slot = 0; slot < 5; slot++)
	{
		int w;
		while ((w = GetPlayerWeaponSlot(client, slot)) != -1)
		{
			RemovePlayerItem(client, w);
			AcceptEntityInput(w, "Kill");
		}
	}
	int awp = GivePlayerItem(client, "weapon_awp");
	if (awp != -1)
	{
		EquipPlayerWeapon(client, awp);
	}
	float ang[3] = {-40.0, 90.0, 0.0};      // looking up at the sky: a plain, bright background
	float zero[3] = {0.0, 0.0, 0.0};
	TeleportEntity(client, NULL_VECTOR, ang, zero);
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

public Action Cmd_Reset(int client, int args)
{
	if (client > 0 && client == g_client && IsClientInGame(client))
	{
		if (!IsPlayerAlive(client))
		{
			CS_RespawnPlayer(client);
		}
		Arm(client);
		WriteRow("reset", 0, 0, "");
	}
	return Plugin_Handled;
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
