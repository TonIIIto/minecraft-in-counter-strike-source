// Part of css-minecraft-passthrough. Licensed under the GNU General Public License v3 (see ../LICENSE-GPL-3.0.txt).
// Minecraft x CS:S passthrough: server-side plugin. Own server only (always run CS:S with -insecure).
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#define REQUIRE_EXTENSIONS
#define AUTOLOAD_EXTENSIONS
#include <mcbridge>

#define UNITS_PER_BLOCK 40.0
#define GROUND_TOP_Y 64           // Minecraft y of the top of the ground under the player when the grid is levelled
#define MAX_BLOCK_ENTS 600        // CS:S has ~2000 entity slots in total
#define BLOCK_MODEL "models/props/cs_office/cardboard_box01.mdl"
#define EF_NODRAW 32

// the scan of CS:S's map: a window of cells around the player
#define WIN_R 20                  // blocks each way (41 x 41 columns)
#define WIN_W 41
#define WIN_BELOW 9               // cells below the player's feet
#define WIN_ABOVE 9               // and above
#define WIN_H 19
#define WIN_CELLS 31939           // 41 * 41 * 19
#define SCAN_PER_FRAME 1500       // hull tests per server frame
#define RESCAN_DISTANCE 7         // blocks the player may walk before the window is re-centred

public Plugin myinfo =
{
	name = "MC Passthrough",
	author = "mc-css",
	description = "Minecraft inside CS:S (camera, ground, blocks, explosions...)",
	version = "0.4.0",
	url = ""
};

ConVar g_cvDebug;
int g_iClient = 0;
bool g_bLeveled = false;
bool g_bWasConnected = false;
float g_fYOff = 0.0;
StringMap g_Blocks;               // "x,y,z" -> entity reference of the invisible solid that stands for a Minecraft block
bool g_bModeWas = false;
int g_iSavedWeapon = INVALID_ENT_REFERENCE;

// map scan state
StringMap g_Sent;                 // cells already sent to Minecraft as ground ("x,y,z")
bool g_Solid[WIN_CELLS];
bool g_bScanning = false;
int g_iScanIndex = 0;
int g_iWinX = 0;                  // cell coordinates of the window's minimum corner
int g_iWinY = 0;
int g_iWinZ = 0;
int g_iLastCenterX = 99999;
int g_iLastCenterZ = 99999;

StringMap g_ProjPrev;             // projectile id -> last position (Minecraft coordinates)

// elytra (F10)
bool g_bFlying = false;
float g_fFlyStart = 0.0;
float g_fBoostUntil = 0.0;
float g_fNextBoost = 0.0;
bool g_bNoclip = false;           // passing through the map's sky roof
float g_fCeilingZ = 0.0;
float g_fFlyVel[3];

// damage dealt by Minecraft's weapons, in CS:S health points (CS:S players have 100)
#define DMG_ARROW 70.0            // two arrows kill
#define DMG_SWORD 45.0            // three hits
#define DMG_MOB_FACTOR 4.0        // a zombie's 3 becomes 12
#define SWORD_REACH 190.0         // units (4.7 blocks)

public void OnPluginStart()
{
	g_Blocks = new StringMap();
	g_Sent = new StringMap();
	g_ProjPrev = new StringMap();
	g_cvDebug = CreateConVar("mc_debug", "1", "Log what the Minecraft bridge is doing to the SourceMod log");
	LogMessage("MC Passthrough 0.4.0 loaded (invincible in Minecraft mode, roof pass-through, combat logging)");
	RegConsoleCmd("mc_level", Cmd_Level, "Re-level Minecraft's ground to where you stand and re-scan the map");
	RegConsoleCmd("mc_test", Cmd_Test, "Build a small Minecraft block tower in front of you");
	RegConsoleCmd("mc_mode", Cmd_Mode, "Toggle Minecraft mode (wheel, 1-9 and mouse buttons go to Minecraft); F7 does the same");
	HookEvent("player_spawn", Event_Spawn);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	CreateTimer(1.0, Timer_Keepalive, _, TIMER_REPEAT);
	CreateTimer(0.1, Timer_Peds, _, TIMER_REPEAT);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage); // the plugin was loaded while people were already in
		}
	}
}

public void OnConfigsExecuted()
{
	// your own server: Minecraft's weapons hurt every bot, whichever team it is on
	ConVar ff = FindConVar("mp_friendlyfire");
	if (ff != null)
	{
		ff.SetInt(1);
	}
}

public void OnMapStart()
{
	g_bLeveled = false;
	g_bScanning = false;
	g_Blocks.Clear();
	g_Sent.Clear();
	g_ProjPrev.Clear();
	g_iLastCenterX = 99999;
	PrecacheModel(BLOCK_MODEL, true);
}

int FindLocalClient()
{
	if (g_iClient > 0 && g_iClient <= MaxClients && IsClientInGame(g_iClient) && !IsFakeClient(g_iClient))
	{
		return g_iClient;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			g_iClient = i;
			return i;
		}
	}

	g_iClient = 0;
	return 0;
}

// ---------------------------------------------------------------------------------------------------------------------
// Coordinates: CS:S (x, y, z-up; 40 units = 1 block) <-> Minecraft (x, y-up, z), shifted by g_fYOff blocks vertically
// ---------------------------------------------------------------------------------------------------------------------

