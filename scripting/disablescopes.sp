#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define NAME "[CS:S]sm_disablescopes"
#define AUTHOR "BallGanda"
#define DESCRIPTION "sm_disablescopes of selected weapons & limit air or ground use"
#define PLUGIN_VERSION "0.0.b8"
#define URL "https://github.com/Ballganda/SourceMod-DisableScopes"
#define DS_PREFIX "[DisableScopes]"

public Plugin myinfo = {
    name = NAME,
    author = AUTHOR,
    description = DESCRIPTION,
    version = PLUGIN_VERSION,
    url = URL
};

ConVar g_cvEnablePlugin = null;
ConVar g_cvDisableScopeAwp = null;
ConVar g_cvDisableScopeScout = null;
ConVar g_cvDisableScopeAutoSnipers = null;
ConVar g_cvDisableScopeWeakSnipers = null;
ConVar g_cvDisableInAir = null;
ConVar g_cvDisableOnGround = null;

int g_iCachedWeapon[MAXPLAYERS + 1];
bool g_bCachedIsNoScope[MAXPLAYERS + 1];

bool g_bEntPropsCached = false;
bool g_bHasZoomLevel = false;
bool g_bHasResumeZoom = false;

public void OnPluginStart()
{
    CheckGameVersion();

    RegAdminCmd("sm_disablescopes", smAbout, ADMFLAG_BAN, "sm_disablescopes info in console");

    CreateConVar("sm_disablescopes_version", PLUGIN_VERSION, NAME, FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_cvEnablePlugin = CreateConVar("sm_disablescopes_enable", "1", "sm_disablescopes_enable enables the plugin <1|0>");
    g_cvDisableScopeAwp = CreateConVar("sm_disablescopes_awp", "1", "Disable the AWP scope <1|0>");
    g_cvDisableScopeScout = CreateConVar("sm_disablescopes_scout", "1", "Disable the scout scope <1|0>");
    g_cvDisableScopeAutoSnipers = CreateConVar("sm_disablescopes_autosnipers", "1", "Disable the auto snipers scope <1|0>");
    g_cvDisableScopeWeakSnipers = CreateConVar("sm_disablescopes_weaksnipers", "1", "Disable the weak snipers scope <1|0>");
    g_cvDisableInAir = CreateConVar("sm_disablescopes_inair", "1", "Disable Scope when the player is jumping/off ground <1|0>");
    g_cvDisableOnGround = CreateConVar("sm_disablescopes_onground", "0", "Disable Scope when the player is on ground <1|0>");

    g_cvDisableScopeAwp.AddChangeHook(OnWeaponFilterCvarChanged);
    g_cvDisableScopeScout.AddChangeHook(OnWeaponFilterCvarChanged);
    g_cvDisableScopeAutoSnipers.AddChangeHook(OnWeaponFilterCvarChanged);
    g_cvDisableScopeWeakSnipers.AddChangeHook(OnWeaponFilterCvarChanged);

    for (int i = 0; i <= MaxClients; i++)
    {
        g_iCachedWeapon[i] = -1;
        g_bCachedIsNoScope[i] = false;
    }

    static const char g_DefaultDisableScopesCfg[][] =
    {
        "// sm_disablescopes per-instance config",
        "sm_disablescopes_enable 1",
        "sm_disablescopes_awp 1",
        "sm_disablescopes_scout 1",
        "sm_disablescopes_autosnipers 1",
        "sm_disablescopes_weaksnipers 1",
        "sm_disablescopes_inair 1",
        "sm_disablescopes_onground 0"
    };

    GeneratePerInstanceConfig(
        "sm_disablescopes",
        g_DefaultDisableScopesCfg,
        sizeof(g_DefaultDisableScopesCfg)
    );
}

public void OnConfigsExecuted()
{
    LoadInstanceConfig("sm_disablescopes");
}

public void OnClientDisconnect(int client)
{
    g_iCachedWeapon[client] = -1;
    g_bCachedIsNoScope[client] = false;
}

public void OnWeaponFilterCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    InvalidateWeaponCache();
}

