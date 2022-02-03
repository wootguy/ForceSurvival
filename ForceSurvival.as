#include "../../maps/point_checkpoint"

string cp_save_path = "scripts/plugins/store/ForceSurvival/";

CCVar@ g_crossPluginToggle;
CCVar@ g_respawnWaveTime;

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

float g_vote_cancel_expire = 0;
bool g_force_cancel_mode = false;
bool g_vote_cancelling = false;
bool g_no_restart_mode = false;
bool g_fake_survival_detected = false;
bool g_respawning_everyone = false;
bool g_restarting_fake_survival_map = false;
int g_wait_fake_detect = 0; // wait a second to be sure fake survival is really enabled (could just be new spawns toggling)
float g_next_respawn_wave = 0;

int g_force_mode = -1;

CScheduledFunction@ g_cancel_schedule = null;

array<EHandle> g_dead_players;
array<EHandle> g_gibbed_players;

// maps_excluded doesn't work for plugins that have delayed removal
array<string> fake_survival_exclusions = {
	"fallguys",
	"shitty_pubg"
};

void PluginInit()
{
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "https://github.com/wootguy/ForceSurvival" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	g_Hooks.RegisterHook( Hooks::Game::MapChange, @MapChange );
	
	g_Scheduler.SetInterval("check_cross_plugin_toggle", 1);
	g_Scheduler.SetInterval("check_living_players", 1);
	
	@g_crossPluginToggle = CCVar("mode", -1, "Toggle survival mode from other plugins via this CVar", ConCommandFlag::AdminOnly);
	@g_respawnWaveTime = CCVar("waveTime", 2*60, "Time in seconds for wave respawns", ConCommandFlag::AdminOnly);
}

string formatTime(float t, bool statsPage=false) {
	int rounded = int(t + 0.5f);
	
	int minutes = rounded / 60;
	int seconds = rounded % 60;
	
	if (minutes > 0) {
		string ss = "" + seconds;
		if (seconds < 10) {
			ss = "0" + ss;
		}
		return "" + minutes + ":" + ss + " minutes";
	} else {
		return "" + seconds + " seconds";
	}
}