void McToCs(const float mc[3], float cs[3])
{
	cs[0] = mc[0] * UNITS_PER_BLOCK;
	cs[1] = -mc[2] * UNITS_PER_BLOCK;
	cs[2] = (mc[1] - g_fYOff) * UNITS_PER_BLOCK;
}

void CsToMc(const float cs[3], float mc[3])
{
	mc[0] = cs[0] / UNITS_PER_BLOCK;
	mc[1] = cs[2] / UNITS_PER_BLOCK + g_fYOff;
	mc[2] = -cs[1] / UNITS_PER_BLOCK;
}

// ---------------------------------------------------------------------------------------------------------------------
// Map scan: CS:S's floors and walls near the player become a shell of ground blocks in Minecraft
// ---------------------------------------------------------------------------------------------------------------------

public bool TraceFilter_WorldOnly(int entity, int contentsMask, any data)
{
	return false; // only the map's own brushes count; players, props and our stand-ins don't
}

/** Level the grid to the player's floor, forget what was sent, and start scanning around the player. */
void LevelGround(int client)
{
	float feet[3];
	GetClientAbsOrigin(client, feet);
	g_fYOff = float(GROUND_TOP_Y) - feet[2] / UNITS_PER_BLOCK;
	MC_SetYOffset(g_fYOff);
	g_bLeveled = true;
	g_Sent.Clear();
	MC_Send("{\"t\":\"clear\"}");
	ClearBlockEnts();
	g_iLastCenterX = 99999;
	StartScan(client);
}

void StartScan(int client)
{
	float feet[3];
	GetClientAbsOrigin(client, feet);
	int cx = RoundToFloor(feet[0] / UNITS_PER_BLOCK);
	int cz = RoundToFloor(-feet[1] / UNITS_PER_BLOCK);
	int cy = RoundToFloor(feet[2] / UNITS_PER_BLOCK + g_fYOff + 0.05);
	g_iWinX = cx - WIN_R;
	g_iWinZ = cz - WIN_R;
	g_iWinY = cy - WIN_BELOW;
	g_iLastCenterX = cx;
	g_iLastCenterZ = cz;
	g_iScanIndex = 0;
	g_bScanning = true;
}

int CellIndex(int ix, int iy, int iz)
{
	return (iy * WIN_W + iz) * WIN_W + ix;
}

/** Hull tests for a slice of the window each frame; when it's done, the shell goes to Minecraft. */
void ScanStep()
{
	float mins[3] = {-14.0, -14.0, -8.0};
	float maxs[3] = {14.0, 14.0, 8.0};
	float pos[3];
	int end = g_iScanIndex + SCAN_PER_FRAME;
	if (end > WIN_CELLS)
	{
		end = WIN_CELLS;
	}

	for (int i = g_iScanIndex; i < end; i++)
	{
		int ix = i % WIN_W;
		int iz = (i / WIN_W) % WIN_W;
		int iy = i / (WIN_W * WIN_W);
		if (iy >= WIN_H)
		{
			break;
		}

		pos[0] = (float(g_iWinX + ix) + 0.5) * UNITS_PER_BLOCK;
		pos[1] = -(float(g_iWinZ + iz) + 0.5) * UNITS_PER_BLOCK;
		pos[2] = (float(g_iWinY + iy) + 0.5 - g_fYOff) * UNITS_PER_BLOCK;
		Handle tr = TR_TraceHullFilterEx(pos, pos, mins, maxs, MASK_PLAYERSOLID_BRUSHONLY, TraceFilter_WorldOnly);
		g_Solid[CellIndex(ix, iy, iz)] = TR_StartSolid(tr);
		delete tr;
	}

	g_iScanIndex = end;
	if (end >= WIN_CELLS)
	{
		g_bScanning = false;
		SendShell();
	}
}

bool IsShell(int ix, int iy, int iz)
{
	if (!g_Solid[CellIndex(ix, iy, iz)])
	{
		return false;
	}

	// a solid cell with air next to it; cells at the window's edge have unknown neighbours and aren't sent yet
	if (ix == 0 || iz == 0 || iy == 0 || ix == WIN_W - 1 || iz == WIN_W - 1 || iy == WIN_H - 1)
	{
		return false;
	}

	return !g_Solid[CellIndex(ix - 1, iy, iz)] || !g_Solid[CellIndex(ix + 1, iy, iz)]
		|| !g_Solid[CellIndex(ix, iy - 1, iz)] || !g_Solid[CellIndex(ix, iy + 1, iz)]
		|| !g_Solid[CellIndex(ix, iy, iz - 1)] || !g_Solid[CellIndex(ix, iy, iz + 1)];
}

