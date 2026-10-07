/**
 * AMXX Bot Takeover  —  CS:GO-style "take over a bot" for Counter-Strike 1.6
 * ---------------------------------------------------------------------
 * When a player dies, after a short death-cam delay they are shown a hint to
 * press a key. On the keypress the plugin snapshots a live teammate bot,
 * kicks it, and force-respawns the dead player into the bot's position with its
 * health / armor / weapons.
 *
 * Modules: amxmodx, fakemeta, hamsandwich, cstrike, fun
 * Bot detection is generic (is_user_bot) — works with any fake-client bot,
 * with no dependency on a specific bot framework.
 */

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <hamsandwich>
#include <cstrike>
#include <fun>

#pragma semicolon 1

#define PLUGIN_NAME    "AMXX Bot Takeover"
#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_AUTHOR  "hlstatsnext.com"

#define MAX_PLAYERS 32
#define MAX_WEAPONS 32

// Per-player takeover state machine.
enum {
    STATE_NONE = 0,
    STATE_DEATHCAM,     // waiting out the death-cam delay
    STATE_OFFER,        // hint shown, waiting for the keypress
    STATE_SWAPPING      // swap scheduled / in progress
}

// Task id bases (player index is added; index <= 32, so the ranges never overlap).
#define TASKID_DEATHCAM 1000
#define TASKID_HINT     2000
#define TASKID_APPLY    3000
#define TASKID_FIXUP    4000
#define TASKID_STRIP    5000
#define TASKID_UNFREEZE 6000

#define DEBOUNCE_TIME 0.15

// Movement-lock flag (engine constant); guard in case an include already has it.
#if !defined FL_FROZEN
    #define FL_FROZEN (1<<16)
#endif

// "Don't render this entity" effect flag; used to hide the silent-killed bot's
// dead body so no corpse is visible where the player lands. Guard like above.
#if !defined EF_NODRAW
    #define EF_NODRAW (1<<7)
#endif

// --- cvar pointers --------------------------------------------------------
new g_pEnabled, g_pDelay, g_pKey, g_pRepeat, g_pSelect;
new g_pAdoptName, g_pAdoptModel, g_pHealthMode;
new g_pHintRepeat, g_pMinBots, g_pStripOnSurvive, g_pDebug;
new g_pBotMode, g_pFreeze;

// --- global state ---------------------------------------------------------
new bool:g_bRoundActive;
new bool:g_bWarmup;
new g_iKeyBit;
new g_hudSync;
new g_iSilenceBot;   // entity whose sounds are suppressed during a silent-kill (0 = none)

// --- per-player state -----------------------------------------------------
new g_iState[MAX_PLAYERS + 1];
new g_iChosenBot[MAX_PLAYERS + 1];           // reserved for future use
new Float:g_fOfferAt[MAX_PLAYERS + 1];
new g_iTakeoverCount[MAX_PLAYERS + 1];
new bool:g_bKeyDown[MAX_PLAYERS + 1];
new g_iDbgLastButtons[MAX_PLAYERS + 1];      // debug: last logged button bitmask while offering
new Float:g_fDeathOrigin[MAX_PLAYERS + 1][3];
new bool:g_bBotConsumed[MAX_PLAYERS + 1];    // indexed by bot entity index
new bool:g_bTookOver[MAX_PLAYERS + 1];       // took over a bot this round (for end-of-round gear reset)

// --- bot snapshot (transient, one slot per swapping player) ---------------
new Float:g_snapOrigin[MAX_PLAYERS + 1][3];
new Float:g_snapAngles[MAX_PLAYERS + 1][3];
new Float:g_snapVelocity[MAX_PLAYERS + 1][3];
new bool:g_snapDucking[MAX_PLAYERS + 1];     // bot was crouched — replay the stance so the player isn't buried in the floor
new g_snapHealth[MAX_PLAYERS + 1];
new g_snapArmor[MAX_PLAYERS + 1];
new g_snapArmorType[MAX_PLAYERS + 1];
new g_savedMoney[MAX_PLAYERS + 1];           // the player's OWN money, preserved across the takeover respawn
new g_snapWeapons[MAX_PLAYERS + 1][MAX_WEAPONS];
new g_snapClip[MAX_PLAYERS + 1][MAX_WEAPONS];
new g_snapBpAmmo[MAX_PLAYERS + 1][MAX_WEAPONS];
new g_snapNumWeapons[MAX_PLAYERS + 1];
new g_snapActive[MAX_PLAYERS + 1];
new g_snapName[MAX_PLAYERS + 1][32];
new g_snapModel[MAX_PLAYERS + 1][32];

