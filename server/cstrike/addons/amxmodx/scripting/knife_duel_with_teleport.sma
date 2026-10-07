/*
	1.5.1f 10.11.2024 by mx?!:
		* Исправлен конфликт с "Unreal Anti ESP" от "karaulov" путём переноса хука RH_SV_StartSound в precache и его перевода с Post на Pre
*/

#include <amxmodx>
#include <reapi>
#include <hamsandwich>

//#define TEST					// Для теста команда в чат /duel. работать будет при любом кол-ве игроков :D Доступ с флагом ADMIN_RCON
#define HITWALL		3 			// Сколько раз надо по стене ударить, чтобы вызвать дуель
#define VOTETODUEL	10 			// Через сколько секунд считать, что противник зассал
#define HEALTHONDUEL	100		// Сколько HP ставить игрокам на время дуели. 0 - будет столько, сколько осталось за время раунда.
#define SETAIMONOPP				// Разворачивать игроков друг к другу лицом
#define ANNOUNCE				// Показывать сообщение, когда остаются игрока 1 х 1

enum _:TEAMS
{
	TT,
	CT
}

new HookChain:HookChain_CBasePlayer_PreThink,
	HookChain:HookChain_SV_StartSound;
new Float:g_fKnifePos[TEAMS][3];
new g_iInsider, g_iOpponent;
new Float:g_fHitWall[33];
new g_iHitWall[33];
const TASK_VOTE_DUEL = 100;
new g_szRoundInfinite[32];
new bool:g_bDuelMode;
new HamHook:g_hPrimaryAttackPre, HamHook:g_hSecondaryAttackPre;
new HamHook:g_hPrimaryAttackPost, HamHook:g_hSecondaryAttackPost;
new Float:g_fStabBaseDamage, Float:g_fSwingBaseDamage, Float:g_fStabBaseDamageFast;

public plugin_precache()
{
	register_plugin("Knife Duel with Teleport", "1.5.1f", "neygomon");
	HookChain_SV_StartSound = RegisterHookChain(RH_SV_StartSound, "SV_StartSound_Pre");
}
	
public plugin_init() {
	DisableHookChain((HookChain_CBasePlayer_PreThink = RegisterHookChain(RG_CBasePlayer_PreThink, "CBasePlayer_PreThink_Post", true)));
	RegisterHookChain(RG_CBasePlayer_Killed, "CBasePlayer_Killed_Post", true);
	RegisterHookChain(RG_CSGameRules_CheckMapConditions, "CheckMapConditions_Post", true);
	FindSpawnsForDuel();
	register_menucmd(register_menuid("VoteToDuel"), MENU_KEY_1|MENU_KEY_2, "VoteHandler");

	bind_pcvar_string(get_cvar_pointer("mp_round_infinite"), g_szRoundInfinite, charsmax(g_szRoundInfinite));

	g_hPrimaryAttackPre = RegisterHam(Ham_Weapon_PrimaryAttack, "weapon_knife", "CKnife_PrimaryAttack_Pre")
	g_hPrimaryAttackPost = RegisterHam(Ham_Weapon_PrimaryAttack, "weapon_knife", "CKnife_PrimaryAttack_Post", true)
	g_hSecondaryAttackPre = RegisterHam(Ham_Weapon_SecondaryAttack, "weapon_knife", "CKnife_SecondaryAttack_Pre")
	g_hSecondaryAttackPost = RegisterHam(Ham_Weapon_SecondaryAttack, "weapon_knife", "CKnife_SecondaryAttack_Post", true)

	DisableHamForward(g_hPrimaryAttackPre)
	DisableHamForward(g_hPrimaryAttackPost)
	DisableHamForward(g_hSecondaryAttackPre)
	DisableHamForward(g_hSecondaryAttackPost)
}

public CKnife_PrimaryAttack_Pre(pKnife) {
	if(!is_nullent(pKnife)) {
		EnableHamForward(g_hPrimaryAttackPost)
		SetAttack(pKnife)
	}
}

public CKnife_PrimaryAttack_Post(pKnife) {
	DisableHamForward(g_hPrimaryAttackPost)

	if(!is_nullent(pKnife)) {
		ResetAttack(pKnife)
	}
}

public CKnife_SecondaryAttack_Pre(pKnife) {
	if(!is_nullent(pKnife)) {
		EnableHamForward(g_hSecondaryAttackPost)
		SetAttack(pKnife)
	}
}