/** New shell cells, as runs up each column: {"t":"ground","c":[x,z,yBottom,yTop,...]}. */
void SendShell()
{
	char buf[6000];
	char one[64];
	char key[48];
	int sent = 0, runs = 0, messages = 0;
	strcopy(buf, sizeof(buf), "{\"t\":\"ground\",\"c\":[");
	bool first = true;
	for (int iz = 0; iz < WIN_W; iz++)
	{
		for (int ix = 0; ix < WIN_W; ix++)
		{
			int runStart = -1;
			for (int iy = 0; iy <= WIN_H; iy++)
			{
				bool fresh = false;
				if (iy < WIN_H && IsShell(ix, iy, iz))
				{
					Format(key, sizeof(key), "%d,%d,%d", g_iWinX + ix, g_iWinY + iy, g_iWinZ + iz);
					int dummy;
					if (!g_Sent.GetValue(key, dummy))
					{
						g_Sent.SetValue(key, 1);
						fresh = true;
						sent++;
					}
				}

				if (fresh)
				{
					if (runStart < 0)
					{
						runStart = iy;
					}
				}
				else if (runStart >= 0)
				{
					Format(one, sizeof(one), "%s%d,%d,%d,%d", first ? "" : ",", g_iWinX + ix, g_iWinZ + iz, g_iWinY + runStart, g_iWinY + iy - 1);
					StrCat(buf, sizeof(buf), one);
					first = false;
					runStart = -1;
					runs++;
					if (strlen(buf) > 5600)
					{
						StrCat(buf, sizeof(buf), "]}");
						MC_Send(buf);
						messages++;
						strcopy(buf, sizeof(buf), "{\"t\":\"ground\",\"c\":[");
						first = true;
					}
				}
			}
		}
	}

	if (!first)
	{
		StrCat(buf, sizeof(buf), "]}");
		MC_Send(buf);
		messages++;
	}

	if (g_cvDebug.BoolValue)
	{
		LogMessage("map scan done: %d new ground cells in %d runs (%d messages), %d known", sent, runs, messages, g_Sent.Size);
	}

	// stand-ins for whatever has been built around the player (changes arrive on their own; this catches what was built out of range)
	MC_Send("{\"t\":\"blocksync\",\"r\":32}");
}

// ---------------------------------------------------------------------------------------------------------------------
// Blocks: every solid Minecraft block gets an invisible solid box in CS:S, so bullets and players stop at it.
// ---------------------------------------------------------------------------------------------------------------------

void BlockKey(int x, int y, int z, char[] key, int maxlen)
{
	Format(key, maxlen, "%d,%d,%d", x, y, z);
}

void ClearBlockEnts()
{
	StringMapSnapshot snap = g_Blocks.Snapshot();
	char key[48];
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		int ref;
		g_Blocks.GetValue(key, ref);
		int ent = EntRefToEntIndex(ref);
		if (ent != INVALID_ENT_REFERENCE && ent > 0)
		{
			AcceptEntityInput(ent, "Kill");
		}
	}

	delete snap;
	g_Blocks.Clear();
}

void AddBlock(int x, int y, int z)
{
	char key[48];
	BlockKey(x, y, z, key, sizeof(key));
	int ref;
	if (g_Blocks.GetValue(key, ref) && EntRefToEntIndex(ref) != INVALID_ENT_REFERENCE)
	{
		return;
	}

	if (g_Blocks.Size >= MAX_BLOCK_ENTS)
	{
		return;
	}

	int ent = CreateEntityByName("prop_dynamic_override");
	if (ent == -1)
	{
		return;
	}

	DispatchKeyValue(ent, "model", BLOCK_MODEL);
	DispatchKeyValue(ent, "solid", "2");                  // SOLID_BBOX
	DispatchKeyValue(ent, "disableshadows", "1");
	DispatchSpawn(ent);
	float pos[3], mins[3] = {-20.0, -20.0, -20.0}, maxs[3] = {20.0, 20.0, 20.0};
	pos[0] = (float(x) + 0.5) * UNITS_PER_BLOCK;
	pos[1] = -(float(z) + 0.5) * UNITS_PER_BLOCK;
	pos[2] = (float(y) + 0.5 - g_fYOff) * UNITS_PER_BLOCK;
	// the box first, then the move: moving is what tells the engine to re-file the entity under its new bounds
	SetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
	SetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
	SetEntProp(ent, Prop_Send, "m_nSolidType", 2);
	SetEntProp(ent, Prop_Send, "m_usSolidFlags", 0);
	SetEntProp(ent, Prop_Send, "m_CollisionGroup", 0);
	SetEntProp(ent, Prop_Send, "m_fEffects", GetEntProp(ent, Prop_Send, "m_fEffects") | EF_NODRAW);
	TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
	g_Blocks.SetValue(key, EntIndexToEntRef(ent));
}

void RemoveBlock(int x, int y, int z)
{
	char key[48];
	BlockKey(x, y, z, key, sizeof(key));
	int ref;
	if (g_Blocks.GetValue(key, ref))
	{
		int ent = EntRefToEntIndex(ref);
		if (ent != INVALID_ENT_REFERENCE && ent > 0)
		{
			AcceptEntityInput(ent, "Kill");
		}

		g_Blocks.Remove(key);
	}
}

/** Every integer in the JSON array that follows `key` (e.g. "\"set\":[") up to its closing bracket. */
void ParseInts(const char[] msg, const char[] key, ArrayList out)
{
	int p = StrContains(msg, key);
	if (p < 0)
	{
		return;
	}

	p += strlen(key);
	int len = strlen(msg);
	while (p < len && msg[p] != ']')
	{
		int value;
		int used = StringToIntEx(msg[p], value);
		if (used == 0)
		{
			p++;
			continue;
		}

		out.Push(value);
		p += used;
	}
}

