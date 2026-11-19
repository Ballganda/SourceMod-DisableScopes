/**
	DisableScopes cost-channel helper.

	Fills the server with AI-less fake clients, gives them restricted or
	unrestricted weapons, profiles with the SourceMod profiler for a fixed
	window and logs one BENCH line with what the runner (bench.ps1) needs:
	client count, ticks and seconds in the window, tick rate held, weapons held.
	Treats the plugin under test as a black box. Inert unless
	disablescopes_bench_autorun is 1.
*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

#define START_DELAY 8.0
#define SPAWN_STEP 0.15
#define SETTLE_TIME 6.0

ConVar g_cvAutorun = null;
ConVar g_cvClients = null;
ConVar g_cvScenario = null;
ConVar g_cvSeconds = null;
ConVar g_cvTickrate = null;
char g_logPath[PLATFORM_MAX_PATH];
int g_spawned = 0;
int g_want = 0;
int g_startTick = 0;
float g_startTime = 0.0;
int g_users[MAXPLAYERS + 1];
int g_userCount = 0;

static const char g_restricted[][] =
{
	"weapon_awp", "weapon_scout", "weapon_g3sg1", "weapon_sg550", "weapon_sg552", "weapon_aug"
};

public Plugin myinfo =
{
	name = "disablescopes_bench",
	author = "BallGanda",
	description = "Cost-channel load helper for sm_disablescopes",
	version = "0.1.0",
	url = ""
};

public void OnPluginStart()
{
	g_cvAutorun = CreateConVar("disablescopes_bench_autorun", "0", "Run the cost benchmark after map start, then quit the server.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvClients = CreateConVar("disablescopes_bench_clients", "20", "Fake clients to spawn (two teams, split evenly).", FCVAR_NONE, true, 2.0, true, 64.0);
	g_cvScenario = CreateConVar("disablescopes_bench_scenario", "0", "0 = nobody holds a restricted weapon, 1 = everybody does.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvSeconds = CreateConVar("disablescopes_bench_seconds", "30", "Profiled window in seconds.", FCVAR_NONE, true, 5.0, true, 600.0);
	g_cvTickrate = CreateConVar("disablescopes_bench_tickrate", "66", "Target tick rate; the run reports whether it was held.", FCVAR_NONE, true, 10.0, true, 200.0);
	BuildPath(Path_SM, g_logPath, sizeof(g_logPath), "logs/disablescopes_bench.log");
}

public void OnMapStart()
{
	if (g_cvAutorun.BoolValue)
	{
		CreateTimer(START_DELAY, Timer_Begin, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_Begin(Handle timer)
{
	LogToFileEx(g_logPath, "=== bench started ===");
	ServerCommand("bot_quota 0");
	ServerCommand("mp_ignore_round_win_conditions 1");
	ServerCommand("mp_autokick 0");
	ServerCommand("mp_limitteams 0");
	ServerCommand("mp_autoteambalance 0");
	ServerCommand("mp_freezetime 0");
	ServerCommand("mp_roundtime 9");
	ServerCommand("mp_timelimit 0");
	// In air and on ground both blocked: every client takes the full path in the plugin.
	ServerCommand("sm_disablescopes_inair 1");
	ServerCommand("sm_disablescopes_onground 1");
	g_want = g_cvClients.IntValue;
	g_spawned = 0;
	g_userCount = 0;
	CreateTimer(SPAWN_STEP, Timer_Spawn, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

public Action Timer_Spawn(Handle timer)
{
	if (g_spawned >= g_want)
	{
		CreateTimer(SETTLE_TIME, Timer_Equip, _, TIMER_FLAG_NO_MAPCHANGE);
		return Plugin_Stop;
	}
	char name[32];
	Format(name, sizeof(name), "bench%d", g_spawned);
	int client = CreateFakeClient(name);
	if (client > 0)
	{
		ChangeClientTeam(client, (g_spawned % 2) ? CS_TEAM_CT : CS_TEAM_T);
		CS_RespawnPlayer(client);
		g_users[g_userCount++] = GetClientUserId(client);
	}
	g_spawned++;
	return Plugin_Continue;
}

public Action Timer_Equip(Handle timer)
{
	int scenario = g_cvScenario.IntValue;
	for (int i = 0; i < g_userCount; i++)
	{
		int client = GetClientOfUserId(g_users[i]);
		if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
		{
			continue;
		}
		if (scenario == 1)
		{
			char item[32];
			strcopy(item, sizeof(item), g_restricted[i % sizeof(g_restricted)]);
			GivePlayerItem(client, item);
			FakeClientCommand(client, "use %s", item);
		}
		else
		{
			FakeClientCommand(client, "use weapon_knife");
		}
	}
	CreateTimer(2.0, Timer_Profile, _, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

int CountAlive()
{
	int n = 0;
	for (int i = 0; i < g_userCount; i++)
	{
		int client = GetClientOfUserId(g_users[i]);
		if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
		{
			n++;
		}
	}
	return n;
}

int CountHoldingRestricted()
{
	int n = 0;
	char cls[32];
	for (int i = 0; i < g_userCount; i++)
	{
		int client = GetClientOfUserId(g_users[i]);
		if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
		{
			continue;
		}
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (weapon <= 0 || !IsValidEntity(weapon))
		{
			continue;
		}
		GetEdictClassname(weapon, cls, sizeof(cls));
		for (int w = 0; w < sizeof(g_restricted); w++)
		{
			if (StrEqual(cls, g_restricted[w]))
			{
				n++;
				break;
			}
		}
	}
	return n;
}

public Action Timer_Profile(Handle timer)
{
	g_startTick = GetGameTickCount();
	g_startTime = GetEngineTime();
	ServerCommand("sm prof start");
	CreateTimer(g_cvSeconds.FloatValue, Timer_Finish, _, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

public Action Timer_Finish(Handle timer)
{
	int ticks = GetGameTickCount() - g_startTick;
	float secs = GetEngineTime() - g_startTime;
	ServerCommand("sm prof stop");
	float rate = secs > 0.0 ? ticks / secs : 0.0;
	int alive = CountAlive();
	int holding = CountHoldingRestricted();
	bool held = rate >= g_cvTickrate.FloatValue * 0.98;
	LogToFileEx(g_logPath, "BENCH clients=%d alive=%d holding=%d scenario=%d ticks=%d seconds=%.2f tickrate=%.2f held=%d",
		g_userCount, alive, holding, g_cvScenario.IntValue, ticks, secs, rate, held ? 1 : 0);
	ServerCommand("sm prof dump vprof");
	CreateTimer(3.0, Timer_Quit, _, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

public Action Timer_Quit(Handle timer)
{
	LogToFileEx(g_logPath, "=== bench finished ===");
	ServerCommand("quit");
	return Plugin_Stop;
}
