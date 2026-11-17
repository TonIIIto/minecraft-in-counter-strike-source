/* MC Bridge - part of css-minecraft-passthrough. Built on the SourceMod extension SDK (AlliedModders).
 * Licensed under the GNU General Public License v3 (see LICENSE-GPL-3.0.txt), with the Half-Life 2 / Source engine
 * linking exception that applies to SourceMod's SDK. */
#ifndef _INCLUDE_SOURCEMOD_EXTENSION_CONFIG_H_
#define _INCLUDE_SOURCEMOD_EXTENSION_CONFIG_H_

#define SMEXT_CONF_NAME			"MC Bridge"
#define SMEXT_CONF_DESCRIPTION	"Link between Counter-Strike: Source and a Minecraft passthrough mod (own server only)"
#define SMEXT_CONF_VERSION		"0.1.0"
#define SMEXT_CONF_AUTHOR		"mc-css"
#define SMEXT_CONF_URL			""
#define SMEXT_CONF_LOGTAG		"MCBRIDGE"
#define SMEXT_CONF_LICENSE		"GPL"
#define SMEXT_CONF_DATESTRING	__DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

#define SMEXT_ENABLE_FORWARDSYS

#endif