void ApplyBlocks(const char[] msg)
{
	ArrayList set = new ArrayList();
	ArrayList clear = new ArrayList();
	ParseInts(msg, "\"set\":[", set);
	ParseInts(msg, "\"clear\":[", clear);
	for (int i = 0; i + 2 < clear.Length; i += 3)
	{
		RemoveBlock(clear.Get(i), clear.Get(i + 1), clear.Get(i + 2));
	}

	for (int i = 0; i + 2 < set.Length; i += 3)
	{
		AddBlock(set.Get(i), set.Get(i + 1), set.Get(i + 2));
	}

	if (g_cvDebug.BoolValue && (set.Length > 0 || clear.Length > 0))
	{
		LogMessage("blocks message: +%d -%d, now %d stand-ins", set.Length / 3, clear.Length / 3, g_Blocks.Size);
	}

	delete set;
	delete clear;
}

// ---------------------------------------------------------------------------------------------------------------------
// Arrows and fireworks fly in Minecraft; here they are traced through CS:S's map and players
// ---------------------------------------------------------------------------------------------------------------------

public bool TraceFilter_Projectile(int entity, int contentsMask, any data)
{
	if (entity == data)
	{
		return false;
	}

	// Minecraft already collides with its own blocks: skip their stand-ins in CS:S
	char model[96];
	if (entity > MaxClients && HasEntProp(entity, Prop_Data, "m_ModelName") && GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model)) > 0 && StrEqual(model, BLOCK_MODEL))
	{
		return false;
	}

	return true;
}

void HandleProjectiles(const char[] msg)
{
	int p = StrContains(msg, "\"p\":[[");
	StringMap now = new StringMap();
	if (p >= 0)
	{
		char body[4096];
		strcopy(body, sizeof(body), msg[p + 6]);
		int e = StrContains(body, "]]");
		if (e >= 0)
		{
			body[e] = 0;
		}

		char parts[64][128];
		int n = ExplodeString(body, "],[", parts, 64, 128);
		for (int i = 0; i < n; i++)
		{
			char f[5][32];
			if (ExplodeString(parts[i], ",", f, 5, 32) < 5)
			{
				continue;
			}

			char idKey[16];
			strcopy(idKey, sizeof(idKey), f[0]);
			float mc[3], cs[3], prevMc[3], prevCs[3];
			mc[0] = StringToFloat(f[2]);
			mc[1] = StringToFloat(f[3]);
			mc[2] = StringToFloat(f[4]);
			now.SetArray(idKey, mc, 3);
			if (!g_ProjPrev.GetArray(idKey, prevMc, 3))
			{
				continue; // first time seen: nothing to trace yet
			}

			McToCs(mc, cs);
			McToCs(prevMc, prevCs);
			Handle tr = TR_TraceRayFilterEx(prevCs, cs, MASK_SHOT, RayType_EndPoint, TraceFilter_Projectile, g_iClient);
			if (TR_DidHit(tr))
			{
				float end[3], endMc[3];
				TR_GetEndPosition(end, tr);
				int victim = TR_GetEntityIndex(tr);
				CsToMc(end, endMc);
				bool person = victim >= 1 && victim <= MaxClients && IsClientInGame(victim) && IsPlayerAlive(victim);
				char out[200];
				Format(out, sizeof(out), "{\"t\":\"projhit\",\"id\":%s,\"pos\":[%.3f,%.3f,%.3f],\"stick\":%s}", f[0], endMc[0], endMc[1], endMc[2], person ? "false" : "true");
				MC_Send(out);
				if (person && victim != g_iClient)
				{
					HurtClient(victim, DMG_ARROW, DMG_BULLET);
				}

				if (g_cvDebug.BoolValue)
				{
					LogMessage("projectile %s hit ent %d at %.0f %.0f %.0f", f[0], victim, end[0], end[1], end[2]);
				}

				now.Remove(idKey);
			}

			delete tr;
		}
	}

	delete g_ProjPrev;
	g_ProjPrev = now;
}

/** Floats in the JSON array that follows `key`, up to `max`; returns how many. */
int ParseFloats(const char[] msg, const char[] key, float[] out, int max)
{
	int p = StrContains(msg, key);
	if (p < 0)
	{
		return 0;
	}

	p += strlen(key);
	int count = 0;
	int len = strlen(msg);
	while (p < len && msg[p] != ']' && count < max)
	{
		int used = StringToFloatEx(msg[p], out[count]);
		if (used == 0)
		{
			p++;
			continue;
		}

		count++;
		p += used;
	}

	return count;
}

