#if defined _mcbridge_included
 #endinput
#endif
#define _mcbridge_included

/** CS:S eye position + eye angles (pitch, yaw, roll) + horizontal fov (4:3 based) -> Minecraft camera. */
native void MC_Camera(const float org[3], const float ang[3], float fovH);
/** Vertical offset (blocks) between CS:S's floor and Minecraft's grid. */
native void MC_SetYOffset(float blocks);
/** Raw JSON message for the Minecraft mod. */
native void MC_Send(const char[] json);
native bool MC_IsConnected();
/** Minecraft mode: the mouse wheel, number keys and mouse buttons go to Minecraft (F7 toggles it too). */
native void MC_SetMode(bool on);
native bool MC_GetMode();
/** Elytra: Minecraft flies the player and CS:S follows (the camera message then carries "drive" and the look direction). */
native void MC_SetDrive(bool on);
/** True once for each press of Space in Minecraft mode. */
native bool MC_PopSpace();
/** True once for each press of F10 (the flight key). */
native bool MC_PopFlight();

/** A message from Minecraft (JSON text), on the game thread. */
forward void MC_OnMessage(const char[] msg);

public Extension __ext_mcbridge =
{
	name = "MC Bridge",
	file = "mcbridge.ext",
#if defined AUTOLOAD_EXTENSIONS
	autoload = 1,
#else
	autoload = 0,
#endif
#if defined REQUIRE_EXTENSIONS
	required = 1,
#else
	required = 0,
#endif
};