void InvalidateWeaponCache()
{
    for (int i = 0; i <= MaxClients; i++)
    {
        g_iCachedWeapon[i] = -1;
        g_bCachedIsNoScope[i] = false;
    }
}

void GeneratePerInstanceConfig(const char[] cfgName, const char[][] defaultLines, int lineCount)
{
    char cfgDir[PLATFORM_MAX_PATH];
    char cfgPath[PLATFORM_MAX_PATH];

    // addons/sourcemod/configs
    BuildPath(Path_SM, cfgDir, sizeof(cfgDir), "configs");

    // addons/sourcemod/configs/<cfgName>.cfg
    Format(cfgPath, sizeof(cfgPath), "%s/%s.cfg", cfgDir, cfgName);

    PrintToServer("%sCFG FILE: %s", DS_PREFIX, cfgPath);

    // Only create if missing
    if (!FileExists(cfgPath))
    {
        File f = OpenFile(cfgPath, "w");
        if (f == null)
        {
            PrintToServer("%sFAILED to create config file", DS_PREFIX);
            return;
        }

        for (int i = 0; i < lineCount; i++)
        {
            f.WriteLine(defaultLines[i]);
        }

        delete f;
        PrintToServer("%sConfig file created", DS_PREFIX);
    }
    else
    {
        PrintToServer("%sConfig file already exists, not overwriting", DS_PREFIX);
    }
}

void LoadInstanceConfig(const char[] cfgName)
{
    char cfgPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, cfgPath, sizeof(cfgPath), "configs");
    Format(cfgPath, sizeof(cfgPath), "%s/%s.cfg", cfgPath, cfgName);

    File f = OpenFile(cfgPath, "r");
    if (f == null)
    {
        PrintToServer("%sFailed to open instance config", DS_PREFIX);
        return;
    }

    char line[256];
    char cvar[64];
    char value[64];

    while (!f.EndOfFile() && f.ReadLine(line, sizeof(line)))
    {
        TrimString(line);

        // Skip empty lines and comments
        if (line[0] == '\0' || line[0] == '/' || line[0] == ';')
            continue;

        int pos = BreakString(line, cvar, sizeof(cvar));
        if (pos == -1)
            continue;

        strcopy(value, sizeof(value), line[pos]);
        TrimString(value);

        ConVar cv = FindConVar(cvar);
        if (cv == null)
        {
            PrintToServer("%sUnknown cvar in config: %s", DS_PREFIX, cvar);
            continue;
        }

        cv.SetString(value);
    }

    delete f;

    // Weapon filter cvars may have changed from config
    InvalidateWeaponCache();

    PrintToServer("%sInstance config loaded", DS_PREFIX);
}

bool IsNoScopeWeapon(int entityNumber)
{
    char checkClassname[MAX_NAME_LENGTH];
    GetEdictClassname(entityNumber, checkClassname, sizeof(checkClassname));

    if (g_cvDisableScopeAwp.BoolValue && StrEqual(checkClassname, "weapon_awp"))
        return true;

    if (g_cvDisableScopeScout.BoolValue && StrEqual(checkClassname, "weapon_scout"))
        return true;

    if (g_cvDisableScopeAutoSnipers.BoolValue &&
        (StrEqual(checkClassname, "weapon_g3sg1") || StrEqual(checkClassname, "weapon_sg550")))
        return true;

    if (g_cvDisableScopeWeakSnipers.BoolValue &&
        (StrEqual(checkClassname, "weapon_sg552") || StrEqual(checkClassname, "weapon_aug")))
        return true;

    return false;
}

bool IsCachedNoScopeWeapon(int client, int activeWeapon)
{
    if (activeWeapon != g_iCachedWeapon[client])
    {
        g_iCachedWeapon[client] = activeWeapon;
        g_bCachedIsNoScope[client] = IsNoScopeWeapon(activeWeapon);
    }

    return g_bCachedIsNoScope[client];
}