/** Minecraft moved the player (an ender pearl landed): CS:S's player follows. */
void HandlePlayerTeleport(const char[] msg)
{
	float mc[3], cs[3];
	if (ParseFloats(msg, "\"pos\":[", mc, 3) < 3)
	{
		return;
	}

	int c = FindLocalClient();
	if (c > 0 && IsPlayerAlive(c))
	{
		McToCs(mc, cs);
		cs[2] += 4.0;
		TeleportEntity(c, cs, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	}
}

// ---------------------------------------------------------------------------------------------------------------------
// Combat: Minecraft's weapons, explosions and mobs hurt CS:S's players and bots
// ---------------------------------------------------------------------------------------------------------------------

void HurtClient(int victim, float damage, int damageType)
{
	if (victim >= 1 && victim <= MaxClients && IsClientInGame(victim) && IsPlayerAlive(victim) && g_iClient > 0)
	{
		int before = GetClientHealth(victim);
		SDKHooks_TakeDamage(victim, g_iClient, g_iClient, damage, damageType);
		if (g_cvDebug.BoolValue)
		{
			LogMessage("hurt client %d (team %d, bot %d) by %.0f: %d -> %d hp", victim, GetClientTeam(victim), IsFakeClient(victim), damage, before, IsPlayerAlive(victim) ? GetClientHealth(victim) : 0);
		}
	}
}

/** Invincible while Minecraft mode is on or while flying. */
public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (victim == g_iClient && (MC_GetMode() || g_bFlying))
	{
		damage = 0.0;
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

/** A sword swing in Minecraft (left click with a sword): whoever is within reach in front of you gets hit. */
void HandleMelee()
{
	int c = FindLocalClient();
	if (c == 0 || !IsPlayerAlive(c))
	{
		return;
	}

	float eye[3], ang[3], fwd[3], end[3];
	float mins[3] = {-10.0, -10.0, -10.0};
	float maxs[3] = {10.0, 10.0, 10.0};
	GetClientEyePosition(c, eye);
	GetClientEyeAngles(c, ang);
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	for (int i = 0; i < 3; i++)
	{
		end[i] = eye[i] + fwd[i] * SWORD_REACH;
	}

	Handle tr = TR_TraceHullFilterEx(eye, end, mins, maxs, MASK_SHOT, TraceFilter_NotSelf, c);
	int victim = TR_GetEntityIndex(tr);
	delete tr;
	if (g_cvDebug.BoolValue)
	{
		LogMessage("sword swing: hit entity %d", victim);
	}

	if (victim >= 1 && victim <= MaxClients && IsClientInGame(victim) && IsPlayerAlive(victim))
	{
		HurtClient(victim, DMG_SWORD, DMG_SLASH);
		float vel[3];
		vel[0] = fwd[0] * 280.0;
		vel[1] = fwd[1] * 280.0;
		vel[2] = 140.0;
		TeleportEntity(victim, NULL_VECTOR, NULL_VECTOR, vel);
		if (g_cvDebug.BoolValue)
		{
			LogMessage("sword hit client %d", victim);
		}
	}
}

public bool TraceFilter_NoEntities(int entity, int contentsMask, any data)
{
	return false;
}

/** Any Minecraft explosion (TNT, creepers): everyone within its radius is hurt and thrown, less behind walls. */
void HandleExplosion(const char[] msg)
{
	float mc[3], cs[3], radius[1];
	if (ParseFloats(msg, "\"pos\":[", mc, 3) < 3 || ParseFloats(msg, "\"r\":", radius, 1) < 1)
	{
		return;
	}

	McToCs(mc, cs);
	float reach = radius[0] * UNITS_PER_BLOCK * 1.25;
	int hurt = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i))
		{
			continue;
		}

		float origin[3], chest[3];
		GetClientAbsOrigin(i, origin);
		chest = origin;
		chest[2] += 36.0;
		float dist = GetVectorDistance(cs, chest);
		if (dist >= reach)
		{
			continue;
		}

		float frac = 1.0 - dist / reach;
		float damage = frac * radius[0] * UNITS_PER_BLOCK * 1.1;
		Handle tr = TR_TraceRayFilterEx(cs, chest, MASK_SOLID_BRUSHONLY, RayType_EndPoint, TraceFilter_NoEntities);
		if (TR_DidHit(tr))
		{
			damage *= 0.35; // the blast is mostly stopped by the wall between
		}

		delete tr;
		float dir[3], vel[3];
		SubtractVectors(chest, cs, dir);
		NormalizeVector(dir, dir);
		for (int k = 0; k < 3; k++)
		{
			vel[k] = dir[k] * 700.0 * frac;
		}

		vel[2] += 260.0 * frac;
		HurtClient(i, damage, DMG_BLAST);
		TeleportEntity(i, NULL_VECTOR, NULL_VECTOR, vel);
		hurt++;
	}

	if (g_cvDebug.BoolValue)
	{
		LogMessage("explosion r=%.1f at %.0f %.0f %.0f hurt %d", radius[0], cs[0], cs[1], cs[2], hurt);
	}
}

/** A Minecraft mob hit one of CS:S's people (its invisible stand-in in Minecraft): {"t":"mobhit","h":client,"d":damage,...}. */
void HandleMobHit(const char[] msg)
{
	float h[1], d[1];
	if (ParseFloats(msg, "\"h\":", h, 1) < 1 || ParseFloats(msg, "\"d\":", d, 1) < 1)
	{
		return;
	}

	HurtClient(RoundToNearest(h[0]), d[0] * DMG_MOB_FACTOR, DMG_SLASH);
}

