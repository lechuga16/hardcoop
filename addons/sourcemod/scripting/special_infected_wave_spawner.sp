#pragma semicolon 1

#define DEBUG 0
// misc constants
#define SI_HARDLIMIT 2
#define MAX_SPAWN_RANGE 750

// timer
#define KICKDELAY 0.1
#define SPAWN_ATTEMPT_INTERVAL 0.5

// functions
#define MAX(%0,%1) (((%0) > (%1)) ? (%0) : (%1))
#define TEAM_CLASS(%1) (%1 == ZC_SMOKER ? "smoker" : (%1 == ZC_BOOMER ? "boomer" : (%1 == ZC_HUNTER ? "hunter" :(%1 == ZC_SPITTER ? "spitter" : (%1 == ZC_JOCKEY ? "jockey" : (%1 == ZC_CHARGER ? "charger" : (%1 == ZC_WITCH ? "witch" : (%1 == ZC_TANK ? "tank" : "None"))))))))

#define PLUGIN_AUTHOR "Breezy"
#define PLUGIN_VERSION "1.0"

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <l4d2_direct>
#include <left4downtown>
#include <l4d2util>

/*
	Bibliography: 
	"[L4D2] SI Coop Limit Bypass" by "MI 5"
	"Zombo Manager" by "CanadaRox"	
	"Current" by "CanadaRox"
	"L4D2 Auto Infected Spawner" by "Tordecybombo, FuzzOne - miniupdate, TacKLER - miniupdate again",
*/

// Special infected classes
enum ZombieClass {
	ZC_NONE = 0, 
	ZC_SMOKER, 
	ZC_BOOMER, 
	ZC_HUNTER, 
	ZC_SPITTER, 
	ZC_JOCKEY, 
	ZC_CHARGER, 
	ZC_WITCH, 
	ZC_TANK, 
	ZC_NOTINFECTED
};

// 0=Anywhere, 1=Behind, 2=IT, 3=Specials in front, 4=Specials anywhere, 5=Far Away, 6=Above
enum SpawnDirection {
	ANYWHERE = 0,
	BEHIND,
	IT,
	SPECIALS_IN_FRONT,
	SPECIALS_ANYWHERE,
	FAR_AWAY,
	ABOVE	
};

// Vanilla cvars
new Handle:hCvarSpawnSafetyRange;
new Handle:hCvarFinaleSpawnSafetyRange;
new Handle:hCvarSpawnMaxDist;
new Handle:hCvarDirectorNoSpecials;
new Handle:hCvarDiscardRange;

// Anti-baiting
new Float:g_fSaferoomExitFlow;
new Float:g_fBaitTolerance;
new Float:g_fBaitThresholdFlow;

// Flags
new bool:g_bIsRoundActive; // left saferoom
new bool:g_bHasPassedBaitThreshold; // start spawning
new bool:g_bIsSpawnerActive; // cooldown between waves

// Interval(seconds) between waves of SI
new Handle:hCvarWaveInterval;
new Float:g_fWaveInterval;

// Custom SI limits (not the vanilla cvars)
new Handle:hCvarMaxSpecials;
new Handle:hCvarSmokerLimit;
new Handle:hCvarBoomerLimit;
new Handle:hCvarHunterLimit;
new Handle:hCvarSpitterLimit;
new Handle:hCvarJockeyLimit;
new Handle:hCvarChargerLimit;

// Tank support
new Handle:hCvarTankSupportHealthPercent; // at what percent of tank health will his support wave spawn

public Plugin:myinfo = 
{
	name = "Special Infected Wave Spawner", 
	author = PLUGIN_AUTHOR, 
	description = "Spawns SI in waves", 
	version = PLUGIN_VERSION, 
	url = ""
};

