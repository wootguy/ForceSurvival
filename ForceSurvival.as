void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

void PluginInit()
{
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "github or sven discord" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	g_Hooks.RegisterHook( Hooks::Game::MapChange, @MapChange );
}

float g_vote_cancel_expire = 0;
bool g_force_cancel_mode = false;
bool g_vote_cancelling = false;

int g_force_mode = -1;

CScheduledFunction@ g_cancel_schedule = null;

array<EHandle> g_dead_players;
array<EHandle> g_gibbed_players;

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
	}
	
	if (args[0] == ".survival") {
		string currentMode = "AUTO";
		if (g_force_mode == 0) currentMode = "OFF";
		if (g_force_mode == 1) currentMode = "ON";
	
		if (args.ArgC() > 1 && isAdmin) {
			int newMode = -1;
			string larg = args[1].ToLowercase();
			if (larg == "on" || larg == "1") newMode = 1;
			if (larg == "off" || larg == "0") newMode = 0;
		
			if (newMode == g_force_mode) {
				g_PlayerFuncs.SayText(plr, "ForceSurvival is already ON");
				return;
			}
			
			g_force_mode = newMode;
		
			if (newMode == 1) {
				if (!g_SurvivalMode.IsEnabled()) {
					g_SurvivalMode.EnableMapSupport();
					g_SurvivalMode.VoteToggle();
				}
				disable_survival_votes();
				
				g_PlayerFuncs.SayTextAll(plr, "ForceSurvival is now ON. All future maps will have survival enabled.");
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
		}
	}
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

void MapInit() {
	if (g_force_mode == 1) {
		g_SurvivalMode.EnableMapSupport();
		g_SurvivalMode.SetStartOn(true);
	} else if (g_force_mode == 0) {
		g_SurvivalMode.SetStartOn(false);
	}
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
	if (args.ArgC() > 0 and (args[0].Find(".survival") == 0 || args[0].Find(".cancelsurvival") == 0 || args[0] == ".togglesurvival"))
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

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}