/** Every 0.1 s: tell Minecraft where CS:S's bots are, so its mobs (creepers, zombies, skeletons) hunt them. */
public Action Timer_Peds(Handle timer)
{
	if (!MC_IsConnected() || !g_bLeveled)
	{
		return Plugin_Continue;
	}

	char buf[3000];
	char one[80];
	strcopy(buf, sizeof(buf), "{\"t\":\"peds\",\"p\":[");
	bool first = true;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == g_iClient || !IsClientInGame(i) || !IsPlayerAlive(i))
		{
			continue;
		}

		float o[3], mc[3];
		GetClientAbsOrigin(i, o);
		CsToMc(o, mc);
		Format(one, sizeof(one), "%s[%d,%.2f,%.2f,%.2f]", first ? "" : ",", i, mc[0], mc[1], mc[2]);
		StrCat(buf, sizeof(buf), one);
		first = false;
	}

	StrCat(buf, sizeof(buf), "]}");
	MC_Send(buf);
	return Plugin_Continue;
}

// ---------------------------------------------------------------------------------------------------------------------
// Elytra: F10 takes off and lands. Elytra-like flight done here in CS:S: look where you want to go, dive to gain speed, climb to lose it,
// right click boosts like a firework. Touching the ground ends it.
// ---------------------------------------------------------------------------------------------------------------------

void StartFlight(int c)
{
	float ang[3], fwd[3], vel[3];
	GetClientEyeAngles(c, ang);
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	for (int i = 0; i < 3; i++)
	{
		vel[i] = fwd[i] * 520.0;
	}

	vel[2] += 320.0; // a lift off the ground
	g_bFlying = true;
	g_bNoclip = false;
	g_fFlyStart = GetGameTime();
	g_fBoostUntil = 0.0;
	g_fNextBoost = 0.0;
	SetEntityMoveType(c, MOVETYPE_FLY);
	TeleportEntity(c, NULL_VECTOR, NULL_VECTOR, vel);
	if (g_cvDebug.BoolValue)
	{
		LogMessage("flight START");
	}
}

void StopFlight(int c, const char[] why)
{
	if (!g_bFlying)
	{
		return;
	}

	g_bFlying = false;
	if (c > 0 && IsClientInGame(c))
	{
		SetEntityMoveType(c, MOVETYPE_WALK);
		SetEntPropFloat(c, Prop_Send, "m_flFallVelocity", 0.0);
		float vel[3];
		if (g_bNoclip)
		{
			vel = g_fFlyVel;
		}
		else
		{
			GetEntPropVector(c, Prop_Data, "m_vecVelocity", vel);
		}

		g_bNoclip = false;
		ScaleVector(vel, 0.2);
		TeleportEntity(c, NULL_VECTOR, NULL_VECTOR, vel);
	}

	if (g_cvDebug.BoolValue)
	{
		LogMessage("flight END (%s)", why);
	}
}

/** One server frame of flight: the velocity is steered toward where you look, dives gain speed, climbs lose it. */
void FlyStep(int c)
{
	float now = GetGameTime();
	float dt = GetTickInterval();
	if (!IsPlayerAlive(c))
	{
		StopFlight(c, "died");
		return;
	}

	if (now - g_fFlyStart > 0.5 && (GetEntityFlags(c) & FL_ONGROUND))
	{
		StopFlight(c, "landed");
		return;
	}

	float ang[3], fwd[3], vel[3], dir[3], pos[3];
	GetClientEyeAngles(c, ang);
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	GetClientAbsOrigin(c, pos);

	// the map's roof is an invisible wall of sky: near it the flight passes through, so you can fly up and out; coming back down
	// into the map the collisions return
	float up[3];
	up = pos;
	up[2] += 6000.0;
	Handle tr = TR_TraceRayFilterEx(pos, up, MASK_SOLID_BRUSHONLY, RayType_EndPoint, TraceFilter_NoEntities);
	if (!g_bNoclip && TR_DidHit(tr) && (TR_GetSurfaceFlags(tr) & 0x4) != 0)
	{
		float hit[3];
		TR_GetEndPosition(hit, tr);
		if (hit[2] - pos[2] < 220.0)
		{
			g_bNoclip = true;
			g_fCeilingZ = hit[2];
			GetEntPropVector(c, Prop_Data, "m_vecVelocity", g_fFlyVel);
			SetEntityMoveType(c, MOVETYPE_NOCLIP);
		}
	}
	else if (g_bNoclip && pos[2] < g_fCeilingZ - 500.0)
	{
		g_bNoclip = false;
		SetEntityMoveType(c, MOVETYPE_FLY);
	}

	delete tr;
	if (g_bNoclip)
	{
		vel = g_fFlyVel;                                  // noclip ignores the velocity, so we keep it ourselves and move the player
	}
	else
	{
		GetEntPropVector(c, Prop_Data, "m_vecVelocity", vel); // the real velocity, so walls and floors are respected
	}

	float speed = GetVectorLength(vel);
	vel[2] -= 280.0 * dt;                                 // gravity, lighter than a fall
	dir = vel;
	if (GetVectorLength(dir) > 1.0)
	{
		NormalizeVector(dir, dir);
	}
	else
	{
		dir = fwd;
	}

	float turn = 1.0 - Pow(2.718281828, -3.2 * dt);
	for (int i = 0; i < 3; i++)
	{
		dir[i] = dir[i] * (1.0 - turn) + fwd[i] * turn;
	}

	NormalizeVector(dir, dir);
	speed += -fwd[2] * 760.0 * dt;                        // diving gains speed, climbing loses it
	speed -= 70.0 * dt;                                   // air drag
	if (now < g_fBoostUntil)
	{
		speed += 2100.0 * dt;                             // firework
	}

	if (speed < 240.0)
	{
		speed = 240.0;
	}

	if (speed > 2600.0)
	{
		speed = 2600.0;
	}

	for (int i = 0; i < 3; i++)
	{
		vel[i] = dir[i] * speed;
	}

	if (g_bNoclip)
	{
		g_fFlyVel = vel;
		for (int i = 0; i < 3; i++)
		{
			pos[i] += vel[i] * dt;
		}

		TeleportEntity(c, pos, NULL_VECTOR, NULL_VECTOR);
	}
	else
	{
		TeleportEntity(c, NULL_VECTOR, NULL_VECTOR, vel);
	}
}

