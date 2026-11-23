#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define NAME "[CS:S]sm_disablescopes"
#define AUTHOR "BallGanda"
#define DESCRIPTION "sm_disablescopes of selected weapons & limit air or ground use"
#define PLUGIN_VERSION "0.0.b11"
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
// OnPlayerRunCmd exits on this one check; everything else runs only when it is set.
bool g_bHoldsRestricted[MAXPLAYERS + 1];

// While a client is blocked the plugin holds its weapon's next-secondary-attack time at least
// NSA_REFRESH seconds ahead (topping it up to NSA_HOLD), so the networked value stays ahead of the
// client's predicted clock up to that much round trip, without a resend every tick.
#define NSA_HOLD 1.0
#define NSA_REFRESH 0.6

bool g_bBlocking[MAXPLAYERS + 1];
int g_iBlockWeapon[MAXPLAYERS + 1];       // entity reference of the weapon whose timer is held
float g_fWrittenNSA[MAXPLAYERS + 1];      // the value last written, or last seen, while holding
float g_fRestoreNSA[MAXPLAYERS + 1];      // the weapon's own value, put back when the hold ends

// Cvar values mirrored by change hooks so the per-tick path never reads a ConVar.
bool g_bEnabled = true;
bool g_bBlockInAir = true;
bool g_bBlockOnGround = false;
bool g_bRestrictAwp = true;
bool g_bRestrictScout = true;
bool g_bRestrictAuto = true;
bool g_bRestrictWeak = true;

// Send-prop offsets looked up once at load, so the per-command path reads and writes by offset
// instead of hashing a property name on every call.
int g_offFlags = -1;
int g_offActiveWeapon = -1;
int g_offFOV = -1;
int g_offDefaultFOV = -1;
int g_offNextSecondaryAttack = -1;

bool g_bEntPropsCached = false;
bool g_bHasZoomLevel = false;
bool g_bHasResumeZoom = false;

public void OnPluginStart()
{
    CheckGameVersion();
    FindOffsets();

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

// Classify the client's active weapon once and store the result in the per-client flag.
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

    // A hold on a weapon that is no longer the restricted one in hand ends now, not at the next tick.
    if (g_bBlocking[client] &&
        (!g_bHoldsRestricted[client] || EntRefToEntIndex(g_iBlockWeapon[client]) != activeWeapon))
    {
        ReleaseHold(client);
    }
}

// Put back the weapon's own next-secondary-attack time, unless the game has set a new one since.
void ReleaseHold(int client)
{
    g_bBlocking[client] = false;

    int weapon = EntRefToEntIndex(g_iBlockWeapon[client]);
    if (weapon <= 0)
        return;

    if (GetEntDataFloat(weapon, g_offNextSecondaryAttack) == g_fWrittenNSA[client])
        SetEntDataFloat(weapon, g_offNextSecondaryAttack, g_fRestoreNSA[client], true);
}

// Keep the next-secondary-attack time at least NSA_REFRESH ahead; write only when it falls short.
// Returns true when the hold was already in place and the game has not touched the timer since:
// the weapon could not zoom in that window, so the caller can skip the unscope check.
bool HoldSecondaryAttack(int client, int activeWeapon)
{
    float nsa = GetEntDataFloat(activeWeapon, g_offNextSecondaryAttack);
    bool steady = g_bBlocking[client] && nsa == g_fWrittenNSA[client];

    if (!g_bBlocking[client])
    {
        g_bBlocking[client] = true;
        g_iBlockWeapon[client] = EntIndexToEntRef(activeWeapon);
        g_fRestoreNSA[client] = nsa;
    }
    else if (nsa != g_fWrittenNSA[client])
    {
        // The game set it (a shot): that is the weapon's own value now.
        g_fRestoreNSA[client] = nsa;
    }

    float now = GetGameTime();
    if (nsa < now + NSA_REFRESH)
    {
        nsa = now + NSA_HOLD;
        SetEntDataFloat(activeWeapon, g_offNextSecondaryAttack, nsa, true);
    }
    g_fWrittenNSA[client] = nsa;
    return steady;
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

bool ShouldBlockScope(int client)
{
    if ((GetEntData(client, g_offFlags) & FL_ONGROUND) != 0)
        return g_bBlockOnGround;

    return g_bBlockInAir;
}

void CacheEntPropAvailability(int client, int activeWeapon)
{
    if (g_bEntPropsCached)
        return;

    g_bHasZoomLevel = HasEntProp(activeWeapon, Prop_Send, "m_zoomLevel");
    g_bHasResumeZoom = HasEntProp(client, Prop_Send, "m_bResumeZoom");
    g_bEntPropsCached = true;
}

void ForceUnscope(int client, int activeWeapon)
{
    // m_iFOV is 0 (b8 build) or the default view (b6 build) when not scoped.
    int fov = GetEntData(client, g_offFOV);
    if (fov == 0 || fov == GetEntData(client, g_offDefaultFOV))
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
    if (!g_bHoldsRestricted[client])
        return Plugin_Continue;

    // Ground state before this command's movement; the post hook judges the state after it.
    if (ShouldBlockScope(client))
        buttons &= ~IN_ATTACK2;

    return Plugin_Continue;
}

// Movement has run: the state the command ends in decides. A jump is unscoped in the command that
// left the ground, and the hold on secondary attack starts or ends with the blocked state.
public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3],
    int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
    if (!g_bHoldsRestricted[client])
        return;

    if (!ShouldBlockScope(client))
    {
        if (g_bBlocking[client])
            ReleaseHold(client);
        return;
    }

    int activeWeapon = GetEntDataEnt2(client, g_offActiveWeapon);
    if (activeWeapon <= 0)
        return;

    if (!HoldSecondaryAttack(client, activeWeapon))
        ForceUnscope(client, activeWeapon);
}

int FindOffsetOrFail(const char[] cls, const char[] prop)
{
    int off = FindSendPropInfo(cls, prop);
    if (off <= 0)
        SetFailState("Send prop %s::%s not found", cls, prop);
    return off;
}

void FindOffsets()
{
    g_offFlags = FindOffsetOrFail("CBasePlayer", "m_fFlags");
    g_offActiveWeapon = FindOffsetOrFail("CBasePlayer", "m_hActiveWeapon");
    g_offFOV = FindOffsetOrFail("CBasePlayer", "m_iFOV");
    g_offDefaultFOV = FindOffsetOrFail("CBasePlayer", "m_iDefaultFOV");
    g_offNextSecondaryAttack = FindOffsetOrFail("CBaseCombatWeapon", "m_flNextSecondaryAttack");
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