public CKnife_SecondaryAttack_Post(pKnife) {
	DisableHamForward(g_hSecondaryAttackPost)

	if(!is_nullent(pKnife)) {
		ResetAttack(pKnife)
	}
}

SetAttack(pKnife) {
	g_fStabBaseDamage = Float:get_member(pKnife, m_Knife_flStabBaseDamage)
	g_fSwingBaseDamage = Float:get_member(pKnife, m_Knife_flSwingBaseDamage)
	g_fStabBaseDamageFast = Float:get_member(pKnife, m_Knife_flSwingBaseDamage_Fast)

	// https://github.com/s1lentq/ReGameDLL_CS/blob/667242fadd431eb0344d12a16847204d10fcad78/regamedll/dlls/weapons.h#L1158
	const Float:KNIFE_STAB_DAMAGE = 65.0
	const Float:KNIFE_SWING_DAMAGE = 15.0
	const Float:KNIFE_SWING_DAMAGE_FAST = 20.0

	set_member(pKnife, m_Knife_flStabBaseDamage, KNIFE_STAB_DAMAGE)
	set_member(pKnife, m_Knife_flSwingBaseDamage, KNIFE_SWING_DAMAGE)
	set_member(pKnife, m_Knife_flSwingBaseDamage_Fast, KNIFE_SWING_DAMAGE_FAST)
}

ResetAttack(pKnife) {
	set_member(pKnife, m_Knife_flStabBaseDamage, g_fStabBaseDamage)
	set_member(pKnife, m_Knife_flSwingBaseDamage, g_fSwingBaseDamage)
	set_member(pKnife, m_Knife_flSwingBaseDamage_Fast, g_fStabBaseDamageFast)
}

public client_disconnected(id)
{
	if(id == g_iInsider || id == g_iOpponent)
		DuelDidNotTake();
}

public CheckMapConditions_Post()
{
	if(g_bDuelMode) {
		g_bDuelMode = false
		DisableHamForward(g_hPrimaryAttackPre)
		DisableHamForward(g_hSecondaryAttackPre)
	}

	if(g_iInsider)
		DuelDidNotTake();
}

public SV_StartSound_Pre(const recipients, const entity, const channel, const sample[], const volume, Float:attenuation, const fFlags, const pitch)
{
	if(sample[0] == 'w' && sample[7] == '/' && sample[8] == 'k' && sample[13] == '_' && sample[17] == 'w') // вангую говно в error логах
	{
		new Float:fGameTime = get_gametime();
		if(fGameTime - g_fHitWall[entity] > 1.0)
			g_iHitWall[entity] = 0;
		else
		{
			new ent1, ent2;
			if(g_iHitWall[entity] == HITWALL - 1 && IsValidPlayersNum(ent1, ent2) && !g_iOpponent)
			{
				VoteToTheDuel(entity, TeamName:get_member(entity, m_iTeam) == TEAM_TERRORIST ? ent2 : ent1);
				DisableHookChain(HookChain_SV_StartSound);
			}
		}
		g_iHitWall[entity]++;
		g_fHitWall[entity] = fGameTime;
	}
}

public CBasePlayer_PreThink_Post(id)
{
	if(g_iInsider == id || g_iOpponent == id)
	{
		if(is_user_alive(id))
		{
			if(get_member(get_member(id, m_pActiveItem), m_iId) != WEAPON_KNIFE)
				engclient_cmd(id, "weapon_knife");
		}
	}
}

public CBasePlayer_Killed_Post(const victim, const killer)
{
	if(g_iInsider)
	{
		if(task_exists(TASK_VOTE_DUEL))
			DuelDidNotTake();
		else if(g_iOpponent)
		{
			if(victim == g_iInsider || victim == g_iOpponent)
				DuelDidNotTake();
		}
		return;
	}
	new ent1, ent2;
	if(IsValidPlayersNum(ent1, ent2))
	{
		client_print_color(ent1, print_team_default,"^1[^4M-16^1] ^4Вы остались^3 1 x 1^4! Хотите дуель на ножах? Ударьте ^3%d раза ^4по стене.", HITWALL);
		client_print_color(ent2, print_team_default,"^1[^4M-16^1] ^4Вы остались^3 1 x 1^4! Хотите дуель на ножах? Ударьте ^3%d раза ^4по стене.", HITWALL);
	}
}