public void MC_OnMessage(const char[] msg)
{
	if (StrContains(msg, "\"t\":\"blocks\"") >= 0)
	{
		ApplyBlocks(msg);
	}
	else if (StrContains(msg, "\"t\":\"proj\"") >= 0)
	{
		HandleProjectiles(msg);
	}
	else if (StrContains(msg, "\"t\":\"explosion\"") >= 0)
	{
		HandleExplosion(msg);
	}
	else if (StrContains(msg, "\"t\":\"melee\"") >= 0)
	{
		HandleMelee();
	}
	else if (StrContains(msg, "\"t\":\"mobhit\"") >= 0)
	{
		HandleMobHit(msg);
	}
	else if (StrContains(msg, "\"t\":\"pteleport\"") >= 0)
	{
		HandlePlayerTeleport(msg);
	}
}

// ---------------------------------------------------------------------------------------------------------------------
// Commands, events and the camera
// ---------------------------------------------------------------------------------------------------------------------

/** mc_test: a small block tower ~4 blocks in front of you, so you can see Minecraft inside CS:S. */
public Action Cmd_Test(int client, int args)
{
	int c = FindLocalClient();
	if (c == 0 || !IsPlayerAlive(c))
	{
		return Plugin_Handled;
	}

	float org[3], ang[3], fwd[3], at[3];
	GetClientAbsOrigin(c, org);
	GetClientEyeAngles(c, ang);
	ang[0] = 0.0;
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	for (int i = 0; i < 3; i++)
	{
		at[i] = org[i] + fwd[i] * 160.0;
	}

	int bx = RoundToFloor(at[0] / UNITS_PER_BLOCK);
	int bz = RoundToFloor(-at[1] / UNITS_PER_BLOCK);
	int by = RoundToFloor(org[2] / UNITS_PER_BLOCK + g_fYOff + 0.05);
	char cmd[256];
	Format(cmd, sizeof(cmd), "{\"t\":\"cmd\",\"c\":\"fill %d %d %d %d %d %d minecraft:stone_bricks\"}", bx, by, bz, bx + 2, by + 2, bz + 2);
	MC_Send(cmd);
	Format(cmd, sizeof(cmd), "{\"t\":\"cmd\",\"c\":\"setblock %d %d %d minecraft:gold_block\"}", bx + 1, by + 3, bz + 1);
	MC_Send(cmd);
	Format(cmd, sizeof(cmd), "{\"t\":\"cmd\",\"c\":\"fill %d %d %d %d %d %d minecraft:red_wool\"}", bx - 2, by, bz, bx - 2, by + 1, bz + 2);
	MC_Send(cmd);
	Format(cmd, sizeof(cmd), "{\"t\":\"cmd\",\"c\":\"fill %d %d %d %d %d %d minecraft:lime_wool\"}", bx + 4, by, bz, bx + 4, by + 1, bz + 2);
	MC_Send(cmd);
	PrintToChat(c, "[MC] built a test tower in front of you");
	return Plugin_Handled;
}

public Action Cmd_Mode(int client, int args)
{
	MC_SetMode(!MC_GetMode());
	return Plugin_Handled;
}

public Action Cmd_Level(int client, int args)
{
	int c = FindLocalClient();
	if (c > 0)
	{
		LevelGround(c);
		PrintToChat(c, "[MC] ground re-levelled, scanning the map");
	}

	return Plugin_Handled;
}

public void Event_Spawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client == FindLocalClient())
	{
		RequestFrame(Frame_Level, GetClientUserId(client));
	}
}

public void Frame_Level(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client))
	{
		LevelGround(client);
	}
}

/** A new round clears the map's entities (including our block stand-ins): make them again from Minecraft's world. */
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_Blocks.Clear();
	MC_Send("{\"t\":\"blocksync\",\"r\":32}");
}

public bool TraceFilter_NotSelf(int entity, int contentsMask, any data)
{
	return entity != data;
}

