/**
	DisableScopes regression suite (tracer bullet).

	Treats the compiled plugin as a black box: it only looks at the plugin's
	state in SourceMod and at its public cvars, so any build runs unchanged.
	Results go to addons/sourcemod/logs/disablescopes_tests.log.
	Unattended: test.ps1 in the repo root.
*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_FILE "disablescopes.smx"
#define START_DELAY 10.0

enum
{
	C_RUNNING = 0,
	C_CVARS,
	NUM_CASES
};

static const char g_caseNames[NUM_CASES][] =
{
	"plugin under test is running",
	"all seven cvars exist"
};

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

public Plugin myinfo =
{
	name = "disablescopes_tests",
	author = "BallGanda",
	description = "Regression suite for sm_disablescopes",
	version = "0.1.0",
	url = ""
};

public void OnPluginStart()
{
	g_cvAutorun = CreateConVar("disablescopes_test_autorun", "0", "Run the suite after map start, then quit the server.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvInjectError = CreateConVar("disablescopes_test_inject_error", "0", "Log a deliberate error (checks that error detection works).", FCVAR_NONE, true, 0.0, true, 1.0);
	RegServerCmd("disablescopes_test", Cmd_Run, "Run the DisableScopes suite");
	BuildPath(Path_SM, g_logPath, sizeof(g_logPath), "logs/disablescopes_tests.log");
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
	ServerCommand("quit");
	return Plugin_Stop;
}

public Action Cmd_Run(int args)
{
	RunSuite();
	return Plugin_Handled;
}

void Report(bool ok, int caseId, const char[] detail)
{
	if (ok)
	{
		g_pass++;
	}
	else
	{
		g_fail++;
	}
	LogToFileEx(g_logPath, "[%s] %s%s%s", ok ? "PASS" : "FAIL", g_caseNames[caseId], detail[0] ? " - " : "", detail);
}

void RunSuite()
{
	g_pass = 0;
	g_fail = 0;
	LogToFileEx(g_logPath, "=== DisableScopes tests started (%d cases) ===", NUM_CASES);

	if (g_cvInjectError.BoolValue)
	{
		LogError("deliberate error injected by disablescopes_test_inject_error");
	}

	Handle plugin = FindPluginByFile(PLUGIN_FILE);
	bool running = plugin != null && GetPluginStatus(plugin) == Plugin_Running;
	Report(running, C_RUNNING, running ? "" : "plugin is not running");

	char missing[256];
	for (int i = 0; i < sizeof(g_cvars); i++)
	{
		if (FindConVar(g_cvars[i]) == null)
		{
			Format(missing, sizeof(missing), "%s%s%s", missing, missing[0] ? ", " : "missing: ", g_cvars[i]);
		}
	}
	Report(!missing[0], C_CVARS, missing);

	LogToFileEx(g_logPath, "tests finished: %d passed, %d failed, 0 skipped", g_pass, g_fail);
}
