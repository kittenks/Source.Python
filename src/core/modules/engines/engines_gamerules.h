/**
* =============================================================================
* Source Python
* Copyright (C) 2012-2020 Source Python Development Team.  All rights reserved.
* =============================================================================
*
* This program is free software; you can redistribute it and/or modify it under
* the terms of the GNU General Public License, version 3.0, as published by the
* Free Software Foundation.
*
* This program is distributed in the hope that it will be useful, but WITHOUT
* ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
* FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
* details.
*
* You should have received a copy of the GNU General Public License along with
* this program.  If not, see <http://www.gnu.org/licenses/>.
*
* As a special exception, the Source Python Team gives you permission
* to link the code of this program (as well as its derivative works) to
* "Half-Life 2," the "Source Engine," and any Game MODs that run on software
* by the Valve Corporation.  You must obey the GNU General Public License in
* all respects for all other code used.  Additionally, the Source.Python
* Development Team grants this exception to all derivative works.
*/

#ifndef _ENGINES_GAMERULES_H
#define _ENGINES_GAMERULES_H

//-----------------------------------------------------------------------------
// Includes.
//-----------------------------------------------------------------------------
// Source.Python
// Addr_t, for the datamap-style accessors below. Those accessors are shaped
//     return *(T*) (((Addr_t) this) + offset);
// which is what the second LLP64 sweep replaced. Without this include the file
// does not compile, and the error appears only where a template is instantiated
// or a non-template body is parsed - not at the two other accessors on the first
// pass, which made the failure look narrower than it was.
#include "modules/memory/memory_addr.h"

// SDK
#include "strtools.h"


//-----------------------------------------------------------------------------
// Functions
//-----------------------------------------------------------------------------
class CGameRulesWrapper;

int find_game_rules_property_offset(const char* name);
const char* find_game_rules_proxy_name();
CGameRulesWrapper* find_game_rules();


//-----------------------------------------------------------------------------
// Classes.
//-----------------------------------------------------------------------------
class CGameRulesWrapper
{
public:

	// Getter methods
	template<class T>
	T GetProperty(const char* name)
	{
		return GetPropertyByOffset<T>(find_game_rules_property_offset(name));
	}

	template<class T>
	T GetPropertyByOffset(int offset)
	{
		return *(T *) (((Addr_t) this) + offset);
	}

	const char* GetPropertyStringArray(const char* name)
	{
		return GetPropertyStringArrayByOffset(find_game_rules_property_offset(name));
	}

	const char* GetPropertyStringArrayByOffset(int offset)
	{
		return (const char*) (((Addr_t) this) + offset);
	}

	// Setter methods
	template<class T>
	void SetProperty(const char* name, T value)
	{
		SetPropertyByOffset<T>(find_game_rules_property_offset(name), value);
	}

	template<class T>
	void SetPropertyByOffset(int offset, T value)
	{
		// (Addr_t), not (unsigned long). Under LLP64 `long` is 32 bits while
		// `this` is 64, so the cast truncated the object pointer. The three
		// Get*ByOffset siblings above were converted during the LLP64 pass and
		// this writer was missed.
		*(T *) (((Addr_t) this) + offset) = value;
	}

	void SetPropertyStringArray(const char* name, const char* value)
	{
		SetPropertyStringArrayByOffset(find_game_rules_property_offset(name), value);
	}

	void SetPropertyStringArrayByOffset(int offset, const char* value)
	{
		strcpy((char*) (((Addr_t) this) + offset), value);
	}
};

#endif // _ENGINES_GAMERULES_H