void doCommand(CBasePlayer@ plr, const CCommand@ args, bool inConsole) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if (args[0] == ".cancelsurvival" && isAdmin) {
		g_vote_cancel_expire = g_Engine.time + g_EngineFuncs.CVarGetFloat("mp_votetimecheck");
		g_force_cancel_mode = g_SurvivalMode.IsActive();
		
		disable_survival_votes();
		
		g_Scheduler.RemoveTimer(g_cancel_schedule);
		@g_cancel_schedule = g_Scheduler.SetTimeout("cancel_vote", 0.05f);
		g_vote_cancelling = true;
		
		string voteMode = g_SurvivalMode.IsEnabled() ? "disable" : "enable";
		g_PlayerFuncs.SayTextAll(plr, "" + plr.pev.netname + " is cancelling votes to " + voteMode + " survival mode");
	}
	
	if (args[0] == ".togglesurvival" && isAdmin) {
		g_SurvivalMode.EnableMapSupport();
		g_SurvivalMode.VoteToggle();
		
		g_no_restart_mode = false;
		
		if (g_SurvivalMode.IsEnabled()) {
			if (args.ArgC() > 1) {
				if (args[1] == "2") {
					setupNoRestartSurvival();
					g_PlayerFuncs.SayTextAll(plr, "[SemiSurvival] Players will respawn every " + formatTime(g_respawnWaveTime.GetInt()) + ".");
				}
			}
		}
	}
	
	if (args[0] == ".savesurvival" && isAdmin) {
		save_checkpoints(plr);
	}
	
	if (args[0] == ".deletecp" && isAdmin) {
		float bestDist = 9e99;
		CBaseEntity@ bestCp = null;
		CBaseEntity@ ent = null;
		do {
			@ent = g_EntityFuncs.FindEntityInSphere(ent, plr.pev.origin, 150, "point_checkpoint", "classname");
			if (ent !is null) {
				float dist = (ent.pev.origin - plr.pev.origin).Length();
				
				if (dist < bestDist) {
					bestDist = dist;
					@bestCp = @ent;
				}
			}
		} while (ent !is null);
		
		if (bestCp !is null) {
			g_SoundSystem.EmitSound( bestCp.edict(), CHAN_ITEM, "debris/beamstart4.wav", 1.0f, ATTN_NORM );
			g_EntityFuncs.Remove(bestCp);
		} else {
			g_PlayerFuncs.SayText(plr, "No nearby checkpoint to delete. Get closer to one.");
		}
	}
	
	if (args[0] == ".survival") {
		string currentMode = "AUTO";
		if (g_force_mode == 0) currentMode = "OFF";
		if (g_force_mode == 1) currentMode = "ON";
		if (g_force_mode == 2) currentMode = "ON (semi-survival mode)";
	
		if (args.ArgC() > 1 && isAdmin) {
			int newMode = -1;
			string larg = args[1].ToLowercase();
			if (larg == "2") newMode = 2;
			if (larg == "on" || larg == "1") newMode = 1;
			if (larg == "off" || larg == "0") newMode = 0;
		
			if (newMode == g_force_mode) {
				g_PlayerFuncs.SayText(plr, "ForceSurvival is already " + newMode);
				return;
			}
			
			g_force_mode = newMode;
			g_no_restart_mode = false;
		
			if (newMode == 1 || newMode == 2) {
				if (!g_SurvivalMode.IsEnabled()) {
					g_SurvivalMode.EnableMapSupport();
					g_SurvivalMode.VoteToggle();
				}
				disable_survival_votes();
				
				if (newMode == 2) {
					setupNoRestartSurvival();
					g_PlayerFuncs.SayTextAll(plr, "ForceSurvival is now ON (semi-survival mode). All future maps will have survival enabled.");
				} else {
					g_PlayerFuncs.SayTextAll(plr, "ForceSurvival is now ON. All future maps will have survival enabled.");
				}
			}
			else if (newMode == 0) {
				if (g_SurvivalMode.IsEnabled()) {
					g_SurvivalMode.VoteToggle();
				}
				disable_survival_votes();
			
				g_PlayerFuncs.SayTextAll(plr, "ForceSurvival is now OFF. All future maps will have survival disabled.");
			} else {
				enable_survival_votes();
				g_PlayerFuncs.SayTextAll(plr, "ForceSurvival is now AUTO. Survival will be enabled on supported maps only.");
			}
		} else {
			g_PlayerFuncs.SayText(plr, "ForceSurvival is " + currentMode);			
			
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '------------------------------ForceSurvival Commands------------------------------\n\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".survival" to show the current mode.\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".survival [mode]" to change forced mode.\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    -1 = Default (no forced mode)\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '     0 = Force OFF\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '     1 = Force ON\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '     2 = Force ON (semi-survival mode). Players respawn if everyone dies.\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".togglesurvival" to toggle survival mode for the current map.\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".togglesurvival 2" to toggle survival mode for the current map (semi-survival mode).\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".cancelsurvival" to cancel an in-progress survival vote.\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".savesurvival" save checkpoint data to the server.\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".deletecp" to delete a nearby checkpoint.\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\n--------------------------------------------------------------------------\n');
		}
	}
}

void setupNoRestartSurvival() {
	g_no_restart_mode = true;
	g_next_respawn_wave = g_Engine.time + g_respawnWaveTime.GetInt();
}

void abort_vote_cancel() {
	g_vote_cancelling = false;
	g_Scheduler.RemoveTimer(g_cancel_schedule);
	@g_cancel_schedule = null;
}

void disable_survival_votes() {
	g_EngineFuncs.ServerCommand("mp_survival_voteallow 0;\n");
	g_EngineFuncs.ServerExecute();
}

void enable_survival_votes() {
	g_EngineFuncs.ServerCommand("mp_survival_voteallow -1;\n");
	g_EngineFuncs.ServerExecute();
}