VoteToTheDuel(id, opponent)
{
		new nameId[32], sMenu[200];
		get_user_name(id, nameId, charsmax(nameId));
		formatex(sMenu, charsmax(sMenu), "^t^t^t^t^t^t\wВас вызвал на дуэль \r%s^n^t^t^t^t^t^t\wВы согласны?^n^n^t^t^t^t^t^t\w1) Да. Сделаю фарш. ^n^t^t^t^t^t^t\r2) Нет. Я очкую", nameId);
		show_menu(opponent, MENU_KEY_1|MENU_KEY_2, sMenu, VOTETODUEL, "VoteToDuel");
		set_task(float(VOTETODUEL), "DuelDidNotTake", TASK_VOTE_DUEL);
		g_iInsider = id;
		return PLUGIN_HANDLED;
}

public VoteHandler(id, key)
{
	switch(key)
	{
		case 0:
		{
			g_iOpponent = id;
			remove_task(TASK_VOTE_DUEL);
			GoToDuel();
		}
		case 1:
		{
			new name[32];
			get_user_name(id, name, charsmax(name));
			client_print_color(0, print_team_default, "^1[^4M-16^1] ^4Игрок ^3%s ^4ссыканул и отказался от дуэли :\", name);
			DuelDidNotTake();
		}
	}
	return PLUGIN_HANDLED;
}

public DuelDidNotTake()
{
	DisableHookChain(HookChain_CBasePlayer_PreThink);
	EnableHookChain(HookChain_SV_StartSound);
	remove_task(TASK_VOTE_DUEL);

	g_iInsider = 0;
	g_iOpponent = 0;
}

FindSpawnsForDuel()
{
	new ent = rg_find_ent_by_class(-1, "info_player_start");
	get_entvar(ent, var_origin, g_fKnifePos[TT]);

	new ent2 = ent, bool:bFindPlace;
	new Float:distance = 1000.0;

	while(distance > 100.0 && !bFindPlace)
	{
		while((ent2 = rg_find_ent_by_class(ent2, "info_player_start")))
		{
			get_entvar(ent2, var_origin, g_fKnifePos[CT]);
			if(get_distance_f(g_fKnifePos[TT], g_fKnifePos[CT]) > distance)
			{
				bFindPlace = true;
				break;
			}
		}
		distance -= 100.0;
		ent2 = ent;
	}
	if(!bFindPlace)
		set_fail_state("spawns for duel not found :( govnomap...");
}

GoToDuel()
{
	if(is_user_alive(g_iInsider) && is_user_alive(g_iOpponent))
	{
		g_bDuelMode = true;
		EnableHamForward(g_hPrimaryAttackPre);
		EnableHamForward(g_hSecondaryAttackPre);
		set_entvar(g_iInsider, var_origin, g_fKnifePos[0]);
		set_entvar(g_iOpponent, var_origin, g_fKnifePos[1]);
		entity_set_aim(g_iInsider, g_iOpponent);
		entity_set_aim(g_iOpponent, g_iInsider);
		set_entvar(g_iInsider, var_health, float(HEALTHONDUEL));
		set_entvar(g_iOpponent, var_health, float(HEALTHONDUEL));
		EnableHookChain(HookChain_CBasePlayer_PreThink);
	}
}

bool:IsRoundInfinite() {
	return (g_szRoundInfinite[0] && g_szRoundInfinite[0] != '0')
}

stock IsValidPlayersNum(&idT = 0, &idCT = 0)
{
	// Дуэль не работает при разминке в random_weapons_warmup.sma
	if(IsRoundInfinite()) {
		return 0;
	}

	new pl[32], tt, ct;
	get_players(pl, tt, "ae", "TERRORIST");
	idT = pl[0];
	get_players(pl, ct, "ae", "CT");
	idCT = pl[0];
	return (tt == 1 && ct == 1);
}

stock entity_set_aim(id, ent)
{
	new Float:vOrigin[3], Float:vEntOrigin[3];
	get_entvar(id, var_origin, vOrigin);
	get_entvar(ent, var_origin, vEntOrigin);
	vOrigin[0] -= vEntOrigin[0];
	vOrigin[1] -= vEntOrigin[1];
	vOrigin[2] -= vEntOrigin[2];
	new Float:vNewAngles[3], Float:vAimVector[3], Float:v_length;
	v_length = vector_length(vOrigin);
	vAimVector[0] = vOrigin[0] / v_length;
	vAimVector[1] = vOrigin[1] / v_length;
	vAimVector[2] = vOrigin[2] / v_length;
	vector_to_angle(vAimVector, vNewAngles);
	vNewAngles[0] *= -1;
	vNewAngles[1] += 180;
	set_entvar(id, var_angles, vNewAngles);
	set_entvar(id, var_fixangle, 1);
}