// CSW id -> weapon entity classname (index 0 and 2 are unused slots).
new const g_szWeaponNames[][] = {
    "",                     //  0
    "weapon_p228",          //  1  CSW_P228
    "",                     //  2
    "weapon_scout",         //  3  CSW_SCOUT
    "weapon_hegrenade",     //  4  CSW_HEGRENADE
    "weapon_xm1014",        //  5  CSW_XM1014
    "weapon_c4",            //  6  CSW_C4
    "weapon_mac10",         //  7  CSW_MAC10
    "weapon_aug",           //  8  CSW_AUG
    "weapon_smokegrenade",  //  9  CSW_SMOKEGRENADE
    "weapon_elite",         // 10  CSW_ELITE
    "weapon_fiveseven",     // 11  CSW_FIVESEVEN
    "weapon_ump45",         // 12  CSW_UMP45
    "weapon_sg550",         // 13  CSW_SG550
    "weapon_galil",         // 14  CSW_GALIL
    "weapon_famas",         // 15  CSW_FAMAS
    "weapon_usp",           // 16  CSW_USP
    "weapon_glock18",       // 17  CSW_GLOCK18
    "weapon_awp",           // 18  CSW_AWP
    "weapon_mp5navy",       // 19  CSW_MP5NAVY
    "weapon_m249",          // 20  CSW_M249
    "weapon_m3",            // 21  CSW_M3
    "weapon_m4a1",          // 22  CSW_M4A1
    "weapon_tmp",           // 23  CSW_TMP
    "weapon_g3sg1",         // 24  CSW_G3SG1
    "weapon_flashbang",     // 25  CSW_FLASHBANG
    "weapon_deagle",        // 26  CSW_DEAGLE
    "weapon_sg552",         // 27  CSW_SG552
    "weapon_ak47",          // 28  CSW_AK47
    "weapon_knife",         // 29  CSW_KNIFE
    "weapon_p90"            // 30  CSW_P90
};

// Whether a CSW id has a clip (false for grenades, c4, knife and unused slots).
new const bool:g_bWeaponHasClip[] = {
    false, true,  false, true,  false, true,  false, true,  true,  false,
    true,  true,  true,  true,  true,  true,  true,  true,  true,  true,
    true,  true,  true,  true,  true,  false, true,  true,  true,  false,
    true
};

// =========================================================================
//  Lifecycle
// =========================================================================
public plugin_init() {
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
    register_dictionary("takeover.txt");

    g_pEnabled     = create_cvar("takeover_enabled", "1", _, "Enable the bot takeover feature");
    g_pDelay       = create_cvar("takeover_delay", "3.0", _, "Death-cam seconds before the takeover hint appears and the key is accepted");
    g_pKey         = create_cvar("takeover_key", "reload", _, "Confirm key: attack, attack2, jump, duck, use, reload");
    g_pRepeat      = create_cvar("takeover_repeat", "1", _, "1=every death while bots remain, 0=once per round, N=cap per round");
    g_pSelect      = create_cvar("takeover_select", "1", _, "Bot pick: 0 random, 1 nearest-to-death, 2 lowest-HP, 3 highest-HP");
    g_pAdoptName   = create_cvar("takeover_adopt_name", "0", _, "1=rename player to the bot's name");
    g_pAdoptModel  = create_cvar("takeover_adopt_model", "1", _, "1=copy the bot's player model");
    g_pHealthMode  = create_cvar("takeover_health_mode", "0", _, "0=copy bot HP/armor, 1=full, 2=copy capped at 100");
    g_pHintRepeat  = create_cvar("takeover_hint_repeat", "1.0", _, "Re-send the hint every N seconds while the offer is open (0=once)");
    g_pMinBots     = create_cvar("takeover_min_bots", "0", _, "Do not offer if it would drop alive team bots to <= this");
    g_pStripOnSurvive = create_cvar("takeover_strip_on_survive", "1", _, "1=if a player survives the round in a taken-over body, reset them to a default loadout next round (you still died, economically)");
    g_pDebug       = create_cvar("takeover_debug", "0", _, "1=log takeover diagnostics to server console + the dead player's chat (for troubleshooting key capture)");
    g_pBotMode     = create_cvar("takeover_bot_mode", "0", _, "Taken-over bot: 0=silent kill (no kill-feed/corpse/death scored, stays on team, respawns next round), 1=kick (remove from server)");
    g_pFreeze      = create_cvar("takeover_freeze", "0.75", _, "Seconds to freeze the player in place right after taking over a body (0=disabled)");

    hook_cvar_change(g_pKey, "OnKeyCvarChanged");

    RegisterHam(Ham_Killed, "player", "fwHamKilled", 1);
    // Two independent reads of the dead player's input: CmdStart sees the raw
    // usercmd buttons, PlayerPreThink sees pev_button. Whichever the engine
    // populates for an observer, the keypress is caught. The state latch in
    // tryTakeover() makes the redundant path a harmless no-op.
    register_forward(FM_CmdStart, "fwCmdStart");
    register_forward(FM_PlayerPreThink, "fwPreThink");
    // Lets us mute the death/drop sounds of a bot during its silent-kill so the
    // takeover is truly silent (see fwEmitSound + taskDoTakeover). Cheap: the
    // handler early-returns on every sound unless a silent-kill is in progress.
    register_forward(FM_EmitSound, "fwEmitSound");

    register_event("HLTV", "fwNewRound", "a", "1=0", "2=0");
    register_logevent("fwRoundStart", 2, "1=Round_Start");
    register_logevent("fwRoundEnd", 2, "1=Round_End");

    register_concmd("takeover_force", "cmdForce", ADMIN_RCON, "Force the calling (dead) player to take over a bot now");

    g_hudSync = CreateHudSyncObj();
    g_bRoundActive = true;
    g_bWarmup = false;
}

