/* MC Bridge - part of css-minecraft-passthrough. Built on the SourceMod extension SDK (AlliedModders).
 * Licensed under the GNU General Public License v3 (see LICENSE-GPL-3.0.txt), with the Half-Life 2 / Source engine
 * linking exception that applies to SourceMod's SDK. */
#ifndef _INCLUDE_MCBRIDGE_EXTENSION_H_
#define _INCLUDE_MCBRIDGE_EXTENSION_H_

#include "smsdk_ext.h"

class McBridge : public SDKExtension
{
public:
	virtual bool SDK_OnLoad(char *error, size_t maxlen, bool late);
	virtual void SDK_OnUnload();
	virtual void SDK_OnAllLoaded();
};

#endif
