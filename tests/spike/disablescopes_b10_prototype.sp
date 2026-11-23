#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define NAME "[CS:S]sm_disablescopes"
#define AUTHOR "BallGanda"
#define DESCRIPTION "sm_disablescopes of selected weapons & limit air or ground use"
#define PLUGIN_VERSION "0.0.b10"
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

// True while the client is alive, in game, and holds a restricted weapon (with the plugin enabled).
// Every hook exits on this one check; nothing runs per tick.
bool g_bHoldsRestricted[MAXPLAYERS + 1];

// While a client is blocked the plugin pushes its weapon's next-secondary-attack time far ahead, once,
// on the transition into the blocked state. It is written again only when the game sets the time
// itself (deploy, reload, fire), and put back when the blocked state ends.
#define NSA_HOLD 100000.0

bool g_bBlocking[MAXPLAYERS + 1];
int g_iBlockWeapon[MAXPLAYERS + 1];       // entity reference of the weapon whose timer is held
float g_fWrittenNSA[MAXPLAYERS + 1];      // the value last written while holding
float g_fRestoreNSA[MAXPLAYERS + 1];      // the weapon's own value, put back when the hold ends

// Cvar values mirrored by change hooks so the per-tick path never reads a ConVar.
bool g_bEnabled = true;
bool g_bBlockInAir = true;
bool g_bBlockOnGround = false;
bool g_bRestrictAwp = true;
bool g_bRestrictScout = true;
bool g_bRestrictAuto = true;
bool g_bRestrictWeak = true;

bool g_bEntPropsCached = false;
bool g_bHasZoomLevel = false;
bool g_bHasResumeZoom = false;
bool g_bHasButtonPressed = false;

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

    g_cvEnablePlugin.AddChangeHook(OnRuleCvarChanged);
    g_cvDisableScopeAwp.AddChangeHook(OnRuleCvarChanged);
    g_cvDisableScopeScout.AddChangeHook(OnRuleCvarChanged);
    g_cvDisableScopeAutoSnipers.AddChangeHook(OnRuleCvarChanged);
    g_cvDisableScopeWeakSnipers.AddChangeHook(OnRuleCvarChanged);
    g_cvDisableInAir.AddChangeHook(OnRuleCvarChanged);
    g_cvDisableOnGround.AddChangeHook(OnRuleCvarChanged);

    HookEvent("player_spawn", OnPlayerStateEvent);
    HookEvent("player_death", OnPlayerStateEvent);
    // The game sets the next-secondary-attack time itself on a shot and on a reload.
    if (!HookEventEx("weapon_fire", OnWeaponTimerEvent))
        LogError("%s weapon_fire event not found", DS_PREFIX);
    if (!HookEventEx("weapon_reload", OnWeaponTimerEvent))
        LogError("%s weapon_reload event not found", DS_PREFIX);

    ReloadRules();

    // Late load: pick up clients already connected
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            HookClient(i);
            RefreshClient(i);
        }
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

public void OnClientPutInServer(int client)
{
    g_bHoldsRestricted[client] = false;
    g_bBlocking[client] = false;
    HookClient(client);
}

public void OnClientDisconnect(int client)
{
    g_bHoldsRestricted[client] = false;
    g_bBlocking[client] = false;
}

void HookClient(int client)
{
    SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponChanged);
    SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponChanged);
    SDKHook(client, SDKHook_WeaponDropPost, OnWeaponChanged);
    SDKHook(client, SDKHook_GroundEntChangedPost, OnGroundChanged);
}

public void OnRuleCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ReloadRules();
    RefreshAllClients();
}

// Copy the cvars into plain bools; callers follow with RefreshAllClients (a cvar change invalidates every classification).
void ReloadRules()
{
    g_bEnabled = g_cvEnablePlugin.BoolValue;
    g_bBlockInAir = g_cvDisableInAir.BoolValue;
    g_bBlockOnGround = g_cvDisableOnGround.BoolValue;
    g_bRestrictAwp = g_cvDisableScopeAwp.BoolValue;
    g_bRestrictScout = g_cvDisableScopeScout.BoolValue;
    g_bRestrictAuto = g_cvDisableScopeAutoSnipers.BoolValue;
    g_bRestrictWeak = g_cvDisableScopeWeakSnipers.BoolValue;
}

void RefreshAllClients()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        RefreshClient(i);
    }
}

public void OnPlayerStateEvent(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0)
    {
        RefreshClient(client);
        // The active weapon is settled a frame after spawn or death.
        RequestFrame(OnRefreshFrame, GetClientUserId(client));
    }
}

public void OnWeaponChanged(int client, int weapon)
{
    RefreshClient(client);
    // On a drop the active weapon is not updated yet; look again next frame.
    RequestFrame(OnRefreshFrame, GetClientUserId(client));
}

public void OnRefreshFrame(int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0)
    {
        RefreshClient(client);
    }
}

public void OnWeaponTimerEvent(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !g_bBlocking[client])
        return;

    // A reload has set the time by now; a shot sets it after its event, so look again next frame.
    RefreshClient(client);
    RequestFrame(OnRefreshFrame, GetClientUserId(client));
}

// Called from inside the movement code, while the ground entity changes. The ground flag still holds
// the state the client is leaving; the new state is read from it where that is unambiguous, and the
// next frame settles the rest (a ledge fall, or a step from one ground entity to another).
public void OnGroundChanged(int client)
{
    if (!g_bHoldsRestricted[client])
        return;

    int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (activeWeapon <= 0)
        return;

    if ((GetEntityFlags(client) & FL_ONGROUND) == 0)
    {
        Enforce(client, activeWeapon, true);              // landing
    }
    else if (GetEntPropEnt(client, Prop_Data, "m_hGroundEntity") == -1 || JumpPressed(client, activeWeapon))
    {
        Enforce(client, activeWeapon, false);             // leaving the ground: unscoped in this command
    }

    RequestFrame(OnRefreshFrame, GetClientUserId(client));
}