public plugin_cfg() {
    new cfgDir[96];
    get_configsdir(cfgDir, charsmax(cfgDir));
    server_cmd("exec %s/takeover.cfg", cfgDir);

    resolveKeyBit();
}

public client_disconnected(id) {
    clearPlayer(id);
}

// =========================================================================
//  Cvar handling
// =========================================================================
public OnKeyCvarChanged(pcvar, const oldValue[], const newValue[]) {
    g_iKeyBit = keyNameToBit(newValue);
    debugMsg(0, "key cvar changed '%s' -> '%s' (bit=%d)", oldValue, newValue, g_iKeyBit);
}

resolveKeyBit() {
    new key[16];
    get_pcvar_string(g_pKey, key, charsmax(key));
    g_iKeyBit = keyNameToBit(key);
}

keyNameToBit(const name[]) {
    if (equali(name, "attack"))  return IN_ATTACK;
    if (equali(name, "attack2")) return IN_ATTACK2;
    if (equali(name, "jump"))    return IN_JUMP;
    if (equali(name, "duck"))    return IN_DUCK;
    if (equali(name, "use"))     return IN_USE;
    if (equali(name, "reload"))  return IN_RELOAD;
    return IN_USE;
}

// Map the logical key name to the physical key most players have it bound to,
// so the hint reads "Press [E]" instead of the cryptic "Press [use]". Falls
// back to the raw name for anything unrecognized.
keyDisplayName(const name[], out[], len) {
    if (equali(name, "attack"))  { copy(out, len, "MOUSE1"); return; }
    if (equali(name, "attack2")) { copy(out, len, "MOUSE2"); return; }
    if (equali(name, "jump"))    { copy(out, len, "SPACE");  return; }
    if (equali(name, "duck"))    { copy(out, len, "CTRL");   return; }
    if (equali(name, "use"))     { copy(out, len, "E");      return; }
    if (equali(name, "reload"))  { copy(out, len, "R");      return; }
    copy(out, len, name);
}

// Diagnostics sink. Off unless takeover_debug is set. Echoes to the server
// console (log_amx) and, when id is a real player, to that player's chat so a
// tester can read the trace on their own screen. Pass id 0 for non-player logs.
debugMsg(id, const fmt[], any:...) {
    if (!get_pcvar_num(g_pDebug))
        return;

    new msg[192];
    vformat(msg, charsmax(msg), fmt, 3);

    log_amx("[takeover] (id %d) %s", id, msg);
    if (id >= 1 && id <= MAX_PLAYERS && is_user_connected(id))
        client_print(id, print_chat, "[takeover] %s", msg);
}

// =========================================================================
//  Round events
// =========================================================================
public fwNewRound() {
    g_bRoundActive = true;
    g_bWarmup = false;

    new bool:strip = get_pcvar_num(g_pStripOnSurvive) != 0;

    for (new i = 1; i <= MAX_PLAYERS; i++) {
        // A player who took over a bot still "died" this round — for next round's
        // economy, reset them to a default loadout so the borrowed kit does not
        // carry over. Deferred a beat so it runs after the engine's round-start
        // equip pass; harmless for takeover-then-died players (already default).
        if (strip && g_bTookOver[i] && is_user_connected(i)) {
            remove_task(TASKID_STRIP + i);
            set_task(0.2, "taskStripGear", TASKID_STRIP + i);
        }

        clearPlayer(i);
        g_iTakeoverCount[i] = 0;
        g_bBotConsumed[i] = false;
        g_bTookOver[i] = false;
    }
}

public fwRoundStart() {
    g_bRoundActive = true;
    g_bWarmup = false;
}

public fwRoundEnd() {
    g_bRoundActive = false;

    for (new i = 1; i <= MAX_PLAYERS; i++) {
        if (g_iState[i] == STATE_DEATHCAM || g_iState[i] == STATE_OFFER) {
            debugMsg(i, "offer CLOSED: round ended");
            clearPlayer(i);
        }
    }
}

