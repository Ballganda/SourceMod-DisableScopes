/**
	Ticket #11 spike: what the game does to a weapon's next-secondary-attack time, and what the
	ground-entity hook sees, with no DisableScopes loaded.

	For each restricted weapon: the time is set to a sentinel far ahead, then the bot deploys the
	weapon, reloads it and fires it; the log says whether the game replaced the sentinel, and for a
	shot and a reload whether that happened before the event fired. Then the bot is launched off the
	ground and lands; the log shows the ground flag and ground entity inside SDKHook_GroundEntChangedPost
	and one frame later. Results go to addons/sourcemod/logs/nsa_spike.log; the server quits after.
	Run: Run-NsaSpike.ps1.
*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#define STEP 0.25
#define SENTINEL 100.0

static const char g_weapons[][] =
{
	"weapon_awp", "weapon_scout", "weapon_g3sg1", "weapon_sg550", "weapon_sg552", "weapon_aug"
};

ConVar g_cvAutorun = null;
char g_logPath[PLATFORM_MAX_PATH];
int g_bot = 0;
int g_step = 0;
int g_w = 0;
int g_phase = 0;
bool g_press1 = false;
bool g_reload = false;
bool g_logGround = false;
float g_spawn[3];

public Plugin myinfo =
{
	name = "nsa_spike",
	author = "BallGanda",
	description = "Ticket #11 spike: next-secondary-attack resets and ground hook timing",
	version = "0.1.0",
	url = ""
};

public void OnPluginStart()
{
	g_cvAutorun = CreateConVar("nsa_spike_autorun", "0", "Run the spike after map start, then quit.");
	BuildPath(Path_SM, g_logPath, sizeof(g_logPath), "logs/nsa_spike.log");
	HookEvent("weapon_fire", OnTimerEvent);
	HookEvent("weapon_reload", OnTimerEvent);
}

public void OnMapStart()
{
	if (g_cvAutorun.BoolValue)
	{
		CreateTimer(8.0, Timer_Begin, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_Begin(Handle timer)
{
	LogToFileEx(g_logPath, "=== nsa spike started ===");
	ServerCommand("sm plugins unload sm_disablescopes");
	ServerCommand("mp_freezetime 0; mp_ignore_round_win_conditions 1; bot_quota 0; mp_limitteams 0; mp_autoteambalance 0");
	g_bot = CreateFakeClient("NsaSpikeBot");
	if (g_bot > 0)
	{
		ChangeClientTeam(g_bot, 2);
	}
	CreateTimer(STEP, Timer_Step, _, TIMER_REPEAT);
	return Plugin_Stop;
}

int Weapon()
{
	return GetEntPropEnt(g_bot, Prop_Send, "m_hActiveWeapon");
}

float Rel(int w)
{
	return GetEntPropFloat(w, Prop_Send, "m_flNextSecondaryAttack") - GetGameTime();
}

void Arm(int w)
{
	SetEntPropFloat(w, Prop_Send, "m_flNextSecondaryAttack", GetGameTime() + SENTINEL);
}

void Ready(int w)
{
	SetEntPropFloat(w, Prop_Send, "m_flNextPrimaryAttack", 0.0);
	SetEntPropFloat(g_bot, Prop_Send, "m_flNextAttack", 0.0);
	SetEntProp(w, Prop_Data, "m_bInReload", 0);
	SetEntProp(w, Prop_Send, "m_iClip1", 10);
}

void Verdict(const char[] what, int w)
{
	float rel = Rel(w);
	bool kept = rel > SENTINEL - 5.0;
	LogToFileEx(g_logPath, "RESULT %s %s: next-secondary-attack now+%.3f -> %s", g_weapons[g_w], what, rel, kept ? "sentinel kept" : "RESET by the game");
}

public void OnTimerEvent(Event event, const char[] name, bool dontBroadcast)
{
	if (GetClientOfUserId(event.GetInt("userid")) != g_bot)
	{
		return;
	}
	int w = Weapon();
	if (w > 0)
	{
		float rel = Rel(w);
		LogToFileEx(g_logPath, "EVENT %s %s: inside the event next-secondary-attack now+%.3f (%s)", g_weapons[g_w], name, rel, rel > SENTINEL - 5.0 ? "not yet set" : "already set");
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (client != g_bot)
	{
		return Plugin_Continue;
	}
	buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_RELOAD | IN_JUMP);
	if (g_press1)
	{
		buttons |= IN_ATTACK;
	}
	if (g_reload)
	{
		buttons |= IN_RELOAD;
	}
	return Plugin_Changed;
}

public void OnGround(int client)
{
	if (!g_logGround)
	{
		return;
	}
	LogToFileEx(g_logPath, "GROUND inside hook: FL_ONGROUND=%d m_hGroundEntity=%d", (GetEntityFlags(client) & FL_ONGROUND) != 0, GetEntPropEnt(client, Prop_Data, "m_hGroundEntity"));
	RequestFrame(OnGroundFrame, GetClientUserId(client));
}

public void OnGroundFrame(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0)
	{
		LogToFileEx(g_logPath, "GROUND next frame: FL_ONGROUND=%d m_hGroundEntity=%d", (GetEntityFlags(client) & FL_ONGROUND) != 0, GetEntPropEnt(client, Prop_Data, "m_hGroundEntity"));
	}
}

public Action Timer_Step(Handle timer)
{
	g_step++;
	if (g_step > 600)
	{
		LogToFileEx(g_logPath, "ABORT: timed out in phase %d", g_phase);
		ServerCommand("quit");
		return Plugin_Stop;
	}
	if (g_bot <= 0 || !IsClientInGame(g_bot))
	{
		return Plugin_Continue;
	}
	if (!IsPlayerAlive(g_bot))
	{
		CS_RespawnPlayer(g_bot);
		return Plugin_Continue;
	}
	int w = Weapon();
	switch (g_phase)
	{
		case 0:   // settle (the first round's freeze time stops weapon think), then give the weapon
		{
			if (g_step < 40)
			{
				return Plugin_Continue;
			}
			SetEntProp(g_bot, Prop_Data, "m_takedamage", 0);
			int old = GetPlayerWeaponSlot(g_bot, 0);
			if (old > 0)
			{
				RemovePlayerItem(g_bot, old);
				RemoveEntity(old);
			}
			GivePlayerItem(g_bot, g_weapons[g_w]);
			FakeClientCommand(g_bot, "use %s", g_weapons[g_w]);
			g_phase = 1;
		}
		case 1:   // deploy: arm on the weapon, switch to the knife
		{
			int slot0 = GetPlayerWeaponSlot(g_bot, 0);
			if (slot0 <= 0)
			{
				g_phase = 0;
				return Plugin_Continue;
			}
			char cls[32];
			if (w > 0)
			{
				GetEdictClassname(w, cls, sizeof(cls));
			}
			if (!StrEqual(cls, g_weapons[g_w]))
			{
				FakeClientCommand(g_bot, "use %s", g_weapons[g_w]);   // the first 'use' after a spawn can be ignored
				return Plugin_Continue;
			}
			Ready(slot0);
			Arm(slot0);
			FakeClientCommand(g_bot, "use weapon_knife");
			g_phase = 2;
		}
		case 2:   // switch back: deploy
		{
			FakeClientCommand(g_bot, "use %s", g_weapons[g_w]);
			g_phase = 3;
		}
		case 3:   // deploy verdict, then fire from a fresh state
		{
			if (w > 0)
			{
				Verdict("deploy", w);
				Ready(w);
				Arm(w);
				g_press1 = true;
			}
			g_phase = 4;
		}
		case 4:   // fire verdict, then reload
		{
			g_press1 = false;
			if (w > 0)
			{
				Verdict("fire", w);
				Ready(w);
				SetEntProp(w, Prop_Send, "m_iClip1", 1);
				Arm(w);
				g_reload = true;
			}
			g_phase = 5;
		}
		case 5:
		{
			g_reload = false;
			if (w > 0)
			{
				Verdict("reload", w);
			}
			g_w++;
			g_phase = (g_w < sizeof(g_weapons)) ? 0 : 6;
		}
		case 6:   // ground hook timing: launch off the ground
		{
			g_w = 0;
			GetClientAbsOrigin(g_bot, g_spawn);
			SDKHook(g_bot, SDKHook_GroundEntChangedPost, OnGround);
			g_logGround = true;
			float v[3];
			v[2] = 400.0;
			LogToFileEx(g_logPath, "GROUND launching (on ground now: %d)", (GetEntityFlags(g_bot) & FL_ONGROUND) != 0);
			TeleportEntity(g_bot, NULL_VECTOR, NULL_VECTOR, v);
			g_phase = 7;
		}
		case 7, 8, 9, 10, 11, 12:
		{
			g_phase++;
		}
		case 13:
		{
			g_logGround = false;
			LogToFileEx(g_logPath, "=== nsa spike finished ===");
			ServerCommand("quit");
			return Plugin_Stop;
		}
	}
	return Plugin_Continue;
}