public OnPluginStart() {
	
	// Vanilla Cvars
	hCvarSpawnSafetyRange = FindConVar("z_spawn_safety_range"); // Spawn safety range
	SetConVarInt(hCvarSpawnSafetyRange, 0);
	
	hCvarFinaleSpawnSafetyRange = FindConVar("z_finale_spawn_safety_range");
	SetConVarInt(hCvarFinaleSpawnSafetyRange, 0);
	
	hCvarSpawnMaxDist = FindConVar("z_spawn_range"); // Maximum spawn range
	SetConVarInt(hCvarSpawnMaxDist, MAX_SPAWN_RANGE);
	
	// Appears to be ineffective; setting PreferredSpecialDirection through 'script' console command appears effective:
	// e.g. ScriptCommand(client, "g_ModeScript.DirectorOptions.PreferredSpecialDirection<-4") - this uses the same enumerations for the direction parameter
	// hCvarSpawnDirection = FindConVar("z_debug_spawn_set"); // 0=Anywhere, 1=Behind, 2=IT, 3=Specials in front, 4=Specials anywhere, 5=Far Away, 6=Above
	// SetConVarInt(hCvarSpawnDirection, SPECIALS_ANYWHERE); // Not sure if this cvar actually has an effect on the "z_spawn_old" command used in this plugin
	
	hCvarDirectorNoSpecials = FindConVar("director_no_specials");
	SetConVarBool(hCvarDirectorNoSpecials, true); // Disable Director spawning specials naturally
	
	hCvarDiscardRange = FindConVar("z_discard_range"); // Discard Zombies farther away than this
	SetConVarInt( hCvarDiscardRange, GetConVarInt(hCvarSpawnMaxDist) + 500 );
	
	// Wave interval
	hCvarWaveInterval = CreateConVar("siws_wave_interval", "30", "Interval in seconds between special infected waves");
	g_fWaveInterval = float(GetConVarInt(hCvarWaveInterval));
	HookConVarChange(hCvarWaveInterval, ConVarChanged:OnCvarChange);
	
	// Custom class limits
	hCvarMaxSpecials 	= CreateConVar("siws_max_specials", 	"6", "Maximum Specials alive at any time");
	HookConVarChange(hCvarMaxSpecials, ConVarChanged:OnCvarChange);
	hCvarSmokerLimit 	= CreateConVar("siws_smoker_limit", 	"1", "Maximum smokers alive at any time");
	hCvarBoomerLimit 	= CreateConVar("siws_boomer_limit", 	"1", "Maximum boomers alive at any time");
	hCvarHunterLimit 	= CreateConVar("siws_hunter_limit", 	"1", "Maximum hunters alive at any time");
	hCvarSpitterLimit	= CreateConVar("siws_spitter_limit", 	"1", "Maximum spitters alive at any time");
	hCvarJockeyLimit 	= CreateConVar("siws_jockey_limit", 	"1", "Maximum jockeys alive at any time");
	hCvarChargerLimit 	= CreateConVar("siws_charger_limit", 	"1", "Maximum chargers alive at any time");
	
	// Tank support
	hCvarTankSupportHealthPercent = CreateConVar("siws_tank_support_health_percent", "50", "SI support wave spawns upon tank health falling below this percent");
	
	// Game event hooks
	// - resetting at the end of rounds
	HookEvent("mission_lost", EventHook:OnRoundOver, EventHookMode_PostNoCopy);
	HookEvent("map_transition", EventHook:OnRoundOver, EventHookMode_PostNoCopy);
	
	#if DEBUG
		HookEvent("player_spawn", OnPlayerSpawn, EventHookMode_Pre);
	#endif
}

#if DEBUG	
public OnPlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast) {
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IsBotInfected(client)) {
		new String:infectedName[32];
		GetClientName(client, infectedName, sizeof(infectedName));
		if (StrContains(infectedName, "dummy", false) == -1) {
			PrintToChatAll("%s spawned", infectedName);
		} 
	}
}
#endif

public OnConfigsExecuted() {
	// Remove hard coded SI limit
	SetConVarBounds(FindConVar("z_minion_limit"), ConVarBound_Upper, true, float(GetConVarInt(hCvarMaxSpecials)));
	SetConVarBounds(FindConVar("z_max_player_zombies"), ConVarBound_Upper, true, float(GetConVarInt(hCvarMaxSpecials)));
}

public OnPluginEnd() {
	// Reset convars
	ResetConVar(hCvarSpawnSafetyRange);
	ResetConVar(hCvarSpawnMaxDist);
	ResetConVar(hCvarDirectorNoSpecials);
	ResetConVar(hCvarDiscardRange);
}