// =========================================================================
//  Death -> offer flow
// =========================================================================
public fwHamKilled(victim, attacker, shouldgib) {
    if (!get_pcvar_num(g_pEnabled))
        return HAM_IGNORED;

    if (victim < 1 || victim > MAX_PLAYERS || !is_user_connected(victim))
        return HAM_IGNORED;

    if (is_user_bot(victim) || !g_bRoundActive || g_bWarmup)
        return HAM_IGNORED;

    new CsTeams:team = cs_get_user_team(victim);
    if (team != CS_TEAM_T && team != CS_TEAM_CT)
        return HAM_IGNORED;

    if (!canTakeoverAgain(victim))
        return HAM_IGNORED;

    pev(victim, pev_origin, g_fDeathOrigin[victim]);

    g_iState[victim] = STATE_DEATHCAM;
    remove_task(TASKID_DEATHCAM + victim);
    set_task(get_pcvar_float(g_pDelay), "taskStartOffer", TASKID_DEATHCAM + victim);

    return HAM_IGNORED;
}

bool:canTakeoverAgain(id) {
    new repeat = get_pcvar_num(g_pRepeat);
    if (repeat <= 0)
        return (g_iTakeoverCount[id] < 1);
    if (repeat == 1)
        return true;
    return (g_iTakeoverCount[id] < repeat);
}

public taskStartOffer(taskid) {
    new id = taskid - TASKID_DEATHCAM;

    if (!is_user_connected(id) || is_user_alive(id) || !g_bRoundActive || g_bWarmup) {
        clearPlayer(id);
        return;
    }
    if (g_iState[id] != STATE_DEATHCAM)
        return;

    new CsTeams:team = cs_get_user_team(id);
    if (countAliveTeamBots(team) <= get_pcvar_num(g_pMinBots)) {
        g_iState[id] = STATE_NONE;
        client_print(id, print_center, "%L", id, "TAKEOVER_NO_BOTS");
        return;
    }

    g_iState[id] = STATE_OFFER;
    g_fOfferAt[id] = get_gametime();
    g_bKeyDown[id] = false;
    g_iDbgLastButtons[id] = -1;
    showHint(id);

    debugMsg(id, "offer OPEN (key bit=%d, bots=%d) — press your key now",
             g_iKeyBit, countAliveTeamBots(team));

    new Float:rep = get_pcvar_float(g_pHintRepeat);
    if (rep > 0.0) {
        remove_task(TASKID_HINT + id);
        set_task(rep, "taskHint", TASKID_HINT + id, _, _, "b");
    }
}

public taskHint(taskid) {
    new id = taskid - TASKID_HINT;

    if (!is_user_connected(id) || is_user_alive(id) || g_iState[id] != STATE_OFFER) {
        debugMsg(id, "offer CLOSED by hint task (connected=%d alive=%d state=%d)",
                 is_user_connected(id), is_user_alive(id), g_iState[id]);
        clearPlayer(id);
        return;
    }

    new CsTeams:team = cs_get_user_team(id);
    if (countAliveTeamBots(team) <= get_pcvar_num(g_pMinBots)) {
        debugMsg(id, "offer CLOSED by hint task: no teammate bots alive");
        clearPlayer(id);
        client_print(id, print_center, "%L", id, "TAKEOVER_NO_BOTS");
        return;
    }

    showHint(id);
}

showHint(id) {
    new keyName[16];
    get_pcvar_string(g_pKey, keyName, charsmax(keyName));

    new keyLabel[16];
    keyDisplayName(keyName, keyLabel, charsmax(keyLabel));

    new msg[192];
    formatex(msg, charsmax(msg), "%L", id, "TAKEOVER_HINT", keyLabel);

    set_hudmessage(0, 200, 120, -1.0, 0.80, 0, 0.0, 3.0, 0.1, 0.3, -1);
    ShowSyncHudMsg(id, g_hudSync, "%s", msg);
}

// =========================================================================
//  Keypress capture (dead players are observers — the engine still runs
//  their usercmds, so the buttons are readable every frame). We read them two
//  ways for robustness: the usercmd handle in CmdStart and pev_button in
//  PlayerPreThink. Whichever the engine populates for an observer wins; the
//  state latch in tryTakeover() keeps the second one from double-firing.
// =========================================================================
public fwCmdStart(id, uc_handle, seed) {
    if (id < 1 || id > MAX_PLAYERS || g_iState[id] != STATE_OFFER)
        return FMRES_IGNORED;

    new ucButtons  = get_uc(uc_handle, UC_Buttons);
    new pevButtons = pev(id, pev_button);
    new buttons    = ucButtons | pevButtons;

    // Diagnostics: log whenever the combined bitmask changes, so we can see
    // whether the press reaches the server at all and which read sees it.
    if (buttons != g_iDbgLastButtons[id]) {
        g_iDbgLastButtons[id] = buttons;
        debugMsg(id, "cmdstart uc=%d pev=%d keybit=%d match=%d",
                 ucButtons, pevButtons, g_iKeyBit, (buttons & g_iKeyBit) ? 1 : 0);
    }

    checkTakeoverKey(id, buttons, "cmdstart");
    return FMRES_IGNORED;
}