/** Once a second: re-scan when the player has walked, keep the stand-ins in step, and log what a bullet would hit. */
public Action Timer_Keepalive(Handle timer)
{
	bool connected = MC_IsConnected();
	int c = FindLocalClient();
	bool alive = c > 0 && IsPlayerAlive(c);
	if (connected && !g_bWasConnected && alive)
	{
		LevelGround(c);
	}
	else if (connected && alive && g_bLeveled)
	{
		float feet[3];
		GetClientAbsOrigin(c, feet);
		int cx = RoundToFloor(feet[0] / UNITS_PER_BLOCK);
		int cz = RoundToFloor(-feet[1] / UNITS_PER_BLOCK);
		if (!g_bScanning && (IntAbs(cx - g_iLastCenterX) > RESCAN_DISTANCE || IntAbs(cz - g_iLastCenterZ) > RESCAN_DISTANCE))
		{
			StartScan(c);
		}
	}

	g_bWasConnected = connected;
	if (g_cvDebug.BoolValue && alive)
	{
		float eye[3], ang[3], end[3];
		GetClientEyePosition(c, eye);
		GetClientEyeAngles(c, ang);
		Handle tr = TR_TraceRayFilterEx(eye, ang, MASK_SHOT, RayType_Infinite, TraceFilter_NotSelf, c);
		int hit = TR_GetEntityIndex(tr);
		TR_GetEndPosition(end, tr);
		char cls[64] = "world";
		if (hit > 0)
		{
			GetEntityClassname(hit, cls, sizeof(cls));
		}

		LogMessage("debug: connected=%d mode=%d stand-ins=%d ground=%d scanning=%d | a shot from your eye hits ent %d (%s) at %.0f units", connected, MC_GetMode(), g_Blocks.Size, g_Sent.Size, g_bScanning, hit, cls, GetVectorDistance(eye, end));
		delete tr;
	}

	return Plugin_Continue;
}

int IntAbs(int v)
{
	return v < 0 ? -v : v;
}

void SetViewModelHidden(int c, bool hidden)
{
	int vm = GetEntPropEnt(c, Prop_Send, "m_hViewModel", 0);
	if (vm > 0 && IsValidEntity(vm))
	{
		int fx = GetEntProp(vm, Prop_Send, "m_fEffects");
		SetEntProp(vm, Prop_Send, "m_fEffects", hidden ? (fx | EF_NODRAW) : (fx & ~EF_NODRAW));
	}
}

/** In Minecraft mode CS:S's gun is put away (not drawn, can't fire or switch); leaving the mode brings it back. */
void UpdateHolster(int c)
{
	bool mode = MC_GetMode();
	if (mode && !g_bModeWas)
	{
		int w = GetEntPropEnt(c, Prop_Send, "m_hActiveWeapon");
		g_iSavedWeapon = w > 0 ? EntIndexToEntRef(w) : INVALID_ENT_REFERENCE;
		if (g_cvDebug.BoolValue)
		{
			LogMessage("Minecraft mode ON (active weapon %d)", w);
		}
	}

	if (mode && IsPlayerAlive(c))
	{
		SetViewModelHidden(c, true);
		float later = GetGameTime() + 1.0;
		for (int i = 0; i < 48; i++)
		{
			int w = GetEntPropEnt(c, Prop_Send, "m_hMyWeapons", i);
			if (w > 0 && IsValidEntity(w))
			{
				SetEntPropFloat(w, Prop_Send, "m_flNextPrimaryAttack", later);
				SetEntPropFloat(w, Prop_Send, "m_flNextSecondaryAttack", later);
			}
		}
	}
	else if (!mode && g_bModeWas)
	{
		SetViewModelHidden(c, false);
		int w = EntRefToEntIndex(g_iSavedWeapon);
		if (w > 0 && w != INVALID_ENT_REFERENCE && IsPlayerAlive(c))
		{
			SetEntPropEnt(c, Prop_Send, "m_hActiveWeapon", w);
		}

		if (g_cvDebug.BoolValue)
		{
			LogMessage("Minecraft mode OFF");
		}
	}

	g_bModeWas = mode;
}

public void OnGameFrame()
{
	int c = FindLocalClient();
	if (c == 0)
	{
		return;
	}

	UpdateHolster(c);
	if (g_bScanning)
	{
		ScanStep();
	}

	if (MC_PopFlight())
	{
		if (g_bFlying)
		{
			StopFlight(c, "F10");
		}
		else if (IsPlayerAlive(c))
		{
			StartFlight(c);
		}
	}

	if (g_bFlying)
	{
		FlyStep(c);
	}

	float org[3], ang[3];
	GetClientEyePosition(c, org);
	GetClientEyeAngles(c, ang);
	int fov = GetEntProp(c, Prop_Send, "m_iFOV");
	if (fov <= 0)
	{
		fov = GetEntProp(c, Prop_Send, "m_iDefaultFOV");
	}

	if (fov <= 0)
	{
		fov = 90;
	}

	if (!g_bLeveled && IsPlayerAlive(c))
	{
		LevelGround(c);
	}

	MC_Camera(org, ang, float(fov));
}

/** In Minecraft mode nothing else fires or switches (belt and braces: the gun is already put away). */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (client == g_iClient && g_bFlying)
	{
		// right click while flying: a firework boost (and it doesn't also zoom or stab)
		float now = GetGameTime();
		if ((buttons & IN_ATTACK2) && now >= g_fNextBoost)
		{
			g_fBoostUntil = now + 0.7;
			g_fNextBoost = now + 1.0;
		}

		buttons &= ~IN_ATTACK2;
	}

	if (client == g_iClient && MC_GetMode())
	{
		buttons &= ~(IN_ATTACK | IN_ATTACK2);
		weapon = 0;
		return Plugin_Changed;
	}

	return g_bFlying && client == g_iClient ? Plugin_Changed : Plugin_Continue;
}