void check_cross_plugin_toggle() {
	if (g_crossPluginToggle.GetInt() != -1) {
		
		bool shouldEnable = g_crossPluginToggle.GetInt() > 0;
	
		if (shouldEnable != g_SurvivalMode.IsEnabled()) {
			g_SurvivalMode.EnableMapSupport();
			g_SurvivalMode.VoteToggle();
		}
		
		if (g_crossPluginToggle.GetInt() == 2) {
			setupNoRestartSurvival();
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[SemiSurvival] Players will respawn every " + formatTime(g_respawnWaveTime.GetInt()) + ".");
		}
		
		if (g_crossPluginToggle.GetInt() == 3) {
			g_no_restart_mode = false;
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "Semi-survival mode disabled. Players will not respawn anymore.");
		}
		
		g_crossPluginToggle.SetInt(-1);
	}
}

void updateRespawnTimer(CBasePlayer@ plr) {	
	HUDNumDisplayParams params;
	params.value = (g_next_respawn_wave - g_Engine.time) + 0.99f;
	params.x = 0;
	params.y = 0.91;
	params.color1 = RGBA_SVENCOOP;
	params.spritename = "stopwatch";
	params.channel = 15;
	params.flags = HUD_ELEM_SCR_CENTER_X | HUD_ELEM_DEFAULT_ALPHA |
		HUD_TIME_MINUTES | HUD_TIME_SECONDS | HUD_TIME_COUNT_DOWN;
	
	g_PlayerFuncs.HudTimeDisplay( plr, params );
}

void check_living_players() {	
	if (!g_SurvivalMode.IsEnabled() || !g_SurvivalMode.MapSupportEnabled()) {
		g_no_restart_mode = false;
	}
	
	int totalLiving = 0;
	int totalPlayers = 0;
	
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "player");
		if (ent !is null) {
			CBasePlayer@ plr = cast<CBasePlayer@>(ent);
			if (!plr.IsConnected()) {
				continue;
			}
			
			totalPlayers += 1;
			if (plr.IsAlive()) {
				totalLiving += 1;
				
				if (g_no_restart_mode) {
					HUDNumDisplayParams hideParams;
					hideParams.channel = 15;
					hideParams.flags = HUD_ELEM_HIDDEN;
					g_PlayerFuncs.HudTimeDisplay(plr, hideParams);
				}
			} else if (g_no_restart_mode) {
				updateRespawnTimer(plr);
			}
		}
	} while (ent !is null);
	
	if (totalPlayers == 0) {
		return;
	}
	
	if (detectFakeSurvivalMode()) {
		if (!g_fake_survival_detected) {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "Fake survival mode detected (no spawn points exist).\n");
			g_fake_survival_detected = true;
			g_EngineFuncs.ServerCommand("mp_observer_mode 1\n"); // no fun staring at your corpse
		}
	} else if (g_fake_survival_detected) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "Fake survival mode is over.\n");
		g_restarting_fake_survival_map = false;
		g_fake_survival_detected = false;
	}
	
	if (g_no_restart_mode && g_next_respawn_wave < g_Engine.time && totalLiving < totalPlayers) {
		int deadCount = totalPlayers - totalLiving;
		string ess = (deadCount == 1) ? "" : "s";
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "[SemiSurvival] Respawning " + deadCount + " dead player" + ess + ".\n");
		respawn_everyone();
		totalLiving = totalPlayers;
	}
	if (g_no_restart_mode and totalLiving == totalPlayers) {
		setupNoRestartSurvival(); // reset the timer until at least one player is dead
	}
	
	if (totalLiving > 0) {
		return;
	}
	
	if (g_no_restart_mode && !g_respawning_everyone) {
		g_respawning_everyone = true;
		g_next_respawn_wave = g_Engine.time + 4;
	}
	else if (g_fake_survival_detected && !g_restarting_fake_survival_map) {
		g_restarting_fake_survival_map = true;
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "No living players or spawn points exist. Map will restart in 10 seconds.\n");
		g_Scheduler.SetTimeout("restart_map", 10);
	}
}