public fwPreThink(id) {
    if (id < 1 || id > MAX_PLAYERS || g_iState[id] != STATE_OFFER)
        return FMRES_IGNORED;

    checkTakeoverKey(id, pev(id, pev_button), "prethink");
    return FMRES_IGNORED;
}

// Mute the death/weapon-drop sounds of the bot being silently killed. Active
// only for the single synchronous user_silentkill() call (g_iSilenceBot is set
// around it and cleared immediately after), so every other sound passes through.
public fwEmitSound(entity, channel, const sample[], Float:volume, Float:attenuation, flags, pitch) {
    if (g_iSilenceBot && entity == g_iSilenceBot)
        return FMRES_SUPERCEDE;
    return FMRES_IGNORED;
}

// Rising-edge detection of the configured key. Shared by both input forwards;
// callers pass the button bitmask they read and a label for diagnostics.
checkTakeoverKey(id, buttons, const src[]) {
    if (g_iState[id] != STATE_OFFER)
        return;

    new bool:down = (buttons & g_iKeyBit) != 0;

    if (down && !g_bKeyDown[id]) {
        g_bKeyDown[id] = true;
        if (get_gametime() - g_fOfferAt[id] >= DEBOUNCE_TIME) {
            debugMsg(id, "key DETECTED via %s (buttons=%d) -> takeover", src, buttons);
            tryTakeover(id);
        }
    } else if (!down) {
        g_bKeyDown[id] = false;
    }
}

tryTakeover(id) {
    if (g_iState[id] != STATE_OFFER)
        return;

    g_iState[id] = STATE_SWAPPING;
    remove_task(TASKID_HINT + id);
    remove_task(TASKID_APPLY + id);
    // Defer one beat so the swap runs cleanly after this frame's input pass.
    set_task(0.1, "taskDoTakeover", TASKID_APPLY + id);
}

// =========================================================================
//  The takeover
// =========================================================================
public taskDoTakeover(taskid) {
    new id = taskid - TASKID_APPLY;

    if (!isTakeoverValid(id)) {
        debugMsg(id, "takeover ABORTED: not valid (enabled/round/warmup/connected/alive/team)");
        g_iState[id] = STATE_NONE;
        return;
    }

    new CsTeams:team = cs_get_user_team(id);
    new bot = selectBot(team, g_fDeathOrigin[id]);
    if (bot == 0) {
        debugMsg(id, "takeover ABORTED: selectBot found no teammate bot");
        g_iState[id] = STATE_NONE;
        client_print(id, print_center, "%L", id, "TAKEOVER_NO_BOTS");
        return;
    }

    debugMsg(id, "takeover proceeding: bot=%d", bot);

    g_bBotConsumed[bot] = true;

    // 1. Snapshot the bot (read-only — must happen before it is removed).
    snapshotBot(id, bot);

    // 2. Preserve the player's OWN money across the respawn — they keep their
    //    economy; only the bot's body/weapons are adopted, not its cash.
    g_savedMoney[id] = cs_get_user_money(id);

    // 3. Respawn the (dead) player FIRST, while the bot is still alive. Removing
    //    the bot before the player materializes would leave the team with zero
    //    alive members at that instant — and CS ends the round the moment a team
    //    is emptied. Spawning the player first keeps the team's alive count >= 1
    //    throughout, so even taking over the team's LAST bot never ends the
    //    round. Clear observer state first.
    set_pev(id, pev_iuser1, 0);
    set_pev(id, pev_iuser2, 0);
    set_pev(id, pev_iuser3, 0);
    ExecuteHamB(Ham_CS_RoundRespawn, id);

    // 4. Remove the bot from the round (now safe — the player is alive on the
    //    team). Slay (default) leaves it on the team so it takes a death this
    //    round and respawns next round — its score is kept instead of being
    //    churned into a fresh 0-score replacement. Kick removes it from the
    //    server entirely (legacy behavior).
    if (get_pcvar_num(g_pBotMode) == 1) {
        new userid = get_user_userid(bot);
        // The kick is queued to end-of-frame, so the live bot is still solid when
        // we teleport the player onto its spot in step 5. Make it non-solid now to
        // avoid that one-frame overlap. (Silent kill already does this via Killed.)
        set_pev(bot, pev_solid, SOLID_NOT);
        server_cmd("kick #%d", userid);   // queued, runs at end of frame
    } else {
        // Silent kill, made truly silent: strip the bot's weapons first so the
        // death doesn't drop a weapon box where the player lands; mute its death
        // sounds for the duration of the kill (fwEmitSound); then hide the dead
        // body with EF_NODRAW so there is no corpse / death animation on screen.
        // No kill-feed line, no death scored — the bot keeps its scoreboard and
        // respawns next round (Spawn() clears EF_NODRAW for us).
        strip_user_weapons(bot);
        g_iSilenceBot = bot;
        user_silentkill(bot);
        g_iSilenceBot = 0;
        // Killed() already set the dead body SOLID_NOT; assert it so the player
        // can never collide with the corpse when teleporting onto the spot.
        set_pev(bot, pev_solid, SOLID_NOT);
        set_pev(bot, pev_effects, pev(bot, pev_effects) | EF_NODRAW);
    }

    // 5. Apply the snapshot onto the now-alive player.
    applySnapshot(id);

    // 6. Briefly freeze the new body so the player can orient before moving —
    //    stops them acting on the instant-respawn frame (anti-abuse / anti-stuck).
    new Float:freeze = get_pcvar_float(g_pFreeze);
    if (freeze > 0.0) {
        set_pev(id, pev_flags, pev(id, pev_flags) | FL_FROZEN);
        remove_task(TASKID_UNFREEZE + id);
        set_task(freeze, "taskUnfreeze", TASKID_UNFREEZE + id);
    }

    // 7. Re-assert HUD-sensitive state shortly after (first-respawn HUD quirk).
    remove_task(TASKID_FIXUP + id);
    set_task(0.1, "taskFixupSpawn", TASKID_FIXUP + id);

    // 8. Done.
    g_iState[id] = STATE_NONE;
    g_iTakeoverCount[id]++;
    g_bTookOver[id] = true;
    g_bKeyDown[id] = false;
    client_print(id, print_chat, "%L", id, "TAKEOVER_DONE", g_snapName[id]);
}