// Update wave interval if it is changed mid-game
public Action:OnCvarChange() {
	g_fWaveInterval = float(GetConVarInt(hCvarWaveInterval));
	SetConVarBounds(FindConVar("z_minion_limit"), ConVarBound_Upper, true, float(GetConVarInt(hCvarMaxSpecials)));
	SetConVarBounds(FindConVar("z_max_player_zombies"), ConVarBound_Upper, true, float(GetConVarInt(hCvarMaxSpecials)));
}

/***********************************************************************************************************************************************************************************

																				PER ROUND
																	
***********************************************************************************************************************************************************************************/

// Calculate bait threshold flow distance
public Action:L4D_OnFirstSurvivorLeftSafeArea(client) {
	SetSpawnDirection(SPECIALS_ANYWHERE);
	g_bIsRoundActive = true;
	
	// Get the flow of the saferoom exit held by the farthest survivor 
	new Float:flow = 0.0;
	decl Float:tmp_flow;
	decl Float:origin[3];
	decl Address:pNavArea;
	GetClientAbsOrigin(client, origin);
	pNavArea = L4D2Direct_GetTerrorNavArea(origin);
	if (pNavArea != Address_Null) {
		tmp_flow = L4D2Direct_GetTerrorNavAreaFlow(pNavArea);
		g_fSaferoomExitFlow = MAX(flow, tmp_flow);
	}
	
	// Generate a flow distance when survivors will be attacked for the first time
	g_fBaitTolerance = GetRandomFloat(100.0, 150.0);
	g_fBaitThresholdFlow = g_fSaferoomExitFlow + g_fBaitTolerance;
	
	#if DEBUG
		PrintToChatAll("Bait tolerance (flow dist): %f", g_fBaitTolerance);
	#endif
}

// Reset flags when survivors wipe or make it to the next map
public OnRoundOver() {
	g_bIsRoundActive = false;
	g_bHasPassedBaitThreshold = false;
	g_bIsSpawnerActive = false;
}

/***********************************************************************************************************************************************************************************

																			WAVE SPAWNING
																	
***********************************************************************************************************************************************************************************/

// Check every game frame whether a wave needs to be spawned
public OnGameFrame() {
	// If survivors have left saferoom
	if (g_bIsRoundActive) {
		// If survivors have progressed at least past a certain distance from saferoom
		if (g_bHasPassedBaitThreshold) {
			// If survivors are not currently between waves or in a tank fight
			if (g_bIsSpawnerActive && !IsTankInPlay()) {
				// Spawn wave and create timer counting down to next wave
				SpawnWave();
				g_bIsSpawnerActive = false;
				CreateTimer(g_fWaveInterval, Timer_ActivateSpawner, _, TIMER_FLAG_NO_MAPCHANGE); 
			}
		} else {  // Check if survivors have passed the flow threshold for spawning
			new Float:currentFlow = GetAverageSurvivorFlow();
			if (currentFlow > g_fBaitThresholdFlow) {
				g_bHasPassedBaitThreshold = true;
				g_bIsSpawnerActive = true;
			}
		}
	}
}

// Initiate spawning for each SI class
SpawnWave() {
	
	#if DEBUG
		new infectedBotCount = CountSpecialInfectedBots();
		PrintToChatAll("\x04Spawning Wave \x01(%i SI carryover)", infectedBotCount);
	#endif
	
	SpawnClassPopulation(ZC_HUNTER);
	SpawnClassPopulation(ZC_JOCKEY);
	SpawnClassPopulation(ZC_SMOKER);
	SpawnClassPopulation(ZC_CHARGER);
	SpawnClassPopulation(ZC_SPITTER);
	SpawnClassPopulation(ZC_BOOMER);
}