bool detectFakeSurvivalMode() {
	if (g_SurvivalMode.IsEnabled() || fake_survival_exclusions.find(g_Engine.mapname) != -1) {
		g_wait_fake_detect = 0;
		return false;
	}
	
	if (areAnySpawnsEnabled()) {
		g_wait_fake_detect = 0;
	}
	
	if (!g_fake_survival_detected and g_wait_fake_detect < 2) {
		g_wait_fake_detect += 1;
		return false;
	}
	
	g_wait_fake_detect = 0;
	return true;
}

bool areAnySpawnsEnabled() {
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "info_player_*");
		if (ent !is null and isSpawnPointEnabled(ent)) {
			return true;
		}
	} while (ent !is null);
	
	return false;
}

bool isSpawnPointEnabled(CBaseEntity@ spawnPoint) {
	bool anyoneDead = false;

	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
		if (p is null or !p.IsConnected())
			continue;
		
		int oldDead = p.pev.deadflag;
		p.pev.deadflag = DEAD_DEAD;
		bool isValid = g_PlayerFuncs.IsSpawnPointValid(spawnPoint, p);
		p.pev.deadflag = oldDead;
		
		if (isValid)
			return true;
	}
	
	// can't detect if spawn point is enabled until someone is dead, so assume it works if everyone is alive
	return false;
}

void respawn_everyone() {
	g_respawning_everyone = false;
	g_PlayerFuncs.RespawnAllPlayers(false, true);
	g_next_respawn_wave = g_Engine.time + g_respawnWaveTime.GetInt();
	
	HUDNumDisplayParams hideParams;
	hideParams.channel = 15;
	hideParams.flags = HUD_ELEM_HIDDEN;
	g_PlayerFuncs.HudTimeDisplay(null, hideParams);
	
	if (!areAnySpawnsEnabled()) {	
		for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
			CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
			
			if (p is null or !p.IsConnected() or p.IsAlive())
				continue;
			
			p.EndRevive(0);
		}
	}
}

void restart_map() {
	if (!g_restarting_fake_survival_map) {
		return; // fake survival mode ended before restart
	}
	
	bool anyLiving = false;
	
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "player");
		if (ent !is null and ent.IsAlive()) {
			anyLiving = true;
		}
	} while (ent !is null);
	
	g_restarting_fake_survival_map = false;
	g_fake_survival_detected = false;
	
	if (anyLiving) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "Living players detected. Map restart aborted.\n");
		return;
	}
	
	g_EngineFuncs.ServerCommand("changelevel " + g_Engine.mapname + "\n");
}

void MapInit() {
	g_no_restart_mode = false; // don't continue this unless RTV plugin says too

	if (g_force_mode == 1 || g_force_mode == 2) {
		g_SurvivalMode.EnableMapSupport();
		g_SurvivalMode.SetStartOn(true);
		if (g_force_mode == 2) {
			setupNoRestartSurvival();
		}
	} else if (g_force_mode == 0) {
		g_SurvivalMode.SetStartOn(false);
	}
	
	// precache default checkpoint stuff
	g_Game.PrecacheModel( "models/common/lambda.mdl" );
	g_Game.PrecacheModel( "sprites/exit1.spr" );
	g_SoundSystem.PrecacheSound( "../media/valve.mp3" );
	g_SoundSystem.PrecacheSound( "debris/beamstart7.wav" );
	g_SoundSystem.PrecacheSound( "ambience/port_suckout1.wav" );		
	g_SoundSystem.PrecacheSound( "debris/beamstart4.wav" );
}

void MapActivate() {
	if (g_CustomEntityFuncs.IsCustomEntity("point_checkpoint")) {
		println("Checkpoint entity already registered");
	} else {
		println("Checkpoint not regeistereserd yet");
		RegisterPointCheckPointEntity();
	}
}