bool:isTakeoverValid(id) {
    if (!get_pcvar_num(g_pEnabled) || !g_bRoundActive || g_bWarmup)
        return false;
    if (!is_user_connected(id) || is_user_alive(id))
        return false;

    new CsTeams:team = cs_get_user_team(id);
    return (team == CS_TEAM_T || team == CS_TEAM_CT);
}

// cs_get_user_bpammo / cs_set_user_bpammo raise a native error for weapons that
// have no ammo type at all — the knife and the C4. Everything else (including
// grenades, whose bpammo is the count carried) is safe.
bool:weaponHasBpAmmo(csw) {
    return (csw >= 1 && csw <= CSW_P90 && csw != CSW_KNIFE && csw != CSW_C4);
}

snapshotBot(id, bot) {
    pev(bot, pev_origin,   g_snapOrigin[id]);
    pev(bot, pev_angles,   g_snapAngles[id]);
    pev(bot, pev_velocity, g_snapVelocity[id]);

    // A crouching bot's origin sits ~18u below a standing one (it's centered on
    // the shorter duck hull, with the feet on the floor). Record the stance so
    // applySnapshot can place the player with the matching hull — otherwise the
    // standing hull's feet end up 18u underground and the player is stuck.
    g_snapDucking[id] = (pev(bot, pev_flags) & FL_DUCKING) != 0;

    g_snapHealth[id] = get_user_health(bot);

    new CsArmorType:armorType;
    g_snapArmor[id] = cs_get_user_armor(bot, armorType);
    g_snapArmorType[id] = _:armorType;

    new weapons[MAX_WEAPONS], num;
    get_user_weapons(bot, weapons, num);
    if (num > MAX_WEAPONS)
        num = MAX_WEAPONS;
    g_snapNumWeapons[id] = num;

    for (new k = 0; k < num; k++) {
        new csw = weapons[k];
        g_snapWeapons[id][k] = csw;
        g_snapClip[id][k] = -1;

        if (weaponHasBpAmmo(csw)) {
            g_snapBpAmmo[id][k] = cs_get_user_bpammo(bot, csw);
            if (g_bWeaponHasClip[csw]) {
                new went = findWeaponEnt(bot, g_szWeaponNames[csw]);
                if (went > 0)
                    g_snapClip[id][k] = cs_get_weapon_ammo(went);
            }
        } else {
            g_snapBpAmmo[id][k] = 0;
        }
    }

    g_snapActive[id] = get_user_weapon(bot);

    get_user_name(bot, g_snapName[id], charsmax(g_snapName[]));

    g_snapModel[id][0] = EOS;
    if (get_pcvar_num(g_pAdoptModel))
        cs_get_user_model(bot, g_snapModel[id], charsmax(g_snapModel[]));
}