// Populate an SI class to its limit
SpawnClassPopulation(ZombieClass:targetClass) {
	CreateTimer(SPAWN_ATTEMPT_INTERVAL, Timer_SpawnSpecialInfected, any:targetClass, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_SpawnSpecialInfected(Handle:timer, any:targetClass) {
	if (!IsClassLimitReached(targetClass)) {
		AttemptSpawn(targetClass);
		return Plugin_Continue;
	} else {
		return Plugin_Stop;
	}
}

// Attempt to spawn a special infected of a particular class
// ('attempt' because there is the occasional "could not find a spawn position in 5 tries" error)
AttemptSpawn(ZombieClass:zombieClassNum) {
	// Create a client if necessary to circumvent the 3 SI limit
	new iSpawnedSpecialsCount = CountSpecialInfectedBots();
	
	if (iSpawnedSpecialsCount >= SI_HARDLIMIT) {
		new String:sBotName[32];
		Format(sBotName, sizeof(sBotName), "(dummy) %s", TEAM_CLASS(zombieClassNum));
		new bot = CreateFakeClient(sBotName); 
		if (bot != 0) {
			ChangeClientTeam(bot, _:L4D2Team_Infected);
			CreateTimer(KICKDELAY, KickBot, bot, TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	// Spawn with z_spawn_old using 'auto' parameter to let the Director find a spawn position
	new client = GetAnyClientInGame();
	if (client != -1) {
		new String:zombieClassName[7];
		zombieClassName = TEAM_CLASS(zombieClassNum);
		CheatCommand(client, "z_spawn_old", zombieClassName, "auto");
	}
}

// Allow spawning
public Action:Timer_ActivateSpawner(Handle:timer) {
	g_bIsSpawnerActive = true;
}

// Kick dummy bot 
public Action:KickBot(Handle:timer, any:client) {
	if (IsClientInGame(client) && (!IsClientInKickQueue(client))) {
		if (IsFakeClient(client))KickClient(client);
	}
}

/***********************************************************************************************************************************************************************************

																				TANK FIGHTS
																	
***********************************************************************************************************************************************************************************/

public OnTankSpawn(tank) {
	SDKHook(tank, SDKHook_OnTakeDamage, OnTakeDamage);
}

public OnTankDeath(tank) {
	SDKUnhook(tank, SDKHook_OnTakeDamage, OnTakeDamage);	
}

public Action:OnTakeDamage(victim, &attacker, &inflictor, &Float:damage, &damagetype) {
	
	// Calculate tank health percent
	new Float:fTankMaxHealth = float(GetEntProp(victim, Prop_Send, "m_iMaxHealth"));
	new Float:fTankCurrentHealth = float(GetEntProp(victim, Prop_Send, "m_iHealth"));
	new Float:fTankHealthPercent = 100.0 * FloatDiv(fTankCurrentHealth, fTankMaxHealth);
	
	// Check if health is below SI support wave percent
	new iTankHealthPercent = RoundToNearest(fTankHealthPercent);
	new iTankSupportHealthPercent = GetConVarInt(hCvarTankSupportHealthPercent);
	if (iTankHealthPercent < iTankSupportHealthPercent) {
		#if DEBUG
			PrintToChatAll("Spawning tank's support wave");
		#endif
		SpawnWave();
		SDKUnhook(victim, SDKHook_OnTakeDamage, OnTakeDamage); // 'victim' must be the tank
	}
	
}

/***********************************************************************************************************************************************************************************

																				UTILITY
																	
***********************************************************************************************************************************************************************************/

// @return: average flow distance covered by survivors
Float:GetAverageSurvivorFlow() {
	new survivorCount = 0;
	new Float:totalFlow = 0.0;
	decl Float:origin[3];
	decl Address:pNavArea;
	for (new client = 1; client <= MaxClients; client++) {
		if (IsClientInGame(client) && L4D2_Team:GetClientTeam(client) == L4D2Team_Survivor) {
			survivorCount++;
			GetClientAbsOrigin(client, origin);
			pNavArea = L4D2Direct_GetTerrorNavArea(origin);
			if (pNavArea != Address_Null) {
				totalFlow += L4D2Direct_GetTerrorNavAreaFlow(pNavArea);
			}
		}
	}
	return FloatDiv(totalFlow, float(survivorCount));
}

// Sets the spawn direction for SI, relative to the survivors

SetSpawnDirection(SpawnDirection:direction) {
	new client = GetAnyClientInGame();
	ScriptCommand(client, "g_ModeScript.DirectorOptions.PreferredSpecialDirection<-%i", _:direction);	
}

// Executes vscript code through the "script" console command
ScriptCommand(client, const String:arguments[], any:...) {
	// format vscript input
	new String:vscript[PLATFORM_MAX_PATH];
	VFormat(vscript, sizeof(vscript), arguments, 3);
	
	// Execute vscript input
	CheatCommand(client, "script", vscript, "");
}

// Executes, without setting sv_cheats to 1, a console command marked as a cheat
CheatCommand(client, String:command[], String:argument1[], String:argument2[]) {
	// Get user bits and command flags
	new userFlagsOriginal = GetUserFlagBits(client);
	new flagsOriginal = GetCommandFlags(command);
	
	// Set as Cheat
	SetUserFlagBits(client, ADMFLAG_ROOT);
	SetCommandFlags(command, flagsOriginal ^ FCVAR_CHEAT);
	
	// Execute command
	FakeClientCommand(client, "%s %s %s", command, argument1, argument2); 
	
	// Reset user bits and command flags
	SetCommandFlags(command, flagsOriginal);
	SetUserFlagBits(client, userFlagsOriginal);
}

// @return: entity index of any ingame client, -1 if none could be found
GetAnyClientInGame() {
	for (new target = 1; target <= MaxClients; target++) {
		if (IsClientInGame(target))return target;
	}
	return -1; // no valid client found
}

//@return: true if neither the target SI class population limit nor the number of spawned specials  have reached their limit
bool:IsClassLimitReached(ZombieClass:targetClass) {
	// Checking class limit
	new iClassLimit = GetClassLimit(targetClass);
	new iClassCount = CountSpecialInfectedClass(targetClass);
	// Checking max specials limit
	new iMaxSpecials = GetConVarInt(hCvarMaxSpecials);
	new iSpawnedSpecialsCount = CountSpecialInfectedBots();
	
	// If neither limit has been reached
	if (iClassCount < iClassLimit && iSpawnedSpecialsCount < iMaxSpecials) {
		return false;
	} else {
		return true;
	}
}

// @return: true if either the class limit or total specials limit has been reached
GetClassLimit(ZombieClass:targetClass) {
	new iClassLimit;
	switch (targetClass) {
		case ZC_SMOKER:iClassLimit = GetConVarInt(hCvarSmokerLimit);
		case ZC_BOOMER:iClassLimit = GetConVarInt(hCvarBoomerLimit);
		case ZC_HUNTER:iClassLimit = GetConVarInt(hCvarHunterLimit);
		case ZC_SPITTER:iClassLimit = GetConVarInt(hCvarSpitterLimit);
		case ZC_JOCKEY:iClassLimit = GetConVarInt(hCvarJockeyLimit);
		case ZC_CHARGER:iClassLimit = GetConVarInt(hCvarChargerLimit);
		default:iClassLimit = 0;
	}
	return iClassLimit;
}

// @return: the number of a particular special infected class alive in the game
CountSpecialInfectedClass(ZombieClass:targetClass) {
	new count = 0;
	for (new i = 1; i < MaxClients; i++) {
		if (IsBotInfected(i) && IsPlayerAlive(i)) {
			new ZombieClass:playerClass = ZombieClass:GetEntProp(i, Prop_Send, "m_zombieClass");
			if (playerClass == targetClass) {
				count++;
			}
		}
	}
	return count;
}

// @return: the total special infected bots alive in the game
CountSpecialInfectedBots() {
	new count = 0;
	for (new i = 1; i < MaxClients; i++) {
		if (IsBotInfected(i) && IsPlayerAlive(i)) {
			count++;
		}
	}
	return count;
}

// @return: true if client is a bot infected
bool:IsBotInfected(client) {
	// Check the input is valid
	if (!IsValidClient(client))return false;
	
	// Check if player is a bot on the infected team
	if (IsInfected(client) && IsFakeClient(client)) {
		return true;
	}
	return false; // otherwise
}

// @return: true if client is valid
bool:IsValidClient(client) {
	if (!(1 <= client <= MaxClients) || !IsClientInGame(client))return false;
	return true;
} 