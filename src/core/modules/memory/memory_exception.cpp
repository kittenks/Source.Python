/**
* =============================================================================
* Source Python
* Copyright (C) 2012-2016 Source Python Development Team.  All rights reserved.
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

#ifdef _WIN32

// ============================================================================
// >> INCLUDES
// ============================================================================
// Windows
#include <Windows.h>

// Memory
#include "utilities/wrap_macros.h"

// Utilities
#include "memory_exception.h"


// ============================================================================
// >> FUNCTIONS
// ============================================================================
int ExceptionHandler(_EXCEPTION_POINTERS* info, DWORD code)
{
	if (code == EXCEPTION_ACCESS_VIOLATION) {
		EXCEPTION_RECORD* record = info->ExceptionRecord;
		char* exc_message;

		// ExceptionInformation[1] is a ULONG_PTR - pointer-width, so 8 bytes on
		// x86-64 and 4 on x86-32 - and it is printed with %llu plus an explicit
		// cast. Both halves of that matter.
		//
		// With %u, PyErr_Format read only the low 32 bits, so every address in
		// this message was silently halved on x86-64. That is not cosmetic. A
		// reported address of 2207807472 (0x839877F0) was in fact
		// 0x7FFA839877F0, and the only reason it appeared to agree with the
		// address of the function being called was a coincidence of the low
		// half. Any conclusion drawn from this message was unsound.
		//
		// Simply changing %u to %llu would be wrong the other way. %llu always
		// reads 8 bytes, but on x86-32 the argument is only 4, so the format
		// would consume the following argument slot. The cast widens the value
		// before the variadic promotion, so one form is right on both
		// architectures.
		//
		// ExceptionInformation[0] is cast to int for the same reason. Its values
		// are small - 0, 1 and 8 for read, write and execute - so %i was reading
		// the right number by luck of the magnitude, not because the format
		// matched the type.
		typedef unsigned long long AddrPrint_t;

		if (record->ExceptionInformation[0] == 0)
			exc_message = "Access violation while reading address '%llu'.";
		else if (record->ExceptionInformation[0] == 1)
			exc_message = "Access violation while writing address '%llu'.";
		else if (record->ExceptionInformation[0] == 8)
			exc_message = "Access violation while executing address '%llu'.";
		else
			BOOST_RAISE_EXCEPTION(
				PyExc_RuntimeError,
				"Unknown access violation '%i' at address '%llu'.", 
				static_cast<int>(record->ExceptionInformation[0]),
				static_cast<AddrPrint_t>(record->ExceptionInformation[1]))

		BOOST_RAISE_EXCEPTION(
			PyExc_RuntimeError,
			exc_message,
			static_cast<AddrPrint_t>(record->ExceptionInformation[1]))
	}

	return EXCEPTION_CONTINUE_SEARCH;
}

#endif // _WIN32