applySnapshot(id) {
    // --- stance: replay the bot's crouch BEFORE placing the body ---
    // The respawn just gave the player the standing hull (mins z -36). The bot's
    // snapshot origin, if it was crouching, is the lowered crouch origin (centered
    // on the duck hull, mins z -18). Dropping the standing hull there buries the
    // feet 18u underground -> the player is stuck. Switch to the duck hull + flag
    // + view offset first, so the body lands feet-on-floor at the crouch origin.
    // The engine then stands the player up next frame if there's headroom, or
    // keeps them crouched under a low ceiling — either way, never stuck.
    if (g_snapDucking[id]) {
        set_pev(id, pev_flags, pev(id, pev_flags) | FL_DUCKING);
        set_pev(id, pev_view_ofs, Float:{0.0, 0.0, 12.0});   // VEC_DUCK_VIEW
        engfunc(EngFunc_SetSize, id, Float:{-16.0, -16.0, -18.0}, Float:{16.0, 16.0, 18.0});
    }

    // --- placement / physics ---
    engfunc(EngFunc_SetOrigin, id, g_snapOrigin[id]);
    set_pev(id, pev_angles,   g_snapAngles[id]);
    set_pev(id, pev_v_angle,  g_snapAngles[id]);
    set_pev(id, pev_fixangle, 1);
    set_pev(id, pev_velocity, g_snapVelocity[id]);

    // --- health / armor ---
    new mode = get_pcvar_num(g_pHealthMode);
    new hp = g_snapHealth[id];
    if (mode == 1)
        hp = 100;
    else if (mode == 2 && hp > 100)
        hp = 100;
    if (hp < 1)
        hp = 1;
    set_user_health(id, hp);

    if (mode == 1)
        cs_set_user_armor(id, 0, CS_ARMOR_NONE);
    else
        cs_set_user_armor(id, g_snapArmor[id], CsArmorType:g_snapArmorType[id]);

    // Restore the player's own money (the respawn can reset it); the bot's cash
    // is intentionally NOT adopted.
    cs_set_user_money(id, g_savedMoney[id], 1);

    // --- weapons / ammo ---
    strip_user_weapons(id);

    for (new k = 0; k < g_snapNumWeapons[id]; k++) {
        new csw = g_snapWeapons[id][k];
        if (csw < 1 || csw > CSW_P90 || g_szWeaponNames[csw][0] == EOS)
            continue;

        new went = give_item(id, g_szWeaponNames[csw]);
        if (went <= 0)
            went = findWeaponEnt(id, g_szWeaponNames[csw]);

        if (weaponHasBpAmmo(csw))
            cs_set_user_bpammo(id, csw, g_snapBpAmmo[id][k]);

        if (went > 0 && g_bWeaponHasClip[csw] && g_snapClip[id][k] >= 0)
            cs_set_weapon_ammo(went, g_snapClip[id][k]);
    }

    // --- active weapon ---
    // Don't deploy the active weapon here. The Deploy that already ran at give_item
    // time (above) happened BEFORE its clip was set below full, and the client seeds
    // its predicted clip from that Deploy and then holds it. A borrowed weapon with a
    // partial clip (e.g. 5/30) then refuses to reload until the player fires once
    // (firing forces a client prediction-error correction that snaps the clip back to
    // reality). Instead hold the knife now; taskFixupSpawn switches to the real weapon
    // a beat later — that deferred switch is a *fresh* Deploy that runs AFTER the clip
    // is set, so the client re-seeds the correct clip and reload works immediately.
    // The player is frozen meanwhile, so the brief knife is unnoticeable. Non-clip
    // actives (knife/grenade/c4) have no clip to mispredict — deploy them directly.
    new active = g_snapActive[id];
    if (active >= 1 && active <= CSW_P90 && g_szWeaponNames[active][0] != EOS) {
        if (g_bWeaponHasClip[active])
            engclient_cmd(id, "weapon_knife");
        else
            engclient_cmd(id, g_szWeaponNames[active]);
    }

    // --- cosmetics ---
    if (get_pcvar_num(g_pAdoptModel) && g_snapModel[id][0] != EOS)
        cs_set_user_model(id, g_snapModel[id]);

    if (get_pcvar_num(g_pAdoptName) && g_snapName[id][0] != EOS) {
        new infoBuffer = engfunc(EngFunc_GetInfoKeyBuffer, id);
        engfunc(EngFunc_SetClientKeyValue, id, infoBuffer, "name", g_snapName[id]);
    }
}

public taskFixupSpawn(taskid) {
    new id = taskid - TASKID_FIXUP;
    if (!is_user_connected(id) || !is_user_alive(id))
        return;

    set_pev(id, pev_fixangle, 1);

    // Deploy the real active weapon now. applySnapshot left a clip weapon on the
    // knife on purpose, so this is a *fresh* Deploy that runs after the clip was set
    // — it re-seeds the client's predicted clip so a partial-clip weapon (e.g. 5/30)
    // reloads immediately instead of only after the first shot. See applySnapshot.
    new active = g_snapActive[id];
    if (active >= 1 && active <= CSW_P90 && g_szWeaponNames[active][0] != EOS)
        engclient_cmd(id, g_szWeaponNames[active]);

    // Re-flush the money HUD, which can blank on the first mid-round respawn.
    cs_set_user_money(id, cs_get_user_money(id), 1);
}