void save_checkpoints(CBasePlayer@ plr) {
	string path = cp_save_path + g_Engine.mapname + ".ini";
	File@ f = g_FileSystem.OpenFile( path, OpenFile::WRITE);
	if (f is null or !f.IsOpen())
	{
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "The folder '/svencoop/" + cp_save_path + "' does not exist! Unable to save checkpoint data.\n");
		return;
	}
	
	if( f.IsOpen() )
	{
		int numCps = 0;
		
		CBaseEntity@ ent = null;
		do {
			@ent = g_EntityFuncs.FindEntityByClassname(ent, "point_checkpoint");
			if (ent !is null) {
				numCps++;
				Vector p = ent.pev.origin;
				f.Write("" + int(p.x) + " " + int(p.y) + " " + int(p.z) + "\n");
			}
		} while (ent !is null);
	
		if (numCps > 0) {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Saved " + path + "\n");
		} else {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "No checkpoints in map. Deleting " + path + "\n");
			f.Remove();
		}
		g_PlayerFuncs.SayText(plr, "Saved " + numCps + " checkpoints\n");
		println("" + plr.pev.netname + " saved survival checkpoints");
	}
	else
		println("Failed to open file: " + path);
}

HookReturnCode MapChange() {
	abort_vote_cancel();
	return HOOK_CONTINUE;
}

CBasePlayer@ getAnyPlayer() 
{
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "player");
		if (ent !is null) {
			CBasePlayer@ plr = cast<CBasePlayer@>(ent);
			return plr;
		}
	} while (ent !is null);
	return null;
}

void cancel_vote() {
	if (!g_vote_cancelling) {
		return;
	}

	if (g_SurvivalMode.IsEnabled() != g_force_cancel_mode) {
		g_PlayerFuncs.SayTextAll(getAnyPlayer(), "jk the vote was cancelled");
		g_SurvivalMode.VoteToggle();
		
		for (uint i = 0; i < g_dead_players.size(); i++) {
			if (!g_dead_players[i].IsValid())
				continue;
			CBasePlayer@ plr = cast<CBasePlayer@>(g_dead_players[i].GetEntity());
			if (plr !is null && plr.IsConnected() && plr.IsAlive()) {
				plr.Killed(plr.pev, GIB_NEVER);
			}
		}
		
		for (uint i = 0; i < g_gibbed_players.size(); i++) {
			if (!g_gibbed_players[i].IsValid())
				continue;
			CBasePlayer@ plr = cast<CBasePlayer@>(g_gibbed_players[i].GetEntity());
			if (plr !is null && plr.IsConnected() && plr.IsAlive()) {
				plr.Killed(plr.pev, GIB_ALWAYS);
			}
		}
		
		g_dead_players.resize(0);
		g_gibbed_players.resize(0);
		g_vote_cancelling = false;
		
		return;
	}

	g_dead_players.resize(0);
	g_gibbed_players.resize(0);
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
		if (p is null or !p.IsConnected() or p.IsAlive())
			continue;
		
		if (p.IsRevivable()) {
			g_dead_players.insertLast(EHandle(p));
		} else {
			g_gibbed_players.insertLast(EHandle(p));
		}
	}

	if (g_Engine.time < g_vote_cancel_expire) {
		@g_cancel_schedule = g_Scheduler.SetTimeout("cancel_vote", 0.05f);
	} else {
		g_PlayerFuncs.SayTextAll(getAnyPlayer(), "no survival votes were cancelled");
		g_vote_cancelling = false;
	}
}

HookReturnCode ClientSay( SayParameters@ pParams ) {
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();
	if (args.ArgC() > 0 and (args[0].Find(".survival") == 0 
							|| args[0].Find(".cancelsurvival") == 0
							|| args[0] == ".togglesurvival"
							|| args[0] == ".savesurvival"
							|| args[0] == ".deletecp"))
	{
		doCommand(plr, args, false);
		pParams.ShouldHide = true;
		return HOOK_HANDLED;
	}
	return HOOK_CONTINUE;
}

CClientCommand _survival("survival", "Survival mode commands", @consoleCmd );
CClientCommand _survival2("cancelsurvival", "Survival mode commands", @consoleCmd );
CClientCommand _survival3("togglesurvival", "Survival mode commands", @consoleCmd );
CClientCommand _survival4("savesurvival", "Survival mode commands", @consoleCmd );
CClientCommand _survival5("deletecp", "Survival mode commands", @consoleCmd );

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}