bool JumpPressed(int client, int activeWeapon)
{
    if (!g_bEntPropsCached)
        CacheEntPropAvailability(client, activeWeapon);

    if (g_bHasButtonPressed)
        return (GetEntProp(client, Prop_Data, "m_afButtonPressed") & IN_JUMP) != 0;

    return (GetClientButtons(client) & IN_JUMP) != 0;
}

// Classify the client's active weapon once, store the result in the per-client flag, and apply the
// rule for the state the client is in now.
void RefreshClient(int client)
{
    g_bHoldsRestricted[client] = false;

    int activeWeapon = -1;
    if (g_bEnabled && IsClientInGame(client) && IsPlayerAlive(client))
    {
        activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        if (activeWeapon > 0 && IsValidEntity(activeWeapon))
            g_bHoldsRestricted[client] = IsNoScopeWeapon(activeWeapon);
    }

    // A hold on a weapon that is no longer the restricted one in hand ends now.
    if (g_bBlocking[client] &&
        (!g_bHoldsRestricted[client] || EntRefToEntIndex(g_iBlockWeapon[client]) != activeWeapon))
    {
        ReleaseHold(client);
    }

    if (g_bHoldsRestricted[client])
        Enforce(client, activeWeapon, (GetEntityFlags(client) & FL_ONGROUND) != 0);
}

// Start, keep or end the hold for the given ground state.
void Enforce(int client, int activeWeapon, bool onGround)
{
    if (!(onGround ? g_bBlockOnGround : g_bBlockInAir))
    {
        if (g_bBlocking[client])
            ReleaseHold(client);
        return;
    }

    HoldSecondaryAttack(client, activeWeapon);
    ForceUnscope(client, activeWeapon);
}

// Put back the weapon's own next-secondary-attack time, unless the game has set a new one since.
void ReleaseHold(int client)
{
    g_bBlocking[client] = false;

    int weapon = EntRefToEntIndex(g_iBlockWeapon[client]);
    if (weapon <= 0)
        return;

    if (GetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack") == g_fWrittenNSA[client])
        SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", g_fRestoreNSA[client]);
}

// Push the next-secondary-attack time far ahead; write again only when the game has set it since.
void HoldSecondaryAttack(int client, int activeWeapon)
{
    float nsa = GetEntPropFloat(activeWeapon, Prop_Send, "m_flNextSecondaryAttack");

    if (!g_bBlocking[client])
    {
        g_bBlocking[client] = true;
        g_iBlockWeapon[client] = EntIndexToEntRef(activeWeapon);
    }
    else if (nsa == g_fWrittenNSA[client])
    {
        return;
    }

    // The weapon's own value (on entry, or set by the game since): put back when the hold ends.
    g_fRestoreNSA[client] = nsa;
    g_fWrittenNSA[client] = GetGameTime() + NSA_HOLD;
    SetEntPropFloat(activeWeapon, Prop_Send, "m_flNextSecondaryAttack", g_fWrittenNSA[client]);
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

    // The change hooks already refreshed on each change; this is a safety net.
    ReloadRules();
    RefreshAllClients();

    PrintToServer("%sInstance config loaded", DS_PREFIX);
}

bool IsNoScopeWeapon(int entityNumber)
{
    char checkClassname[MAX_NAME_LENGTH];
    GetEdictClassname(entityNumber, checkClassname, sizeof(checkClassname));

    if (g_bRestrictAwp && StrEqual(checkClassname, "weapon_awp"))
        return true;

    if (g_bRestrictScout && StrEqual(checkClassname, "weapon_scout"))
        return true;

    if (g_bRestrictAuto &&
        (StrEqual(checkClassname, "weapon_g3sg1") || StrEqual(checkClassname, "weapon_sg550")))
        return true;

    if (g_bRestrictWeak &&
        (StrEqual(checkClassname, "weapon_sg552") || StrEqual(checkClassname, "weapon_aug")))
        return true;

    return false;
}

void CacheEntPropAvailability(int client, int activeWeapon)
{
    if (g_bEntPropsCached)
        return;

    g_bHasZoomLevel = HasEntProp(activeWeapon, Prop_Send, "m_zoomLevel");
    g_bHasResumeZoom = HasEntProp(client, Prop_Send, "m_bResumeZoom");
    g_bHasButtonPressed = HasEntProp(client, Prop_Data, "m_afButtonPressed");
    g_bEntPropsCached = true;
}

void ForceUnscope(int client, int activeWeapon)
{
    // m_iFOV is 0 (b8 build) or the default view (b6 build) when not scoped.
    int fov = GetEntProp(client, Prop_Send, "m_iFOV");
    if (fov == 0 || fov == GetEntProp(client, Prop_Send, "m_iDefaultFOV"))
        return;

    CacheEntPropAvailability(client, activeWeapon);

    SetEntProp(client, Prop_Send, "m_iFOV", 0);

    if (g_bHasZoomLevel)
    {
        SetEntProp(activeWeapon, Prop_Send, "m_zoomLevel", 0);
    }

    if (g_bHasResumeZoom)
    {
        SetEntProp(client, Prop_Send, "m_bResumeZoom", 0);
    }
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