bool ShouldBlockScope(int client)
{
    bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;

    if (onGround)
        return g_cvDisableOnGround.BoolValue;

    return g_cvDisableInAir.BoolValue;
}

void CacheEntPropAvailability(int client, int activeWeapon)
{
    if (g_bEntPropsCached)
        return;

    g_bHasZoomLevel = HasEntProp(activeWeapon, Prop_Send, "m_zoomLevel");
    g_bHasResumeZoom = HasEntProp(client, Prop_Send, "m_bResumeZoom");
    g_bEntPropsCached = true;
}

void ForceUnscope(int client, int activeWeapon, bool pressedAttack2)
{
    // Kill predicted scope window (high-ping fix) — every blocked tick
    SetEntPropFloat(activeWeapon, Prop_Send, "m_flNextSecondaryAttack", GetGameTime() + 0.2);

    // Skip FOV/zoom writes when idle and not scoped
    int fov = GetEntProp(client, Prop_Send, "m_iFOV");
    if (!pressedAttack2 && fov == 0)
        return;

    CacheEntPropAvailability(client, activeWeapon);

    // m_iFOV == 0 means "use default FOV" (not scoped)
    if (fov != 0)
    {
        SetEntProp(client, Prop_Send, "m_iFOV", 0);
    }

    if (g_bHasZoomLevel)
    {
        SetEntProp(activeWeapon, Prop_Send, "m_zoomLevel", 0);
    }

    if (g_bHasResumeZoom)
    {
        SetEntProp(client, Prop_Send, "m_bResumeZoom", 0);
    }
}

public Action OnPlayerRunCmd(
    int client,
    int &buttons,
    int &impulse,
    float vel[3],
    float angles[3],
    int &weapon,
    int &subtype,
    int &cmdnum,
    int &tickcount,
    int &seed,
    int mouse[2]
)
{
    if (!g_cvEnablePlugin.BoolValue || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Continue;

    // Cheap air/ground check before weapon classname work
    if (!ShouldBlockScope(client))
        return Plugin_Continue;

    int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsValidEntity(activeWeapon))
        return Plugin_Continue;

    if (!IsCachedNoScopeWeapon(client, activeWeapon))
        return Plugin_Continue;

    bool pressedAttack2 = (buttons & IN_ATTACK2) != 0;

    // Strip secondary attack so player cannot re-scope
    buttons &= ~IN_ATTACK2;
    ForceUnscope(client, activeWeapon, pressedAttack2);

    return Plugin_Continue;
}

void CheckGameVersion()
{
    if (GetEngineVersion() != Engine_CSS)
    {
        SetFailState("Only CS:S Supported");
    }
}

public Action smAbout(int client, int args)
{
    PrintToConsole(client, "");
    PrintToConsole(client, "Plugin Name.......: %s", NAME);
    PrintToConsole(client, "Plugin Author.....: %s", AUTHOR);
    PrintToConsole(client, "Plugin Description: %s", DESCRIPTION);
    PrintToConsole(client, "Plugin Version....: %s", PLUGIN_VERSION);
    PrintToConsole(client, "Plugin URL........: %s", URL);
    PrintToConsole(client, "List of cvars: ");
    PrintToConsole(client, "sm_disablescopes_version");
    PrintToConsole(client, "sm_disablescopes_enable <1|0>");
    PrintToConsole(client, "sm_disablescopes_awp <1|0>");
    PrintToConsole(client, "sm_disablescopes_scout <1|0>");
    PrintToConsole(client, "sm_disablescopes_autosnipers <1|0>");
    PrintToConsole(client, "sm_disablescopes_weaksnipers <1|0>");
    PrintToConsole(client, "sm_disablescopes_inair <1|0>");
    PrintToConsole(client, "sm_disablescopes_onground <1|0>");
    return Plugin_Continue;
}
