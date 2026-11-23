/**
	Scope-prediction spike helper (ticket #4). Not part of the regression suite:
	Run-ScopeSpike.ps1 compiles, deploys and removes it for the length of one run.

	Puts the first real client on CT with an AWP at a fixed spot and view, then logs
	server state for that client every command to logs/scope_spike.csv:
	server tick, command number, final buttons (after every plugin ran), on ground,
	m_iFOV, the weapon's m_flNextSecondaryAttack and game time.
	The client sets the simulated latency with "spike_lag <ms>" (server net_fakelag).
*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

char g_csvPath[PLATFORM_MAX_PATH];
File g_csv = null;
int g_client = 0;
ConVar g_cvFakelag = null;

ConVar g_cvPitch = null;
ConVar g_cvYaw = null;

public Plugin myinfo =
{
	name = "scope_spike",
	author = "BallGanda",
	description = "Ticket #4 spike helper: logs scope state of the real client",
	version = "0.1.0",
	url = ""
};

public void OnPluginStart()
{
	BuildPath(Path_SM, g_csvPath, sizeof(g_csvPath), "logs/scope_spike.csv");
	g_cvFakelag = FindConVar("net_fakelag");
	g_cvPitch = CreateConVar("spike_pitch", "-40", "view pitch set on arm");
	g_cvYaw = CreateConVar("spike_yaw", "90", "view yaw set on arm");
	RegConsoleCmd("spike_lag", Cmd_Lag, "spike_lag <ms>: set server net_fakelag");
	RegConsoleCmd("spike_mark", Cmd_Mark, "spike_mark <text>: write a marker row");
	RegConsoleCmd("spike_reset", Cmd_Reset, "respawn on the spike spot with a fresh AWP");
}

public void OnMapStart()
{
	ServerCommand("mp_ignore_round_win_conditions 1; mp_autokick 0; mp_freezetime 0; mp_roundtime 9; mp_timelimit 0; mp_limitteams 0; mp_autoteambalance 0");
	if (g_csv != null)
	{
		delete g_csv;
	}
	g_csv = OpenFile(g_csvPath, "w");
	g_csv.WriteLine("kind,tick,cmdnum,buttons,onground,fov,next2,gametime,lag,text");
	g_csv.Flush();
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
		g_client = 0;
		WriteRow("disconnect", 0, 0, "");
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
	Arm(client);
	WriteRow("ready", 0, 0, "");
	LogMessage("SPIKE READY client %d", client);
	return Plugin_Stop;
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
	float ang[3];
	ang[0] = g_cvPitch.FloatValue;
	ang[1] = g_cvYaw.FloatValue;
	ang[2] = 0.0;
	float zero[3] = {0.0, 0.0, 0.0};
	TeleportEntity(client, NULL_VECTOR, ang, zero);
	SetEntProp(client, Prop_Send, "m_iFOV", 0);
}

public Action Cmd_Lag(int client, int args)
{
	int ms = GetCmdArgInt(1);
	if (g_cvFakelag != null)
	{
		g_cvFakelag.SetInt(ms);
	}
	WriteRow("lag", 0, 0, "");
	return Plugin_Handled;
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
	if (client > 0 && IsClientInGame(client))
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
	int onground = -1, fov = -1;
	float next2 = -1.0;
	if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
	{
		onground = (GetEntityFlags(client) & FL_ONGROUND) ? 1 : 0;
		fov = GetEntProp(client, Prop_Send, "m_iFOV");
		int w = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (w != -1 && IsValidEntity(w))
		{
			next2 = GetEntPropFloat(w, Prop_Send, "m_flNextSecondaryAttack");
		}
	}
	g_csv.WriteLine("%s,%d,%d,%d,%d,%d,%.4f,%.4f,%d,%s", kind, GetGameTickCount(), cmdnum, buttons,
		onground, fov, next2, GetGameTime(), g_cvFakelag != null ? g_cvFakelag.IntValue : -1, text);
	g_csv.Flush();
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3],
	int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	if (client == g_client && IsPlayerAlive(client))
	{
		WriteRow("cmd", cmdnum, buttons, "");
	}
}

public void OnMapEnd()
{
	if (g_csv != null)
	{
		delete g_csv;
	}
}

public void OnPluginEnd()
{
	if (g_csv != null)
	{
		g_csv.Flush();
		delete g_csv;
	}
}