// Lift the post-takeover movement freeze once the player has had a moment to
// orient. Respawning next round clears FL_FROZEN anyway, so a missed task here
// can never leave a player stuck across rounds.
public taskUnfreeze(taskid) {
    new id = taskid - TASKID_UNFREEZE;
    if (!is_user_connected(id) || !is_user_alive(id))
        return;

    set_pev(id, pev_flags, pev(id, pev_flags) & ~FL_FROZEN);
}

// Next round after a takeover: reset the survivor to a normal post-death loadout
// (knife + default pistol, no armor, no grenades) so the borrowed bot kit does
// not carry over. Money is untouched — they rebuy in freeze time like anyone
// who died. No-op for players who took over but then died (already on default).
public taskStripGear(taskid) {
    new id = taskid - TASKID_STRIP;
    if (!is_user_connected(id) || !is_user_alive(id))
        return;

    new CsTeams:team = cs_get_user_team(id);
    if (team != CS_TEAM_T && team != CS_TEAM_CT)
        return;

    strip_user_weapons(id);
    cs_set_user_armor(id, 0, CS_ARMOR_NONE);

    give_item(id, "weapon_knife");

    if (team == CS_TEAM_T) {
        give_item(id, "weapon_glock18");
        cs_set_user_bpammo(id, CSW_GLOCK18, 120);
    } else {
        give_item(id, "weapon_usp");
        cs_set_user_bpammo(id, CSW_USP, 100);
    }
}

// =========================================================================
//  Admin / debug command
// =========================================================================
public cmdForce(id, level, cid) {
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED;

    if (!is_user_connected(id))
        return PLUGIN_HANDLED;

    if (is_user_alive(id)) {
        client_print(id, print_console, "%L", id, "TAKEOVER_NEED_DEAD");
        return PLUGIN_HANDLED;
    }

    pev(id, pev_origin, g_fDeathOrigin[id]);
    g_iState[id] = STATE_SWAPPING;
    remove_task(TASKID_APPLY + id);
    set_task(0.1, "taskDoTakeover", TASKID_APPLY + id);
    return PLUGIN_HANDLED;
}

// =========================================================================
//  Helpers
// =========================================================================
selectBot(CsTeams:team, const Float:fromOrigin[3]) {
    new candidates[MAX_PLAYERS], numCand = 0;

    for (new i = 1; i <= MAX_PLAYERS; i++) {
        if (!is_user_connected(i) || !is_user_bot(i) || !is_user_alive(i))
            continue;
        // Same-team only: `team` is the dead player's team, so an enemy bot can
        // never be selected. This is the sole guard enforcing own-team takeover.
        if (g_bBotConsumed[i] || cs_get_user_team(i) != team)
            continue;
        candidates[numCand++] = i;
    }

    if (numCand == 0)
        return 0;

    new mode = get_pcvar_num(g_pSelect);
    if (mode == 0)
        return candidates[random_num(0, numCand - 1)];

    new best = 0;
    new bool:haveBest = false;
    new Float:bestScore = 0.0;

    for (new c = 0; c < numCand; c++) {
        new i = candidates[c];
        new Float:score = 0.0;

        if (mode == 1) {
            new Float:botOrigin[3];
            pev(i, pev_origin, botOrigin);
            score = -vector_distance(fromOrigin, botOrigin);   // closer = higher
        } else if (mode == 2) {
            score = -float(get_user_health(i));                // lower HP = higher
        } else {
            score = float(get_user_health(i));                 // higher HP = higher
        }

        if (!haveBest || score > bestScore) {
            bestScore = score;
            best = i;
            haveBest = true;
        }
    }

    return best;
}

countAliveTeamBots(CsTeams:team) {
    new count = 0;
    for (new i = 1; i <= MAX_PLAYERS; i++) {
        if (!is_user_connected(i) || !is_user_bot(i) || !is_user_alive(i))
            continue;
        if (g_bBotConsumed[i] || cs_get_user_team(i) != team)
            continue;
        count++;
    }
    return count;
}

findWeaponEnt(owner, const classname[]) {
    new ent = -1;
    while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", classname)) > 0) {
        if (pev(ent, pev_owner) == owner)
            return ent;
    }
    return 0;
}

clearPlayer(id) {
    g_iState[id] = STATE_NONE;
    g_iChosenBot[id] = 0;
    g_bKeyDown[id] = false;
    remove_task(TASKID_DEATHCAM + id);
    remove_task(TASKID_HINT + id);
    remove_task(TASKID_APPLY + id);
    remove_task(TASKID_FIXUP + id);
    remove_task(TASKID_UNFREEZE + id);
}
